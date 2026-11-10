"""
pipeline.py
-----------
Ejecuta todo el proceso en orden (equivale al main.py del proyecto original):

    1. Descargar los datos de Eurostat
    2. Guardarlos tal cual en Blob Storage      -> contenedor raw/
    3. Limpiar y transformar (modelo estrella)
    4. Guardar las tablas limpias en CSV         -> contenedor processed/
    5. Cargar las tablas en Azure SQL Database

La Azure Function llama a ejecutar_pipeline(). También se puede ejecutar
desde tu ordenador (desde la raíz del repositorio):

    python -m src.pipeline --local   # solo descarga y limpia; guarda en data/ (no usa Azure)
    python -m src.pipeline           # proceso completo contra Azure (lee el archivo .env)

Variables de entorno necesarias para el proceso completo (ver .env.example):
    ALMACENAMIENTO_DATOS   cadena de conexión de la Storage Account
    SQL_CADENA_CONEXION    cadena de conexión de Azure SQL Database
"""

import logging
import os
import sys
from datetime import date
from pathlib import Path

from src import almacenamiento, carga_sql, descarga, limpieza

log = logging.getLogger(__name__)

RAIZ = Path(__file__).resolve().parents[1]
RUTA_ESQUEMA = RAIZ / "sql" / "01_esquema.sql"


def ejecutar_pipeline() -> dict:
    """Ejecuta el pipeline completo en Azure y devuelve un resumen."""
    fecha = date.today().isoformat()   # nombre de la "carpeta" de esta ejecución
    log.info(f">>> Inicio del pipeline ({fecha})")

    # Las cadenas de conexión vienen de variables de entorno (en Azure, de la
    # configuración de la Function App). Si falta alguna, KeyError lo dice claro.
    cadena_storage = os.environ["ALMACENAMIENTO_DATOS"]
    cadena_sql = os.environ["SQL_CADENA_CONEXION"]
    blobs = almacenamiento.conectar(cadena_storage)

    # 1 y 2. Descarga -> raw/
    log.info(">>> 1. Descarga desde Eurostat")
    archivos_raw = descarga.descargar_todo()
    for tabla, contenido in archivos_raw.items():
        almacenamiento.subir(blobs, almacenamiento.CONTENEDOR_RAW, f"{fecha}/{tabla}.tsv", contenido)
    almacenamiento.subir(blobs, almacenamiento.CONTENEDOR_RAW, f"{fecha}/fuente_datos.json",
                         descarga.metadatos_fuente())

    # 3 y 4. Limpieza -> processed/
    log.info(">>> 2. Limpieza con pandas")
    tablas = limpieza.limpiar(archivos_raw)
    for nombre, df in tablas.items():
        almacenamiento.subir_csv(blobs, almacenamiento.CONTENEDOR_PROCESSED, f"{fecha}/{nombre}.csv", df)

    # 5. Carga en Azure SQL
    log.info(">>> 3. Carga en Azure SQL Database")
    recuento = carga_sql.cargar(tablas, cadena_sql, RUTA_ESQUEMA)

    log.info(">>> Pipeline terminado correctamente")
    return {"fecha": fecha, "filas": recuento}


def ejecutar_local() -> None:
    """Prueba sin Azure: descarga y limpia, y guarda los archivos en data/."""
    ruta_raw = RAIZ / "data" / "raw"
    ruta_processed = RAIZ / "data" / "processed"
    ruta_raw.mkdir(parents=True, exist_ok=True)
    ruta_processed.mkdir(parents=True, exist_ok=True)

    archivos_raw = descarga.descargar_todo()
    for tabla, contenido in archivos_raw.items():
        (ruta_raw / f"{tabla}.tsv").write_bytes(contenido)
    (ruta_raw / "fuente_datos.json").write_bytes(descarga.metadatos_fuente())

    tablas = limpieza.limpiar(archivos_raw)
    for nombre, df in tablas.items():
        df.to_csv(ruta_processed / f"{nombre}.csv", index=False, encoding="utf-8")
    log.info(f"[OK] Archivos guardados en {RAIZ / 'data'}")


def leer_archivo_env(ruta: Path) -> None:
    """
    Lee un archivo .env sencillo (líneas NOMBRE=valor) y lo pasa a variables
    de entorno. Solo se usa en local; en Azure las variables ya existen.
    """
    if not ruta.exists():
        return
    for linea in ruta.read_text(encoding="utf-8").splitlines():
        linea = linea.strip()
        if linea and not linea.startswith("#") and "=" in linea:
            nombre, valor = linea.split("=", 1)
            os.environ.setdefault(nombre.strip(), valor.strip())


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    if "--local" in sys.argv:
        ejecutar_local()
    else:
        leer_archivo_env(RAIZ / ".env")
        print(ejecutar_pipeline())
