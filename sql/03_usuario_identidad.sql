-- =====================================================================
-- 03_usuario_identidad.sql  (Fase 3B)
-- Crea en la base de datos el usuario de la IDENTIDAD ADMINISTRADA de la
-- Function App y le da solo los permisos que necesita el pipeline.
--
-- Se ejecuta UNA VEZ, a mano, en el Query editor del portal, iniciando
-- sesión con "Microsoft Entra authentication" (no con el usuario SQL:
-- "FROM EXTERNAL PROVIDER" solo funciona con una sesión de Entra).
-- Ver docs/identidad_sql.md.
--
-- ANTES de ejecutarlo: cambia func-agroeco-dev-XXXXX por el nombre real de
-- tu Function App (las 3 veces). La identidad se llama igual que la Function.
-- =====================================================================

-- 1. Usuario de la identidad (sin contraseña: Azure lo reconoce por su token)
CREATE USER [func-agroeco-dev-XXXXX] FROM EXTERNAL PROVIDER;

-- 2. Permisos mínimos que usa el pipeline (sql/01_esquema.sql + carga):
--    CREATE TABLE / CREATE VIEW      -> crear las 6 tablas y la vista
--    ALTER     ON SCHEMA::dbo        -> crear y BORRAR (DROP) objetos del esquema dbo, y el índice
--    REFERENCES ON SCHEMA::dbo       -> crear las claves foráneas (hechos -> dimensiones)
--    INSERT    ON SCHEMA::dbo        -> cargar las filas
--    SELECT    ON SCHEMA::dbo        -> el recuento final de filas
--    No tiene UPDATE, DELETE ni permisos fuera del esquema dbo, y no es db_owner.
GRANT CREATE TABLE, CREATE VIEW TO [func-agroeco-dev-XXXXX];
GRANT ALTER, REFERENCES, INSERT, SELECT ON SCHEMA::dbo TO [func-agroeco-dev-XXXXX];

-- 3. Comprobación: debe salir el usuario (tipo E = externo, de Entra) con 7 permisos:
--    CONNECT (lo da CREATE USER automáticamente) y los 6 de arriba
SELECT p.name, p.type_desc, pe.permission_name, pe.class_desc
FROM sys.database_principals AS p
LEFT JOIN sys.database_permissions AS pe ON pe.grantee_principal_id = p.principal_id
WHERE p.type = 'E' AND p.name LIKE 'func-%'
ORDER BY pe.class_desc, pe.permission_name;
