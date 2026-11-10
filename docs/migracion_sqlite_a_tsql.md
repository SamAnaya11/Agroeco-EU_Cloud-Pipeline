# 🔁 De SQLite a Azure SQL Database (T-SQL)

El proyecto original guardaba los datos en **SQLite** (un archivo `.db`). En la nube se usa
**Azure SQL Database**, que habla **T-SQL**, el dialecto de SQL de Microsoft SQL Server.
El modelo en estrella es exactamente el mismo; lo que cambia es la sintaxis y los tipos de datos.

## 📋 Diferencias generales

| Tema | SQLite | T-SQL (Azure SQL) | ¿Afecta a este proyecto? |
|---|---|---|---|
| Limitar filas | `... LIMIT 4` | `SELECT TOP 4 ...` | ✅ q10 |
| Saltar filas (paginar) | `LIMIT 10 OFFSET 20` | `ORDER BY ... OFFSET 20 ROWS FETCH NEXT 10 ROWS ONLY` | ❌ |
| Redondear | `ROUND(x)` (decimales opcionales) | `ROUND(x, 0)` (**obligatorio**) | ✅ casi todas |
| Alias del `SELECT` en `HAVING` | Permitido | **No permitido**: se repite la expresión | ✅ q07 |
| `ORDER BY` dentro de una CTE o subconsulta | Permitido | Solo con `TOP` | ✅ q10 |
| Textos | `TEXT` (sin longitud) | `VARCHAR(n)` / `NVARCHAR(n)`. `TEXT` está obsoleto y no puede ser clave primaria | ✅ esquema |
| Textos con tildes / ñ | Siempre Unicode | `NVARCHAR` y literales `N'texto'` | ✅ esquema, q08 |
| Decimales | `REAL` = 8 bytes | `FLOAT` = 8 bytes. **Ojo:** `REAL` en T-SQL es de 4 bytes (~7 cifras) | ✅ esquema |
| Booleanos | `INTEGER` + `CHECK (x IN (0,1))` | `BIT` | ✅ `es_agregado` |
| Autoincremento | `INTEGER PRIMARY KEY AUTOINCREMENT` | `INT IDENTITY(1,1)` | ❌ |
| Fecha actual | `date('now')`, `datetime('now')` | `CAST(GETDATE() AS DATE)`, `SYSDATETIME()` | ❌ (*) |
| Partes de una fecha | `strftime('%Y', f)` | `YEAR(f)`, `DATEPART(...)`, `FORMAT(f, 'yyyy')` | ❌ (*) |
| Concatenar | `a \|\| b` | `a + b` o `CONCAT(a, b)` | ❌ |
| Nulos | `IFNULL(a, b)` | `ISNULL(a, b)` (o `COALESCE`, que vale en los dos) | ❌ |
| Claves foráneas | Desactivadas por defecto (`PRAGMA foreign_keys = ON`) | **Siempre activas** | ✅ orden de carga |
| `PRAGMA` | Existe | No existe | ✅ se quita del código Python |
| Lotes | Un script se ejecuta entero | `CREATE VIEW` debe ir sola en su lote → separador `GO` | ✅ esquema |
| Mayúsculas en comparaciones | `=` distingue mayúsculas | La intercalación por defecto (`..._CI_AS`) **no** distingue | ⚠️ sin efecto (códigos ya en mayúsculas) |
| Tipado | Dinámico (acepta casi cualquier valor) | Estricto: un texto en una columna `INT` da error | ⚠️ la limpieza con pandas ya garantiza tipos |

(*) Las consultas del proyecto no usan funciones de fecha: el año (`anio`) es un número entero
y la fecha de descarga la calcula Python (`date.today()`). Si en el futuro se añade una columna
de fecha de carga, se usaría `SYSDATETIME()`.

## 🗄️ Cambios en `01_esquema.sql`

| Elemento | SQLite (original) | T-SQL (nuevo) | Motivo |
|---|---|---|---|
| Códigos (`codigo_pais`, `codigo_cultivo`) | `TEXT` | `VARCHAR(20)` | Una clave primaria necesita longitud fija; solo hay caracteres ASCII |
| Textos (`pais`, `cultivo`, `grupo`, `tipo_operador`, `especie`, `nota`) | `TEXT` | `NVARCHAR(n)` | Tildes y ñ (España, Cítricos, Viñedo) |
| `nivel`, `metodo` | `TEXT` | `VARCHAR(10/15)` | Valores fijos sin tildes |
| `es_agregado` | `INTEGER CHECK (IN (0,1))` | `BIT` | Tipo booleano nativo; el `CHECK` sobra |
| `anio`, `numero`, `cabezas` | `INTEGER` | `INT` | Nombre del tipo en T-SQL |
| `superficie_ha`, `pct_sau_ecologica` | `REAL` | `FLOAT` | Mantener 8 bytes de precisión |
| `DROP ... IF EXISTS` | ✔ | ✔ (igual) | Disponible desde SQL Server 2016 |
| `CREATE VIEW` | En el mismo script | Precedido y seguido de `GO` | Debe ser la única sentencia de su lote |
| Claves `PRIMARY KEY`, `REFERENCES`, `CHECK`, `UNIQUE`, índice | ✔ | ✔ (igual) | SQL estándar |

## 🔎 Cambios en las 10 consultas (`02_consultas_analisis.sql`)

| Consulta | Qué cambia | Por qué |
|---|---|---|
| **q01** evolución España | `ROUND(x)` → `ROUND(x, 0)` (3 columnas) | En T-SQL los decimales son obligatorios |
| **q02** España vs UE | **Sin cambios** | Solo usa `MAX(CASE ...)` y `ROUND(x, 2)`, que ya es válido |
| **q03** ranking hectáreas | `ROUND(x)` → `ROUND(x, 0)` | Ídem. `RANK()`, `SUM() OVER ()` y CTE funcionan igual |
| **q04** ranking % SAU | **Sin cambios** | `es_agregado = 0` sigue funcionando con `BIT` |
| **q05** usos del suelo | `ROUND(x)` → `ROUND(x, 0)` (3 columnas) | Ídem |
| **q06** cultivos España | `ROUND(x)` → `ROUND(x, 0)` | Ídem. Las subconsultas escalares funcionan igual |
| **q07** crecimiento cultivos | `ROUND(x)` → `ROUND(x, 0)` (4 columnas) **y** `HAVING ha_2012 IS NOT NULL ...` → se repite `SUM(CASE WHEN ...)` | T-SQL evalúa `HAVING` antes que el `SELECT`, así que no conoce sus alias |
| **q08** operadores | Literales `'Productores agrícolas'` → `N'Productores agrícolas'` (y resto) | Comparar con una columna `NVARCHAR` usando texto Unicode, por las tildes |
| **q09** ganadería | `ROUND(x)` → `ROUND(x, 0)` | Ídem. `FIRST_VALUE ... OVER (PARTITION BY ... ORDER BY ...)` funciona igual |
| **q10** grandes países | `LIMIT 4` → `SELECT TOP 4` y `ROUND(x)` → `ROUND(x, 0)` | T-SQL no tiene `LIMIT`; además, el `ORDER BY` de la CTE solo es válido junto a `TOP` |

## ⚠️ Cosas a tener en cuenta (no son errores)

- **Años fijos en q07 y q10** (`2012`, `2024`): se mantienen igual que en el original para que
  los resultados coincidan. Cuando Eurostat publique 2025, el pipeline cargará los datos nuevos,
  pero estas dos consultas seguirán comparando 2012 con 2024 hasta que se cambie el año.
- **`ROUND` con `FLOAT`** devuelve un `FLOAT` (por ejemplo `2944904.0`); el valor es el mismo
  que en SQLite.
- **El separador `GO`** lo entienden `sqlcmd`, SSMS y la extensión *mssql* de VS Code. Desde
  Python no existe, así que la Function divide el esquema por las líneas `GO` y ejecuta cada
  bloque por separado. Si el editor de consultas del portal no lo acepta, ejecuta cada bloque
  seleccionándolo.
