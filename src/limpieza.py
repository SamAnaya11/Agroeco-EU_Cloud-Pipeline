"""
limpieza.py
-----------
Limpia y transforma los archivos TSV de Eurostat con pandas y los deja como un
modelo en estrella (dimensiones + hechos) listo para cargar en SQL.
Reutiliza scripts/02_limpieza.py del proyecto original: los diccionarios,
la función leer_tsv_eurostat(), los filtros y las comprobaciones son los mismos.

Diferencia con el original: recibe el contenido de los TSV (bytes) y DEVUELVE
las tablas como DataFrames, en vez de leer y escribir en carpetas locales.

Problemas de los datos originales y cómo se resuelven:
    1. La primera columna junta varias dimensiones separadas por comas
       ("A,HA,O1000,TOTAL,ES")              -> se separa en columnas.
    2. Cada año es una columna (formato ancho) -> se pasa a formato largo (melt).
    3. Los valores vienen como texto, con espacios y con "notas" pegadas
       ("2.9 e" = estimado, "8.00 e", "189725 d") -> se separa número y nota.
    4. Los valores no disponibles se marcan con ":" -> se eliminan.
    5. Códigos poco legibles (O1000, PRD_AGRI...) -> se traducen al español.
    6. Hay países fuera de la UE y agregados antiguos (EU28...) -> se filtran.

Salida (diccionario {nombre: DataFrame}):
    dim_pais, dim_cultivo,
    fact_superficie, fact_pct_sau, fact_operadores, fact_ganaderia
"""

import io
import logging

import pandas as pd

log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Diccionarios de códigos de Eurostat -> nombres en español  (sin cambios)
# ---------------------------------------------------------------------------
PAISES_UE = {
    "AT": "Austria", "BE": "Bélgica", "BG": "Bulgaria", "CY": "Chipre",
    "CZ": "Chequia", "DE": "Alemania", "DK": "Dinamarca", "EE": "Estonia",
    "EL": "Grecia", "ES": "España", "FI": "Finlandia", "FR": "Francia",
    "HR": "Croacia", "HU": "Hungría", "IE": "Irlanda", "IT": "Italia",
    "LT": "Lituania", "LU": "Luxemburgo", "LV": "Letonia", "MT": "Malta",
    "NL": "Países Bajos", "PL": "Polonia", "PT": "Portugal", "RO": "Rumanía",
    "SE": "Suecia", "SI": "Eslovenia", "SK": "Eslovaquia",
}
AGREGADO_UE = {"EU27_2020": "Unión Europea (27)"}

# codigo: (nombre, grupo, nivel)
#   nivel "total"   -> toda la superficie ecológica
#   nivel "grupo"   -> los 3 grandes usos del suelo (suman el total)
#   nivel "cultivo" -> detalle de cultivos dentro de cada grupo
CULTIVOS = {
    "UAAXK0000":   ("Superficie ecológica total",   "Total",                "total"),
    "ARA":         ("Tierras arables",              "Tierras arables",      "grupo"),
    "PECR":        ("Cultivos permanentes",         "Cultivos permanentes", "grupo"),
    "J0000":       ("Pastos permanentes",           "Pastos permanentes",   "grupo"),
    "C0000":       ("Cereales",                     "Tierras arables",      "cultivo"),
    "P0000":       ("Legumbres secas",              "Tierras arables",      "cultivo"),
    "G0000":       ("Cultivos forrajeros",          "Tierras arables",      "cultivo"),
    "V0000_S0000": ("Hortalizas y fresas",          "Tierras arables",      "cultivo"),
    "I0000":       ("Cultivos industriales",        "Tierras arables",      "cultivo"),
    "Q0000":       ("Barbecho",                     "Tierras arables",      "cultivo"),
    "O1000":       ("Olivar",                       "Cultivos permanentes", "cultivo"),
    "F4000":       ("Frutos secos",                 "Cultivos permanentes", "cultivo"),
    "W1000":       ("Viñedo",                       "Cultivos permanentes", "cultivo"),
    "T0000":       ("Cítricos",                     "Cultivos permanentes", "cultivo"),
    "F1000":       ("Frutales de clima templado",   "Cultivos permanentes", "cultivo"),
    "F2000":       ("Frutas subtropicales",         "Cultivos permanentes", "cultivo"),
    "F3000":       ("Frutos rojos",                 "Cultivos permanentes", "cultivo"),
}

METODOS = {
    "TOTAL": "total",          # convertida + en conversión
    "FCONV": "convertida",     # ya certificada como ecológica
    "UCONV": "en_conversion",  # periodo de transición (2-3 años)
}

OPERADORES = {
    "OP": "Total operadores",
    "PRD_AGRI": "Productores agrícolas",
    "PRD_AQUA": "Productores de acuicultura",
    "PRC": "Elaboradores",
    "IMP": "Importadores",
    "EXP": "Exportadores",
    "OTH_TRD": "Comercializadores",
}

ESPECIES = {
    "A2000": "Bovino",
    "A3100": "Porcino",
    "A4100": "Ovino",
    "A4200": "Caprino",
}

# Significado de las notas (flags) de Eurostat
NOTAS = {
    "e": "estimado", "p": "provisional", "d": "definición diferente",
    "b": "ruptura de serie", "u": "baja fiabilidad", "c": "confidencial",
}

# Orden de las tablas: primero dimensiones, después hechos (por las claves foráneas)
ORDEN_TABLAS = ["dim_pais", "dim_cultivo", "fact_superficie", "fact_pct_sau",
                "fact_operadores", "fact_ganaderia"]


def leer_tsv_eurostat(contenido: bytes) -> pd.DataFrame:
    """
    Convierte un TSV de Eurostat (formato ancho) en una tabla larga y limpia:
    una fila por combinación de dimensiones y año, con columnas 'valor' y 'nota'.
    (Igual que en el original, pero lee de memoria en lugar de un archivo.)
    """
    df = pd.read_csv(io.BytesIO(contenido), sep="\t", dtype=str)

    # 1. Separar la primera columna "freq,unit,crops,...,geo\TIME_PERIOD"
    columna_dims = df.columns[0]
    nombres_dims = columna_dims.split("\\")[0].split(",")
    df[nombres_dims] = df[columna_dims].str.split(",", expand=True)
    df = df.drop(columns=columna_dims)
    df.columns = [c.strip() for c in df.columns]  # los años traen espacios: "2012 "

    # 2. De ancho a largo: una fila por año
    largo = df.melt(id_vars=nombres_dims, var_name="anio", value_name="valor_texto")
    largo["anio"] = largo["anio"].astype(int)

    # 3. Separar número y nota:  "2.9 e" -> 2.9 + "e" ;  ":" -> sin valor
    texto = largo["valor_texto"].str.strip()
    largo["valor"] = pd.to_numeric(texto.str.extract(r"^([-\d.]+)")[0], errors="coerce")
    largo["nota"] = texto.str.extract(r"\s([a-z]+)$")[0]
    return largo


def resumen_calidad(nombre: str, largo: pd.DataFrame) -> str:
    total = len(largo)
    sin_dato = largo["valor"].isna().sum()
    con_nota = largo["nota"].notna().sum()
    return (f"{nombre:<12} {total:>7,} celdas | {sin_dato:>7,} sin dato (':') "
            f"({100 * sin_dato / total:.0f} %) | {con_nota:>5,} con nota").replace(",", ".")


def limpiar(archivos_raw: dict[str, bytes]) -> dict[str, pd.DataFrame]:
    """
    Recibe {nombre_tabla_eurostat: contenido_tsv} y devuelve las 6 tablas
    del modelo en estrella como DataFrames.
    """
    paises_validos = set(PAISES_UE) | set(AGREGADO_UE)

    # ------------------------------------------------------------------
    # Dimensiones
    # ------------------------------------------------------------------
    dim_pais = pd.DataFrame(
        [{"codigo_pais": c, "pais": n, "es_agregado": 0} for c, n in PAISES_UE.items()]
        + [{"codigo_pais": c, "pais": n, "es_agregado": 1} for c, n in AGREGADO_UE.items()]
    )
    dim_cultivo = pd.DataFrame(
        [{"codigo_cultivo": c, "cultivo": n, "grupo": g, "nivel": nv} for c, (n, g, nv) in CULTIVOS.items()]
    )

    informe = []

    # ------------------------------------------------------------------
    # Superficie por cultivo (hectáreas)
    # ------------------------------------------------------------------
    sup = leer_tsv_eurostat(archivos_raw["org_cropar"])
    informe.append(resumen_calidad("org_cropar", sup))
    sup = sup[(sup["unit"] == "HA")
              & sup["crops"].isin(CULTIVOS)
              & sup["agprdmet"].isin(METODOS)
              & sup["geo"].isin(paises_validos)
              & sup["valor"].notna()]
    fact_superficie = pd.DataFrame({
        "anio": sup["anio"],
        "codigo_pais": sup["geo"],
        "codigo_cultivo": sup["crops"],
        "metodo": sup["agprdmet"].map(METODOS),
        "superficie_ha": sup["valor"],
        "nota": sup["nota"].map(NOTAS),
    })

    # ------------------------------------------------------------------
    # % de la superficie agraria utilizada (SAU) que es ecológica
    # ------------------------------------------------------------------
    pct = leer_tsv_eurostat(archivos_raw["sdg_02_40"])
    informe.append(resumen_calidad("sdg_02_40", pct))
    pct = pct[pct["geo"].isin(paises_validos) & pct["valor"].notna()]
    fact_pct_sau = pd.DataFrame({
        "anio": pct["anio"],
        "codigo_pais": pct["geo"],
        "pct_sau_ecologica": pct["valor"],
        "nota": pct["nota"].map(NOTAS),
    })

    # ------------------------------------------------------------------
    # Operadores (registrados a final de año)
    # ------------------------------------------------------------------
    ope = leer_tsv_eurostat(archivos_raw["org_coptyp"])
    informe.append(resumen_calidad("org_coptyp", ope))
    ope = ope[(ope["procstat"] == "REG_END")
              & ope["operator"].isin(OPERADORES)
              & ope["geo"].isin(paises_validos)
              & ope["valor"].notna()]
    fact_operadores = pd.DataFrame({
        "anio": ope["anio"],
        "codigo_pais": ope["geo"],
        "tipo_operador": ope["operator"].map(OPERADORES),
        "numero": ope["valor"].astype(int),
        "nota": ope["nota"].map(NOTAS),
    })

    # ------------------------------------------------------------------
    # Ganadería ecológica (cabezas)
    # ------------------------------------------------------------------
    gan = leer_tsv_eurostat(archivos_raw["org_lstspec"])
    informe.append(resumen_calidad("org_lstspec", gan))
    gan = gan[(gan["unit"] == "HD")
              & gan["animals"].isin(ESPECIES)
              & gan["geo"].isin(paises_validos)
              & gan["valor"].notna()]
    fact_ganaderia = pd.DataFrame({
        "anio": gan["anio"],
        "codigo_pais": gan["geo"],
        "especie": gan["animals"].map(ESPECIES),
        "cabezas": gan["valor"].astype(int),
        "nota": gan["nota"].map(NOTAS),
    })

    # ------------------------------------------------------------------
    # Comprobaciones de calidad (sin cambios: si fallan, el pipeline se
    # detiene ANTES de tocar la base de datos)
    # ------------------------------------------------------------------
    hechos = {
        "fact_superficie": (fact_superficie, ["anio", "codigo_pais", "codigo_cultivo", "metodo"]),
        "fact_pct_sau": (fact_pct_sau, ["anio", "codigo_pais"]),
        "fact_operadores": (fact_operadores, ["anio", "codigo_pais", "tipo_operador"]),
        "fact_ganaderia": (fact_ganaderia, ["anio", "codigo_pais", "especie"]),
    }
    for nombre, (df, clave) in hechos.items():
        assert not df.duplicated(clave).any(), f"Duplicados en {nombre}"
        assert df.select_dtypes("number").ge(0).all().all(), f"Valores negativos en {nombre}"
        assert len(df) > 0, f"La tabla {nombre} ha quedado vacía"

    log.info("[OK] Limpieza terminada")
    log.info("     Calidad de los datos originales:")
    for linea in informe:
        log.info(f"        {linea}")

    tablas = {"dim_pais": dim_pais, "dim_cultivo": dim_cultivo}
    for nombre, (df, clave) in hechos.items():
        tablas[nombre] = df.sort_values(clave).reset_index(drop=True)
        log.info(f"        {nombre:<16} -> {len(df):>6,} filas".replace(",", "."))
    return tablas
