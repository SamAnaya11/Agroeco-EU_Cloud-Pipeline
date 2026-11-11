# 🔁 CI/CD con GitHub Actions y OIDC

Cada vez que se sube código a `main`, GitHub Actions despliega el proyecto en Azure solo
(workflow [`.github/workflows/desplegar.yml`](../.github/workflows/desplegar.yml)).
Este documento explica **cómo se identifica GitHub ante Azure sin guardar ninguna contraseña**.

---

## 🔑 OIDC frente a *client secret*

Para que GitHub pueda desplegar, necesita una **identidad** en Azure: una aplicación de Microsoft Entra ID
con permisos sobre el grupo de recursos. La pregunta es cómo demuestra GitHub que es esa aplicación.

### Opción antigua: *client secret* (una contraseña)

```
 Azure genera una contraseña ──> la copias en un secreto de GitHub ──> GitHub la envía a Azure en cada despliegue
```

- La contraseña **dura meses o años** y sirve desde cualquier sitio: si se filtra (un log, un fork, un error),
  cualquiera puede usarla hasta que caduque o se borre.
- **Caduca**: hay que acordarse de renovarla y volver a copiarla en GitHub.

### Opción actual: OIDC (credencial federada)

```
 1. GitHub Actions pide a GitHub un token firmado que dice:
       "soy el workflow del repositorio SamAnaya11/Agroeco-EU_Cloud-Pipeline, rama main"
 2. GitHub lo envía a Microsoft Entra ID
 3. Entra ID comprueba la firma y que el repositorio y la rama coinciden con la
    credencial federada configurada ──> devuelve un token de acceso a Azure que dura ~1 hora
```

- **No existe ninguna contraseña** que guardar, renovar o filtrar.
- El token de acceso **dura minutos** y solo se consigue desde **ese repositorio y esa rama**. Un fork u otra rama
  no puede usarlo.
- Lo recomiendan Microsoft y GitHub.

| | Client secret | OIDC |
|---|---|---|
| ¿Hay contraseña guardada en GitHub? | Sí | **No** |
| Duración | Meses o años | **~1 hora** por ejecución |
| ¿Desde dónde se puede usar? | Desde cualquier sitio | **Solo desde este repositorio y la rama `main`** |
| ¿Caduca y hay que renovarla? | Sí | No |
| Coste | Gratis | Gratis |

Los secretos de GitHub que siguen haciendo falta (`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`)
son **identificadores**, no contraseñas: sin el token firmado por GitHub no sirven para entrar. Se guardan como
secretos igualmente para no publicarlos en un repositorio público.

---

## 🛡️ Permisos: rol Contributor solo sobre el grupo de recursos

La identidad de GitHub tiene el rol **Contributor** solo sobre `rg-agroeco-dev`: puede crear y cambiar recursos
**dentro de ese grupo** y nada más. No puede tocar otros grupos ni la suscripción, ni dar permisos a nadie.

Consecuencias:

| Tarea | ¿La hace GitHub? | Por qué |
|---|---|---|
| Desplegar `infra/modulos/recursos.bicep` | ✅ | Despliegue dentro del grupo (`az deployment group create`) |
| Crear el Action Group y la alerta de fallos | ✅ | Son recursos `Microsoft.Insights` dentro del grupo (ver [`alertas.md`](alertas.md)) |
| Activar la identidad administrada de la Function y poner el administrador de Entra del servidor SQL | ✅ | Son propiedades de recursos del grupo (ver [`identidad_sql.md`](identidad_sql.md)) |
| Crear el usuario de la identidad dentro de la base de datos | ❌ | Es T-SQL, no Azure: se hace una vez a mano en el Query editor |
| Subir el código de la Function | ✅ | Recurso dentro del grupo |
| Desplegar `infra/main.bicep` (crea el grupo) | ❌ | Es un despliegue de **suscripción** |
| Registrar proveedores de recursos | ❌ | Es una acción de **suscripción** (ya están registrados) |
| Crear asignaciones de roles | ❌ | Contributor no puede dar permisos (ver abajo) |

Por eso el **primer despliegue** (el que crea el grupo de recursos) se hace desde tu ordenador con
`scripts/desplegar.ps1`, y GitHub se encarga de los siguientes.

> ⚠️ Si borras todo con `borrar_todo`, se borra también el permiso de GitHub (estaba dentro del grupo).
> Para volver: `desplegar.ps1` y después repetir el paso 3 de los comandos de abajo (`az role assignment create`,
> con las variables del paso 0). La aplicación y la credencial federada no se borran: están en Entra ID, no en el grupo.

### ¿Y si el Bicep crea asignaciones de roles?

Hoy el Bicep **no crea ninguna**, así que Contributor es suficiente.

La **Fase 3B** tampoco las necesita. La Function entra en SQL con su identidad administrada, pero sus permisos
dentro de la base de datos se dan con **T-SQL** (`GRANT`), no con roles de Azure. El administrador de Entra del
servidor es una propiedad del servidor, y Contributor puede cambiarla.

Sí harían falta si en el futuro el **Storage** pasara a identidad administrada (roles *Storage Blob Data
Owner*, etc.). Para eso hace falta el permiso `Microsoft.Authorization/roleAssignments/write`, que
**Contributor no tiene**. Opciones:

| Rol extra sobre el grupo | ¿Recomendado? |
|---|---|
| **Role Based Access Control Administrator** con una **condición** que solo le deje asignar los roles concretos que usa el Bicep | ✅ Mínimo privilegio |
| User Access Administrator | ⚠️ Puede asignar cualquier rol, incluido Owner |
| Owner | ❌ Demasiado amplio |

Se añadiría solo si hace falta.

---

## 🧰 Comandos para crear la identidad (se ejecutan una sola vez)

En PowerShell, desde la carpeta del proyecto y con `az login` hecho. **Todo es gratis**: las aplicaciones,
service principals, asignaciones de roles y credenciales federadas de Microsoft Entra ID no tienen coste.

```powershell
# 0. Datos de tu suscripción (solo lectura). Se guardan en variables; no los copies en ningún archivo.
$Suscripcion = az account show --query id -o tsv
$Tenant      = az account show --query tenantId -o tsv
$GrupoId     = az group show --name rg-agroeco-dev --query id -o tsv

# 1. Aplicación en Microsoft Entra ID: la "ficha" de la identidad de GitHub
$AppId = az ad app create --display-name "github-agroeco-despliegue" --query appId -o tsv

# 2. Service principal: la identidad real de esa aplicación en tu directorio (a quien se le dan permisos)
$SpId = az ad sp create --id $AppId --query id -o tsv

# 3. Rol Contributor SOLO sobre el grupo rg-agroeco-dev
az role assignment create --assignee-object-id $SpId --assignee-principal-type ServicePrincipal `
  --role Contributor --scope $GrupoId

# 4. Credenciales federadas: Azure confía en los tokens de GitHub de este repositorio y la rama main.
#    Son dos porque GitHub puede escribir el "subject" de dos formas (ver AADSTS700213 más abajo):
az ad app federated-credential create --id $AppId --parameters "@scripts/credencial_federada.json"      # formato clásico
az ad app federated-credential create --id $AppId --parameters "@scripts/credencial_federada_ids.json"  # formato con IDs
```

| Archivo | Nombre de la credencial | `subject` |
|---|---|---|
| `scripts/credencial_federada.json` | `github-agroeco-main` | `repo:SamAnaya11/Agroeco-EU_Cloud-Pipeline:ref:refs/heads/main` |
| `scripts/credencial_federada_ids.json` | `github-agroeco-main-ids` | `repo:SamAnaya11@200885290/Agroeco-EU_Cloud-Pipeline@1452895973:ref:refs/heads/main` |

En este proyecto, la que se usa es la de **IDs**. Los números son los IDs públicos de la cuenta y del
repositorio en GitHub; no son secretos.

Los valores para los secretos de GitHub salen de `$AppId`, `$Tenant` y `$Suscripcion`. Ver la tabla de
secretos en el [README](../README.md#-cicd-con-github-actions).

### Comprobarlo en el portal

- **Microsoft Entra ID → App registrations → All applications → github-agroeco-despliegue →
  Certificates & secrets → Federated credentials**: deben aparecer `github-agroeco-main` y
  `github-agroeco-main-ids`. En *Client secrets* no debe haber ninguno.
- **Resource groups → rg-agroeco-dev → Access control (IAM) → Role assignments**:
  `github-agroeco-despliegue` con el rol *Contributor*.

### Errores típicos

| Error en GitHub Actions | Causa |
|---|---|
| `AADSTS700213: No matching federated identity record found` | El `subject` que envía GitHub no coincide **exactamente** con ninguna credencial federada. Ver abajo |
| `AADSTS70021: No matching federated identity record found` | Igual que el anterior, en su versión más antigua: el repositorio o la rama no coinciden (mayúsculas incluidas) |
| `AuthorizationFailed` | Falta la asignación de rol, o se intentó algo fuera del grupo de recursos |
| `ResourceGroupNotFound` | El grupo no existe: despliega primero con `scripts/desplegar.ps1` |

#### AADSTS700213: el *subject* con IDs inmutables

**Qué pasó en este proyecto:** la primera ejecución del trabajo `infraestructura` falló al iniciar sesión.
La credencial federada esperaba el formato clásico del *subject*, pero GitHub envió uno que incluye los
**IDs numéricos** de la cuenta y del repositorio:

```
Esperado (formato clásico):  repo:SamAnaya11/Agroeco-EU_Cloud-Pipeline:ref:refs/heads/main
Enviado  (formato con IDs):  repo:SamAnaya11@200885290/Agroeco-EU_Cloud-Pipeline@1452895973:ref:refs/heads/main
```

Los IDs no cambian aunque se renombre la cuenta o el repositorio. Así nadie puede crear después un
repositorio con el mismo nombre y heredar el acceso a Azure.

**Cómo leer el *subject* que envía GitHub.** Aparece en dos sitios del log del paso *Iniciar sesión en Azure (OIDC)*:

1. En el propio error: `AADSTS700213: No matching federated identity record found for presented assertion
   subject 'repo:...'`. Lo que va entre comillas es el *subject* exacto.
2. Al principio del paso, en *Federated token details* → `subject claim - repo:...`. Se muestra también
   cuando el inicio de sesión funciona (ver la captura `09b_github_actions_login.png`).

Hay que copiarlo **tal cual**, carácter a carácter. Azure compara el texto exacto, incluidas las mayúsculas.

**Solución 1: portal**

1. **Microsoft Entra ID → App registrations → All applications → github-agroeco-despliegue**.
2. **Certificates & secrets → Federated credentials → + Add credential**.
3. *Federated credential scenario*: **Other issuer**. El escenario "GitHub Actions deploying Azure resources"
   construye el *subject* en el formato clásico, así que no sirve para el formato con IDs.
4. *Issuer*: `https://token.actions.githubusercontent.com`
5. *Type*: **Explicit subject identifier**. *Value*: el *subject* copiado del log.
6. *Name*: `github-agroeco-main-ids`. *Audience*: `api://AzureADTokenExchange` (el valor por defecto).
7. **Add**. Después, en GitHub: **Actions → la ejecución fallida → Re-run failed jobs**.

**Solución 2: Azure CLI**

Se pone el *subject* en un archivo JSON (aquí, `scripts/credencial_federada_ids.json`) y se crea la credencial:

```powershell
# ID de la aplicación ya creada (solo lectura)
$AppId = az ad app list --display-name "github-agroeco-despliegue" --query "[0].appId" -o tsv

# Crea la credencial federada con el subject con IDs (gratis)
az ad app federated-credential create --id $AppId --parameters "@scripts/credencial_federada_ids.json"

# Comprobar: deben salir las dos credenciales
az ad app federated-credential list --id $AppId --query "[].{nombre:name, subject:subject}" -o table
```

La credencial clásica (`github-agroeco-main`) se puede dejar: no da más acceso, porque solo sirve para el
mismo repositorio y la misma rama.
