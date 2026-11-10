"""
empaquetar.py
-------------
Crea el paquete .zip que se despliega en la Azure Function.

Azure necesita en la RAÍZ del zip: function_app.py, host.json y
requirements.txt. Además se añaden las carpetas src/ y sql/, que la Function
importa y lee. Las dependencias NO van en el zip: Azure las instala al
desplegar ("remote build"), así se compilan para Linux aunque trabajes en Windows.

Se usa Python (y no Compress-Archive de PowerShell 5.1) porque este último
guarda las rutas con "\" y en Linux se romperían las carpetas.

Uso:
    python scripts/empaquetar.py <ruta_del_zip>
"""

import sys
import zipfile
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[1]
ARCHIVOS_EXCLUIDOS = {"local.settings.json"}   # configuración local con secretos


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit("Uso: python scripts/empaquetar.py <ruta_del_zip>")
    destino = Path(sys.argv[1])
    destino.parent.mkdir(parents=True, exist_ok=True)

    with zipfile.ZipFile(destino, "w", zipfile.ZIP_DEFLATED) as paquete:
        # 1. Contenido de function_app/ en la raíz del zip
        for archivo in (RAIZ / "function_app").iterdir():
            if archivo.is_file() and archivo.name not in ARCHIVOS_EXCLUIDOS:
                paquete.write(archivo, archivo.name)

        # 2. Carpetas src/ y sql/ (as_posix() = rutas con "/", válidas en Linux)
        for carpeta in ["src", "sql"]:
            for archivo in sorted((RAIZ / carpeta).rglob("*")):
                if archivo.is_file() and "__pycache__" not in archivo.parts:
                    paquete.write(archivo, archivo.relative_to(RAIZ).as_posix())

        nombres = paquete.namelist()

    print(f"[OK] Paquete creado: {destino} ({len(nombres)} archivos)")
    for nombre in nombres:
        print(f"     {nombre}")


if __name__ == "__main__":
    main()
