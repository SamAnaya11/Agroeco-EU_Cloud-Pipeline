-- =====================================================================
-- 02_consultas_analisis.sql  (versión T-SQL para Azure SQL Database)
-- Consultas de análisis sobre la agricultura ecológica en España y la UE.
-- Fuente: Eurostat (org_cropar, sdg_02_40, org_coptyp, org_lstspec).
--
-- Son las mismas 10 consultas del proyecto original (SQLite), adaptadas a
-- T-SQL. Cada cambio está marcado con un comentario "-- [T-SQL]" y resumido
-- en docs/migracion_sqlite_a_tsql.md
--
-- Cada consulta empieza con una línea "-- @nombre: xxx" (igual que en el
-- original), así un notebook puede cargarlas por su nombre.
-- Para ejecutar una sola consulta en el editor del portal, selecciónala
-- entera (desde su "-- @nombre" hasta el ";") y pulsa "Ejecutar".
--
-- Conceptos SQL que se practican: JOIN, GROUP BY, HAVING, CASE, subconsultas,
-- CTE (WITH) y funciones ventana (LAG, RANK, FIRST_VALUE, SUM OVER).
-- =====================================================================


-- @nombre: q01_evolucion_espana
-- ¿Cómo ha evolucionado la superficie ecológica en España?
-- Total, parte ya certificada, parte en conversión, crecimiento anual y % de la SAU.
-- [T-SQL] ROUND(x) -> ROUND(x, 0): en T-SQL el segundo argumento es obligatorio.
SELECT
    v.anio,
    ROUND(v.total_ha, 0)                                            AS total_ha,
    ROUND(v.convertida_ha, 0)                                       AS convertida_ha,
    ROUND(v.en_conversion_ha, 0)                                    AS en_conversion_ha,
    ROUND(100.0 * v.en_conversion_ha / v.total_ha, 1)               AS pct_en_conversion,
    ROUND(100.0 * (v.total_ha - LAG(v.total_ha) OVER (ORDER BY v.anio))
                / LAG(v.total_ha) OVER (ORDER BY v.anio), 1)        AS crecimiento_anual_pct,
    p.pct_sau_ecologica
FROM v_superficie_total AS v
LEFT JOIN fact_pct_sau  AS p ON p.codigo_pais = v.codigo_pais AND p.anio = v.anio
WHERE v.codigo_pais = 'ES'
ORDER BY v.anio;


-- @nombre: q02_espana_vs_ue
-- % de la superficie agraria en ecológico: España frente a la media de la UE-27.
-- (Eurostat publica el dato de la UE-27 solo hasta 2020.)
-- [T-SQL] Sin cambios: todo lo que usa es SQL estándar.
SELECT
    anio,
    MAX(CASE WHEN codigo_pais = 'ES'        THEN pct_sau_ecologica END) AS espana_pct,
    MAX(CASE WHEN codigo_pais = 'EU27_2020' THEN pct_sau_ecologica END) AS ue27_pct,
    ROUND(MAX(CASE WHEN codigo_pais = 'ES'        THEN pct_sau_ecologica END)
        - MAX(CASE WHEN codigo_pais = 'EU27_2020' THEN pct_sau_ecologica END), 2) AS diferencia_pp
FROM fact_pct_sau
WHERE anio >= 2012
GROUP BY anio
ORDER BY anio;


-- @nombre: q03_ranking_ue_superficie
-- Ranking de países de la UE por hectáreas ecológicas (último año disponible de cada país).
-- [T-SQL] ROUND(x) -> ROUND(x, 0).
WITH ultimo_anio AS (
    SELECT codigo_pais, MAX(anio) AS anio
    FROM v_superficie_total
    WHERE total_ha IS NOT NULL AND es_agregado = 0
    GROUP BY codigo_pais
)
SELECT
    RANK() OVER (ORDER BY v.total_ha DESC)                         AS ranking,
    v.pais,
    v.anio                                                         AS anio_dato,
    ROUND(v.total_ha, 0)                                           AS total_ha,
    ROUND(100.0 * v.total_ha / SUM(v.total_ha) OVER (), 1)         AS cuota_ue_pct
FROM v_superficie_total AS v
JOIN ultimo_anio        AS u ON u.codigo_pais = v.codigo_pais AND u.anio = v.anio
ORDER BY ranking;


-- @nombre: q04_ranking_ue_pct_sau
-- ¿Qué países tienen mayor % de su superficie agraria en ecológico?
-- ¿Cuáles cumplen ya el objetivo europeo del 25 % para 2030?
-- [T-SQL] Sin cambios. "es_agregado = 0" sigue funcionando aunque ahora sea BIT.
WITH ultimo_anio AS (
    SELECT codigo_pais, MAX(anio) AS anio
    FROM fact_pct_sau
    GROUP BY codigo_pais
)
SELECT
    RANK() OVER (ORDER BY f.pct_sau_ecologica DESC) AS ranking,
    p.pais,
    f.anio                                          AS anio_dato,
    f.pct_sau_ecologica,
    CASE WHEN f.pct_sau_ecologica >= 25 THEN 'Cumple' ELSE 'No cumple' END AS objetivo_25
FROM fact_pct_sau AS f
JOIN ultimo_anio  AS u ON u.codigo_pais = f.codigo_pais AND u.anio = f.anio
JOIN dim_pais     AS p ON p.codigo_pais = f.codigo_pais
WHERE p.es_agregado = 0
ORDER BY ranking;


-- @nombre: q05_usos_suelo_espana
-- Reparto de la superficie ecológica española en los 3 grandes usos del suelo.
-- Los pastos se calculan por diferencia (Eurostat dejó de publicarlos en 2021).
-- [T-SQL] ROUND(x) -> ROUND(x, 0).
WITH grupos AS (
    SELECT
        anio,
        SUM(CASE WHEN codigo_cultivo = 'UAAXK0000' THEN superficie_ha END) AS total_ha,
        SUM(CASE WHEN codigo_cultivo = 'ARA'       THEN superficie_ha END) AS arables_ha,
        SUM(CASE WHEN codigo_cultivo = 'PECR'      THEN superficie_ha END) AS permanentes_ha
    FROM fact_superficie
    WHERE codigo_pais = 'ES' AND metodo = 'total'
    GROUP BY anio
)
SELECT
    anio,
    ROUND(arables_ha, 0)                                  AS arables_ha,
    ROUND(permanentes_ha, 0)                              AS permanentes_ha,
    ROUND(total_ha - arables_ha - permanentes_ha, 0)      AS pastos_ha,
    ROUND(100.0 * arables_ha / total_ha, 1)               AS arables_pct,
    ROUND(100.0 * permanentes_ha / total_ha, 1)           AS permanentes_pct,
    ROUND(100.0 * (total_ha - arables_ha - permanentes_ha) / total_ha, 1) AS pastos_pct
FROM grupos
ORDER BY anio;


-- @nombre: q06_cultivos_espana
-- Principales cultivos ecológicos de España en el último año disponible.
-- Se usa la superficie ya convertida, que es la única con detalle por cultivo desde 2021.
-- [T-SQL] ROUND(x) -> ROUND(x, 0).
WITH ultimo AS (
    SELECT MAX(anio) AS anio FROM fact_superficie WHERE codigo_pais = 'ES'
),
total_convertida AS (
    SELECT superficie_ha
    FROM fact_superficie
    WHERE codigo_pais = 'ES' AND codigo_cultivo = 'UAAXK0000' AND metodo = 'convertida'
      AND anio = (SELECT anio FROM ultimo)
)
SELECT
    c.grupo,
    c.cultivo,
    ROUND(s.superficie_ha, 0)                                                 AS superficie_ha,
    ROUND(100.0 * s.superficie_ha / (SELECT superficie_ha FROM total_convertida), 1) AS pct_sobre_total
FROM fact_superficie AS s
JOIN dim_cultivo     AS c ON c.codigo_cultivo = s.codigo_cultivo
WHERE s.codigo_pais = 'ES'
  AND s.metodo = 'convertida'
  AND c.nivel = 'cultivo'
  AND s.anio = (SELECT anio FROM ultimo)
ORDER BY superficie_ha DESC;


-- @nombre: q07_crecimiento_cultivos
-- ¿Qué cultivos han crecido más entre 2012 y 2024? (superficie convertida)
-- HAVING descarta los cultivos sin dato en alguno de los dos años.
-- [T-SQL] ROUND(x) -> ROUND(x, 0).
-- [T-SQL] HAVING no puede usar los alias del SELECT (ha_2012, ha_2024):
--         hay que repetir la expresión completa.
SELECT
    c.cultivo,
    ROUND(SUM(CASE WHEN s.anio = 2012 THEN s.superficie_ha END), 0) AS ha_2012,
    ROUND(SUM(CASE WHEN s.anio = 2024 THEN s.superficie_ha END), 0) AS ha_2024,
    ROUND(SUM(CASE WHEN s.anio = 2024 THEN s.superficie_ha END)
        - SUM(CASE WHEN s.anio = 2012 THEN s.superficie_ha END), 0) AS ha_ganadas,
    ROUND(100.0 * (SUM(CASE WHEN s.anio = 2024 THEN s.superficie_ha END)
                 / SUM(CASE WHEN s.anio = 2012 THEN s.superficie_ha END) - 1), 0) AS crecimiento_pct
FROM fact_superficie AS s
JOIN dim_cultivo     AS c ON c.codigo_cultivo = s.codigo_cultivo
WHERE s.codigo_pais = 'ES' AND s.metodo = 'convertida' AND c.nivel = 'cultivo'
GROUP BY c.cultivo
HAVING SUM(CASE WHEN s.anio = 2012 THEN s.superficie_ha END) IS NOT NULL
   AND SUM(CASE WHEN s.anio = 2024 THEN s.superficie_ha END) IS NOT NULL
ORDER BY ha_ganadas DESC;


-- @nombre: q08_operadores_espana
-- Evolución de los operadores ecológicos en España (una columna por tipo).
-- [T-SQL] Textos con tildes escritos como N'...' (Unicode), porque la columna es NVARCHAR.
SELECT
    anio,
    MAX(CASE WHEN tipo_operador = N'Productores agrícolas' THEN numero END) AS productores,
    MAX(CASE WHEN tipo_operador = N'Elaboradores'          THEN numero END) AS elaboradores,
    MAX(CASE WHEN tipo_operador = N'Comercializadores'     THEN numero END) AS comercializadores,
    MAX(CASE WHEN tipo_operador = N'Importadores'          THEN numero END) AS importadores,
    MAX(CASE WHEN tipo_operador = N'Exportadores'          THEN numero END) AS exportadores
FROM fact_operadores
WHERE codigo_pais = 'ES'
GROUP BY anio
ORDER BY anio;


-- @nombre: q09_ganaderia_espana
-- Ganado ecológico en España por especie y crecimiento respecto a 2012.
-- FIRST_VALUE toma el primer valor de cada especie para calcular el índice.
-- [T-SQL] ROUND(x) -> ROUND(x, 0).
SELECT
    anio,
    especie,
    cabezas,
    ROUND(100.0 * cabezas / FIRST_VALUE(cabezas) OVER (PARTITION BY especie ORDER BY anio), 0) AS indice_2012_100
FROM fact_ganaderia
WHERE codigo_pais = 'ES'
ORDER BY especie, anio;


-- @nombre: q10_grandes_paises
-- Evolución de los 4 países con más superficie ecológica en 2024.
-- [T-SQL] LIMIT 4 -> TOP 4 (va justo después de SELECT).
--         En T-SQL un ORDER BY dentro de una CTE solo se permite si hay TOP.
-- [T-SQL] ROUND(x) -> ROUND(x, 0).
WITH top4 AS (
    SELECT TOP 4 codigo_pais
    FROM v_superficie_total
    WHERE anio = 2024 AND es_agregado = 0 AND total_ha IS NOT NULL
    ORDER BY total_ha DESC
)
SELECT v.anio, v.pais, ROUND(v.total_ha, 0) AS total_ha
FROM v_superficie_total AS v
WHERE v.codigo_pais IN (SELECT codigo_pais FROM top4)
ORDER BY v.pais, v.anio;
