"""
almacenamiento.py
-----------------
Guarda archivos en Azure Blob Storage. Sustituye a las carpetas data/raw/ y
data/processed/ del proyecto original por dos contenedores con el mismo nombre.

Cada ejecución guarda sus archivos en una "carpeta" con la fecha, así se
conserva el histórico de todas las descargas:

    raw/2026-12-01/org_cropar.tsv          processed/2026-12-01/dim_pais.csv
    raw/2026-12-01/fuente_datos.json       processed/2026-12-01/fact_superficie.csv
    ...                                    ...

(En Blob Storage no existen carpetas de verdad: "2026-12-01/" es solo parte
del nombre del archivo, pero el portal lo muestra como si fuera una carpeta.)
"""

import logging

import pandas as pd
from azure.storage.blob import BlobServiceClient

log = logging.getLogger(__name__)

CONTENEDOR_RAW = "raw"
CONTENEDOR_PROCESSED = "processed"


def conectar(cadena_conexion: str) -> BlobServiceClient:
    """Crea el cliente de Blob Storage a partir de la cadena de conexión."""
    return BlobServiceClient.from_connection_string(cadena_conexion)


def subir(cliente: BlobServiceClient, contenedor: str, ruta: str, datos: bytes) -> None:
    """Sube (o sobrescribe) un archivo en un contenedor."""
    cliente.get_blob_client(container=contenedor, blob=ruta).upload_blob(datos, overwrite=True)
    log.info(f"     Guardado {contenedor}/{ruta} ({len(datos) / 1024:,.0f} KB)")


def subir_csv(cliente: BlobServiceClient, contenedor: str, ruta: str, df: pd.DataFrame) -> None:
    """Convierte un DataFrame en CSV (UTF-8, igual que el original) y lo sube."""
    subir(cliente, contenedor, ruta, df.to_csv(index=False).encode("utf-8"))
