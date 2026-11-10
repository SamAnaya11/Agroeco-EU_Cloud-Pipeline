-- =====================================================================
-- 01_esquema.sql
-- Modelo en estrella de la base de datos (Azure SQL Database / T-SQL)
--
-- Adaptado de la versión SQLite del proyecto original. Las tablas, columnas,
-- claves y la vista son las mismas; solo cambian los tipos de datos y la
-- sintaxis propia de T-SQL (ver docs/migracion_sqlite_a_tsql.md).
--
--                     ┌──< fact_superficie >── dim_cultivo
--      dim_pais 1 ────┼──< fact_pct_sau
--                     ├──< fact_operadores
--                     └──< fact_ganaderia
--
-- IMPORTANTE: las líneas "GO" separan lotes (batches). No son T-SQL, las
-- interpretan las herramientas cliente (sqlcmd, SSMS, VS Code mssql...).
-- CREATE VIEW tiene que ir sola en su lote, por eso hacen falta.
-- La Azure Function divide este archivo por las líneas "GO" antes de
-- ejecutarlo. Si un editor no entiende "GO", ejecuta cada bloque por separado.
-- =====================================================================

-- Se borra todo y se vuelve a crear en cada carga (igual que en el original).
-- Orden: primero la vista y las tablas de hechos (dependen de las dimensiones).
DROP VIEW  IF EXISTS v_superficie_total;
DROP TABLE IF EXISTS fact_superficie;
DROP TABLE IF EXISTS fact_pct_sau;
DROP TABLE IF EXISTS fact_operadores;
DROP TABLE IF EXISTS fact_ganaderia;
DROP TABLE IF EXISTS dim_cultivo;
DROP TABLE IF EXISTS dim_pais;
GO

-- ---------------------------------------------------------------------
-- Dimensiones
-- ---------------------------------------------------------------------
-- VARCHAR  -> códigos de Eurostat (solo letras, números y "_")
-- NVARCHAR -> textos en español (tildes, ñ)
CREATE TABLE dim_pais (
    codigo_pais  VARCHAR(20)   NOT NULL PRIMARY KEY,   -- código Eurostat (ES, FR, EU27_2020...)
    pais         NVARCHAR(100) NOT NULL UNIQUE,
    es_agregado  BIT           NOT NULL                -- 1 = total de la UE, 0 = país
);

CREATE TABLE dim_cultivo (
    codigo_cultivo  VARCHAR(20)   NOT NULL PRIMARY KEY, -- código Eurostat (O1000, W1000...)
    cultivo         NVARCHAR(100) NOT NULL UNIQUE,
    grupo           NVARCHAR(50)  NOT NULL,
    nivel           VARCHAR(10)   NOT NULL CHECK (nivel IN ('total', 'grupo', 'cultivo'))
);

-- ---------------------------------------------------------------------
-- Hechos
-- ---------------------------------------------------------------------
-- FLOAT en T-SQL = número decimal de 8 bytes (igual que REAL en SQLite).
-- OJO: REAL en T-SQL es de solo 4 bytes (~7 cifras) y perdería precisión.
CREATE TABLE fact_superficie (
    anio            INT           NOT NULL,
    codigo_pais     VARCHAR(20)   NOT NULL REFERENCES dim_pais (codigo_pais),
    codigo_cultivo  VARCHAR(20)   NOT NULL REFERENCES dim_cultivo (codigo_cultivo),
    metodo          VARCHAR(15)   NOT NULL CHECK (metodo IN ('total', 'convertida', 'en_conversion')),
    superficie_ha   FLOAT         NOT NULL CHECK (superficie_ha >= 0),
    nota            NVARCHAR(30)  NULL,                -- estimado, provisional...
    PRIMARY KEY (anio, codigo_pais, codigo_cultivo, metodo)
);

CREATE TABLE fact_pct_sau (
    anio               INT          NOT NULL,
    codigo_pais        VARCHAR(20)  NOT NULL REFERENCES dim_pais (codigo_pais),
    pct_sau_ecologica  FLOAT        NOT NULL CHECK (pct_sau_ecologica BETWEEN 0 AND 100),
    nota               NVARCHAR(30) NULL,
    PRIMARY KEY (anio, codigo_pais)
);

CREATE TABLE fact_operadores (
    anio           INT           NOT NULL,
    codigo_pais    VARCHAR(20)   NOT NULL REFERENCES dim_pais (codigo_pais),
    tipo_operador  NVARCHAR(50)  NOT NULL,
    numero         INT           NOT NULL CHECK (numero >= 0),
    nota           NVARCHAR(30)  NULL,
    PRIMARY KEY (anio, codigo_pais, tipo_operador)
);

CREATE TABLE fact_ganaderia (
    anio         INT           NOT NULL,
    codigo_pais  VARCHAR(20)   NOT NULL REFERENCES dim_pais (codigo_pais),
    especie      NVARCHAR(50)  NOT NULL,
    cabezas      INT           NOT NULL CHECK (cabezas >= 0),
    nota         NVARCHAR(30)  NULL,
    PRIMARY KEY (anio, codigo_pais, especie)
);

CREATE INDEX idx_superficie_cultivo ON fact_superficie (codigo_cultivo);
GO

-- ---------------------------------------------------------------------
-- Vista de apoyo: superficie ecológica total por país y año
-- (la reutilizan varias consultas del análisis)
-- CREATE VIEW debe ser la única sentencia de su lote (por eso el GO anterior).
-- ---------------------------------------------------------------------
CREATE VIEW v_superficie_total AS
SELECT
    s.anio,
    p.codigo_pais,
    p.pais,
    p.es_agregado,
    SUM(CASE WHEN s.metodo = 'total'         THEN s.superficie_ha END) AS total_ha,
    SUM(CASE WHEN s.metodo = 'convertida'    THEN s.superficie_ha END) AS convertida_ha,
    SUM(CASE WHEN s.metodo = 'en_conversion' THEN s.superficie_ha END) AS en_conversion_ha
FROM fact_superficie AS s
JOIN dim_pais        AS p ON p.codigo_pais = s.codigo_pais
WHERE s.codigo_cultivo = 'UAAXK0000'
GROUP BY s.anio, p.codigo_pais, p.pais, p.es_agregado;
GO
