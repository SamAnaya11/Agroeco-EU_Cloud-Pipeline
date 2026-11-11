# 🪪 La Function entra en Azure SQL sin contraseña (Fase 3, parte B)

La Function App se conecta a Azure SQL con su **identidad administrada**: una identidad de Microsoft Entra ID
que Azure crea y gestiona. No hay ninguna contraseña en la configuración de la Function.

| | Antes (Fases 1-3A) | Ahora (Fase 3B) |
|---|---|---|
| Cadena de conexión de la Function | `...;UID=agroecoadmin;PWD=<contraseña>;...` | `...;Authentication=ActiveDirectoryMSI;...` |
| ¿Quién entra en SQL? | El **administrador** del servidor (todos los permisos) | Un usuario propio de la Function, con **permisos mínimos** |
| Si alguien lee la configuración de la Function | Tiene la contraseña del administrador SQL | No tiene nada: el token solo se consigue **desde dentro** de la Function |
| Caducidad | La contraseña no caduca | Cada token dura ~1 hora y Azure lo renueva solo |
| Coste | 0 € | **0 €** (la identidad administrada y el administrador de Entra son gratis) |

```
 Function App ──1. pide un token──> Microsoft Entra ID (identidad func-agroeco-dev-XXXXX)
      │                                     │
      │ <────────── 2. token (~1 h) ────────┘
      │
      └──3. se conecta con el token──> Azure SQL ──> usuario [func-agroeco-dev-XXXXX]
                                                    (CREATE TABLE, CREATE VIEW, ALTER,
                                                     REFERENCES, INSERT, SELECT en dbo)
```

---

## ⚠️ ¿Hay alguna limitación con la suscripción de prueba y una cuenta personal?

La suscripción de prueba se creó con una **cuenta personal de Microsoft**. Al darte de alta, Azure creó un
directorio de Microsoft Entra (*Default Directory*), y tu cuenta personal está dentro de él como usuario
**externo**: su nombre de usuario acaba en `#EXT#@<directorio>.onmicrosoft.com`.

Esto dice la documentación de Microsoft:

| Pregunta | Respuesta | Fuente |
|---|---|---|
| ¿Puede una cuenta personal o externa ser administrador de Entra del servidor SQL? | **Sí**: *"Guest users can also be set as the Microsoft Entra admin for the logical server"*. Incluye cuentas *"Outlook, Windows Live Mail"* | [Guest users](https://learn.microsoft.com/en-us/azure/azure-sql/database/authentication-aad-guest-users) |
| ¿Tiene que poder leer el directorio? | Sí, para crear usuarios de otras identidades. Tú eres el administrador global del directorio, así que puedes | Misma página |
| ¿Hacen falta permisos de Microsoft Graph o el rol *Directory Readers* para el servidor? | **No**, si el `CREATE USER` lo ejecuta un **usuario** (tú) y no una aplicación | [Overview](https://learn.microsoft.com/en-us/azure/azure-sql/database/authentication-aad-overview), [Configure](https://learn.microsoft.com/en-us/azure/azure-sql/database/authentication-aad-configure) |
| ¿Admite el Query editor el inicio de sesión con Entra? | Sí. La página no menciona ninguna limitación para cuentas personales | [Query editor](https://learn.microsoft.com/en-us/azure/azure-sql/database/query-editor) |
| ¿Hace falta un administrador de Entra para que entre la identidad de la Function? | **Sí**: sin administrador no funciona ninguna conexión de Entra | Overview |

**Conclusión:** no hay ninguna limitación documentada, y el plan es usar **tu propio usuario** como
administrador de Entra. Si al probarlo algo falla con tu cuenta personal, hay dos alternativas, las dos gratis:

1. **Ejecutar el T-SQL desde tu ordenador** en lugar del Query editor (ver *Plan B* más abajo).
2. **Crear un usuario nativo del directorio**, por ejemplo `admin-sql@<directorio>.onmicrosoft.com`, desde
   *Microsoft Entra ID → Users → New user*, y nombrarlo administrador de Entra. Ese usuario no es externo, así
   que no le afecta nada de lo anterior.

---

## 🧱 Qué cambia en el código

| Archivo | Cambio |
|---|---|
| `infra/modulos/recursos.bicep` | `identity: { type: 'SystemAssigned' }` en la Function App |
| | Recurso `Microsoft.Sql/servers/administrators` (*ActiveDirectory*): tu usuario como administrador de Entra. Se muestra como `admin-entra-agroeco` |
| | `SQL_CADENA_CONEXION` sin `UID`/`PWD`, con `Authentication=ActiveDirectoryMSI` |
| | Se **mantiene** el usuario SQL con contraseña como acceso de emergencia (la Function ya no lo usa) |
| `infra/main.bicep` | Parámetro `sqlAdminEntraId` (Object ID de tu usuario) |
| `function_app/requirements.txt` | `azure-identity`: la librería con la que `mssql-python` pide el token |
| `src/carga_sql.py` | Escribe en el log cómo se autentica (*"Conectando a Azure SQL con identidad administrada (sin contraseña)"*) y no reintenta si el fallo es del token |
| `function_app/function_app.py` | Silencia los logs de cada petición HTTP de las librerías de Azure (menos ruido y menos cuota de logs) |
| `scripts/desplegar.ps1` / `.sh` | Leen tu Object ID con `az ad signed-in-user show` y se lo pasan al Bicep. No se guarda en ningún archivo |
| `.github/workflows/desplegar.yml` | Secreto opcional `SQL_ADMIN_ENTRA_ID` |
| `sql/03_usuario_identidad.sql` | El T-SQL que crea el usuario de la identidad (se ejecuta una vez, a mano) |
| `.env.example` | Opción A (`ActiveDirectoryDefault`, sin contraseña) y opción B (usuario SQL) para ejecutar en local |

El **Object ID** de tu usuario no es una contraseña, pero es un identificador personal: no está en el
repositorio. `desplegar.ps1` lo lee de tu sesión, y GitHub lo toma del secreto `SQL_ADMIN_ENTRA_ID`. Si
GitHub no tiene el secreto, el despliegue **no toca** el administrador que ya existe (modo incremental).

---

## 🔐 ¿Hacen falta asignaciones de roles?

**No.** Los permisos de la identidad dentro de la base de datos se dan con **T-SQL** (`GRANT`), no con roles de
Azure (RBAC). El administrador de Entra es una propiedad del servidor SQL, y el rol **Contributor** puede
cambiarla. Por eso GitHub sigue teniendo **solo Contributor** y no necesita *Role Based Access Control
Administrator*.

Sí harían falta asignaciones de roles si **también** el Storage pasara a identidad administrada. Para eso habría
que dar a la identidad los roles *Storage Blob Data Owner*, *Storage Queue Data Contributor* y *Storage Table Data
Contributor*. No forma parte de esta fase.

---

## 🧱 ¿Se puede quitar la regla de firewall `AllowAllWindowsAzureIps`?

**No, se mantiene.** La identidad administrada cambia **cómo** se autentica la Function, no **desde dónde** se
conecta. Las opciones para cerrar la red serían:

| Opción | ¿Sirve aquí? | Por qué |
|---|---|---|
| Regla de firewall con la IP de la Function | ❌ | En Flex Consumption sin red virtual, la Function **no tiene una IP de salida fija** |
| Red virtual + *service endpoint* de SQL (gratis) | ❌ | Tienen que estar en la **misma región**: *"You must host all these referenced subnets in the same geographic region that hosts the database"* ([fuente](https://learn.microsoft.com/en-us/azure/azure-sql/database/vnet-service-endpoint-rule-overview)). La Function está en Spain Central y SQL en France Central |
| Red virtual + *private endpoint* | ✅ | Pero **tiene coste**: unos 7 €/mes. Queda como mejora opcional |

Lo que sí mejora: aunque cualquier servicio de Azure pueda **llegar** al servidor, para **entrar** hace falta un
token de Entra de una identidad con usuario en la base de datos, o la contraseña del administrador SQL. Esa
contraseña ya no está en la Function.

**Siguiente paso opcional (gratis):** activar *Microsoft Entra authentication only* en el servidor para
desactivar del todo el usuario SQL con contraseña. Se deja para después de comprobar que todo funciona, porque
entonces la opción B del `.env` y el inicio de sesión con usuario SQL del Query editor dejarían de funcionar.

---

## 🧪 Pasos (en este orden)

1. **What-if y despliegue** con `.\scripts\desplegar.ps1`: activa la identidad, pone el administrador de Entra y
   cambia la cadena de conexión.
2. **Crear el usuario de la identidad** en la base de datos (abajo).
3. **Probar** con `.\scripts\ejecutar_manual.ps1`: deben salir las mismas filas de siempre.

> El what-if de este proyecto **no mostró** `identity.type: SystemAssigned`, pero la identidad sí se creó.
> Después de desplegar, compruébalo siempre con
> `az functionapp identity show -g rg-agroeco-dev -n <function> --query type -o tsv` (debe devolver `SystemAssigned`).

Entre el paso 1 y el 2, la Function **no puede entrar en SQL**, porque su usuario aún no existe. Hazlos
seguidos; el temporizador solo se ejecuta el día 1 de cada mes.

### Crear el usuario en el Query editor (con Microsoft Entra authentication)

1. Portal → **SQL databases** → `sqldb-agroeco` → **Query editor (preview)**.
2. Elige **Microsoft Entra authentication** y pulsa **Continue as `<tu usuario>`**. No uses *SQL server
   authentication*: `FROM EXTERNAL PROVIDER` solo funciona con una sesión de Entra.
3. Si sale *"Cannot open server ... Client with IP address ... is not allowed"*, tu IP ha cambiado: vuelve a
   desplegar con `-IpCliente`.
4. Si la base de datos está en pausa, el primer intento puede tardar ~1 minuto o fallar: repítelo.
5. Pega `sql/03_usuario_identidad.sql`, cambia `func-agroeco-dev-XXXXX` por el nombre de tu Function App
   (las 3 veces) y pulsa **Run**.
6. La consulta final debe mostrar 7 filas: `CONNECT`, `CREATE TABLE` y `CREATE VIEW` (*DATABASE*), y
   `ALTER`, `INSERT`, `REFERENCES` y `SELECT` (*SCHEMA*).

### Plan B: si `FROM EXTERNAL PROVIDER` falla

Si SQL no encuentra la identidad por su nombre (un error del tipo *"Principal ... could not be found"*), en ese caso se crea el usuario con su **SID**, que se calcula a partir del
*Application (client) ID* de la identidad y no necesita buscar en el directorio:

```powershell
# Solo lectura: Application ID de la identidad de la Function
$App   = az functionapp list -g rg-agroeco-dev --query "[0].name" -o tsv
$PrincipalId = az functionapp identity show -g rg-agroeco-dev -n $App --query principalId -o tsv
az ad sp show --id $PrincipalId --query appId -o tsv
```

```sql
-- 1. Convierte el Application ID en SID (cambia el GUID)
SELECT CAST(CAST('00000000-0000-0000-0000-000000000000' AS UNIQUEIDENTIFIER) AS VARBINARY(16));
-- 2. Crea el usuario con ese valor (0x...) y después ejecuta los GRANT de 03_usuario_identidad.sql
CREATE USER [func-agroeco-dev-XXXXX] WITH SID = 0x..., TYPE = E;
```

Si fallara también el inicio de sesión con Entra en el Query editor, el mismo T-SQL se puede ejecutar desde tu
ordenador con `Authentication=ActiveDirectoryDefault` (tu `az login`).

---

### Resultado de la prueba (11/11/2026)

- `az functionapp identity show` → `SystemAssigned`. `az sql server ad-admin list` → `admin-entra-agroeco`.
- El usuario y los `GRANT` se crearon en el Query editor con *Microsoft Entra authentication*. Con el usuario
  SQL, `FROM EXTERNAL PROVIDER` no funciona.
- `ejecutar_manual.ps1` cargó las mismas filas que antes: 28 / 17 / 13.529 / 620 / 2.015 / 1.395.

---

## 💻 Ejecutar en local

El código es el mismo; solo cambia la cadena de conexión del `.env` (ver `.env.example`):

| Opción | Cadena | Requisitos |
|---|---|---|
| **A, sin contraseña** | `...;Authentication=ActiveDirectoryDefault;...` | `az login` hecho, tu IP en el firewall (`-IpCliente`) |
| B, emergencia | `...;UID=<usuario>;PWD=<contraseña>;...` | La contraseña del administrador SQL |

Con la opción A, `mssql-python` usa tu sesión de Azure CLI. Entras como administrador de Entra, así que
puedes crear las tablas igual que la Function.

---

## 🔎 Comprobarlo en el portal

- **Function App → Settings → Identity → System assigned**: *Status: On*.
- **SQL servers → `sql-agroeco-dev-XXXXX` → Settings → Microsoft Entra ID**: administrador `admin-entra-agroeco`.
- **Function App → Settings → Environment variables → `SQL_CADENA_CONEXION`**: contiene
  `Authentication=ActiveDirectoryMSI` y **no** contiene `PWD`.
- **Application Insights → Logs** (o *Log stream*): la línea *"Conectando a Azure SQL con identidad administrada
  (sin contraseña)"*.

## 🧯 Errores típicos

| Error | Causa | Solución |
|---|---|---|
| `Login failed for user '<token-identified principal>'` | El usuario de la identidad no existe en la base de datos, o tiene otro nombre | Ejecuta `03_usuario_identidad.sql` con el nombre exacto de la Function App |
| `Failed to acquire an Entra ID access token for authentication type 'msi'` | La Function no tiene identidad o falta `azure-identity` | Comprueba *Identity → On* y vuelve a desplegar el código |
| `CREATE USER ... permission denied` / `Principal ... could not be found` | No has entrado con Entra, o SQL no encuentra la identidad | Entra con *Microsoft Entra authentication*, o usa el *Plan B* |
| `The CREATE TABLE permission was denied` (en el pipeline) | Faltan los `GRANT` | Ejecuta la parte 2 de `03_usuario_identidad.sql` |
