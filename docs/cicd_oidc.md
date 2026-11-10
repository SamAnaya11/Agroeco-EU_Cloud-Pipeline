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

En la **Fase 3** (identidad administrada), el Bicep sí creará asignaciones de roles. Por ejemplo, dar a la
Function permiso de lectura y escritura en el Storage. Para eso hace falta el permiso
`Microsoft.Authorization/roleAssignments/write`, que **Contributor no tiene**. Opciones:

| Rol extra sobre el grupo | ¿Recomendado? |
|---|---|
| **Role Based Access Control Administrator** con una **condición** que solo le deje asignar los roles concretos que usa el Bicep | ✅ Mínimo privilegio |
| User Access Administrator | ⚠️ Puede asignar cualquier rol, incluido Owner |
| Owner | ❌ Demasiado amplio |

Se añadirá en la Fase 3, solo si hace falta.

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

# 4. Credencial federada: Azure confía en los tokens de GitHub de este repositorio y la rama main
az ad app federated-credential create --id $AppId --parameters "@scripts/credencial_federada.json"
```

Los valores para los secretos de GitHub salen de `$AppId`, `$Tenant` y `$Suscripcion`. Ver la tabla de
secretos en el [README](../README.md#-cicd-con-github-actions).

### Comprobarlo en el portal

- **Microsoft Entra ID → App registrations → All applications → github-agroeco-despliegue →
  Certificates & secrets → Federated credentials**: debe aparecer `github-agroeco-main`. En
  *Client secrets* no debe haber ninguno.
- **Resource groups → rg-agroeco-dev → Access control (IAM) → Role assignments**:
  `github-agroeco-despliegue` con el rol *Contributor*.

### Errores típicos

| Error en GitHub Actions | Causa |
|---|---|
| `AADSTS70021: No matching federated identity record found` | El `subject` de la credencial no coincide con el repositorio o la rama (mayúsculas incluidas) |
| `AuthorizationFailed` | Falta la asignación de rol, o se intentó algo fuera del grupo de recursos |
| `ResourceGroupNotFound` | El grupo no existe: despliega primero con `scripts/desplegar.ps1` |
