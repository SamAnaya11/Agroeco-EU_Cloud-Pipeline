"""
carga_sql.py
------------
Crea las tablas en Azure SQL Database a partir de sql/01_esquema.sql y carga
en ellas las tablas limpias. Sustituye a scripts/03_cargar_sql.py del
proyecto original (que usaba SQLite).

Qué cambia respecto al original:
    - SQLite era un archivo; Azure SQL es un servidor al que nos conectamos
      con una cadena de conexión (se lee de una variable de entorno, nunca
      se escribe en el código).
    - Se usa el driver oficial de Microsoft "mssql-python". No necesita
      instalar aparte el driver ODBC: viene incluido en el paquete de pip.
    - El esquema tiene líneas "GO" (separadores de lote). Python no las
      entiende, así que se divide el archivo por esas líneas.
    - Todo se hace en UNA transacción: si algo falla a mitad, se deshace
      (rollback) y la base de datos se queda con los datos del mes anterior.
    - La base de datos gratuita se pausa sola tras 15 minutos sin uso. La
      primera conexión la "despierta" y puede fallar mientras arranca, por
      eso se reintenta varias veces.
"""

import logging
import time
from pathlib import Path

import mssql_python
import pandas as pd

from src.limpieza import ORDEN_TABLAS

log = logging.getLogger(__name__)

INTENTOS_CONEXION = 6    # 6 intentos x 30 s = hasta 3 minutos esperando a que despierte
ESPERA_SEGUNDOS = 30
TIEMPO_ESPERA_CONEXION = 60   # segundos máximos por cada intento de conexión


def conectar(cadena_conexion: str) -> mssql_python.Connection:
    """Abre la conexión con Azure SQL, reintentando si la base de datos está en pausa."""
    for intento in range(1, INTENTOS_CONEXION + 1):
        try:
            # El tiempo de espera va como parámetro: mssql-python no admite
            # "Connection Timeout" dentro de la cadena de conexión.
            return mssql_python.connect(cadena_conexion, autocommit=False,
                                        timeout=TIEMPO_ESPERA_CONEXION)
        except mssql_python.Error as error:
            if intento == INTENTOS_CONEXION:
                raise
            log.warning(f"     No se pudo conectar (intento {intento}/{INTENTOS_CONEXION}). "
                        f"Puede que la base de datos esté reanudándose. Reintento en {ESPERA_SEGUNDOS} s. "
                        f"Detalle: {error}")
            time.sleep(ESPERA_SEGUNDOS)


def dividir_en_lotes(texto_sql: str) -> list[str]:
    """Divide un script SQL por las líneas que solo contienen 'GO'."""
    lotes = []
    lote_actual = []
    for linea in texto_sql.splitlines():
        if linea.strip().upper() == "GO":
            lotes.append("\n".join(lote_actual))
            lote_actual = []
        else:
            lote_actual.append(linea)
    lotes.append("\n".join(lote_actual))
    # Se descartan los lotes vacíos o que solo tienen comentarios
    return [lote for lote in lotes if any(l.strip() and not l.strip().startswith("--") for l in lote.splitlines())]


def filas_para_sql(df: pd.DataFrame) -> list[tuple]:
    """
    Convierte un DataFrame en una lista de tuplas para insertar en SQL.
      - astype(object) convierte los números de numpy en números de Python.
      - where(..., None) cambia los NaN (valores vacíos de pandas) por None,
        que el driver guarda como NULL.
    """
    limpio = df.astype(object).where(df.notna(), None)
    return list(limpio.itertuples(index=False, name=None))


def cargar(tablas: dict[str, pd.DataFrame], cadena_conexion: str, ruta_esquema: Path) -> dict[str, int]:
    """Crea el esquema, inserta todas las tablas y devuelve cuántas filas tiene cada una."""
    lotes_esquema = dividir_en_lotes(ruta_esquema.read_text(encoding="utf-8"))

    conexion = conectar(cadena_conexion)
    try:
        cursor = conexion.cursor()

        # 1. Borrar y crear tablas y vista
        for lote in lotes_esquema:
            cursor.execute(lote, use_prepare=False)
        log.info(f"     Esquema creado ({len(lotes_esquema)} lotes)")

        # 2. Insertar los datos: primero dimensiones, después hechos
        for nombre in ORDEN_TABLAS:
            df = tablas[nombre]
            columnas = ", ".join(df.columns)
            marcadores = ", ".join(["?"] * len(df.columns))
            cursor.executemany(f"INSERT INTO {nombre} ({columnas}) VALUES ({marcadores})", filas_para_sql(df))
            log.info(f"     {nombre:<16} -> {len(df):>6,} filas insertadas".replace(",", "."))

        # 3. Confirmar todo de una vez
        conexion.commit()

        # 4. Comprobación rápida (igual que en el original)
        recuento = {}
        for nombre in ORDEN_TABLAS:
            cursor.execute(f"SELECT COUNT(*) FROM {nombre}")
            recuento[nombre] = cursor.fetchone()[0]
        log.info(f"[OK] Carga en Azure SQL terminada: {recuento}")
        return recuento

    except Exception:
        conexion.rollback()   # deja la base de datos como estaba antes
        log.error("     Error durante la carga: se deshacen todos los cambios (rollback)")
        raise
    finally:
        conexion.close()
