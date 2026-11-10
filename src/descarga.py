"""
descarga.py
-----------
Descarga los datos oficiales de agricultura ecológica desde la API pública de
EUROSTAT. Reutiliza scripts/01_descargar_datos.py del proyecto original.

Diferencia con el original: en vez de guardar los archivos en data/raw/,
las funciones DEVUELVEN el contenido (bytes). Así quien las llama decide dónde
guardarlo: Blob Storage en Azure o una carpeta local en pruebas.

Tablas descargadas:
    org_cropar   -> Superficie ecológica por cultivo (hectáreas)
    sdg_02_40    -> % de la superficie agraria utilizada que es ecológica
    org_coptyp   -> Número de operadores ecológicos por tipo
    org_lstspec  -> Ganado ecológico por especie (cabezas)
"""

import json
import logging
import time
import urllib.request
from datetime import date

log = logging.getLogger(__name__)

URL_API = "https://ec.europa.eu/eurostat/api/dissemination/sdmx/2.1/data/{tabla}?format=TSV&compressed=false"

TABLAS = {
    "org_cropar": "Organic crop area by agricultural production methods and crops",
    "sdg_02_40": "Area under organic farming (% of utilised agricultural area)",
    "org_coptyp": "Organic operators by status of the registration process",
    "org_lstspec": "Organic livestock by species",
}

INTENTOS = 3            # la API de Eurostat a veces falla puntualmente
ESPERA_SEGUNDOS = 20    # espera entre intentos


def descargar(tabla: str) -> bytes:
    """Descarga una tabla de Eurostat (formato TSV) y devuelve su contenido."""
    url = URL_API.format(tabla=tabla)
    peticion = urllib.request.Request(url, headers={"User-Agent": "agroeco-cloud-pipeline/1.0"})

    for intento in range(1, INTENTOS + 1):
        try:
            with urllib.request.urlopen(peticion, timeout=120) as respuesta:
                return respuesta.read()
        except OSError as error:  # errores de red y HTTP heredan de OSError
            if intento == INTENTOS:
                raise
            log.warning(f"     Fallo descargando {tabla} (intento {intento}): {error}. Reintentando...")
            time.sleep(ESPERA_SEGUNDOS)


def descargar_todo() -> dict[str, bytes]:
    """Descarga las 4 tablas. Devuelve {nombre_tabla: contenido_tsv}."""
    archivos = {}
    for tabla, descripcion in TABLAS.items():
        log.info(f"     Descargando {tabla:<12} ({descripcion})...")
        archivos[tabla] = descargar(tabla)
        log.info(f"     -> {len(archivos[tabla]) / 1024:,.0f} KB")
    return archivos


def metadatos_fuente() -> bytes:
    """
    Devuelve el contenido de fuente_datos.json (igual que en el original):
    de dónde y cuándo salieron los datos (trazabilidad).
    """
    metadatos = {
        "fuente": "Eurostat - API de difusión SDMX 2.1",
        "fecha_descarga": date.today().isoformat(),
        "tablas": {t: {"descripcion": d, "url": URL_API.format(tabla=t)} for t, d in TABLAS.items()},
    }
    return json.dumps(metadatos, indent=2, ensure_ascii=False).encode("utf-8")
