# 🚨 Alerta si falla la Function (Fase 3, parte A)

Si `pipeline_mensual` o `pipeline_manual` fallan, llega un **correo** en unos 5-10 minutos.

```
 Function falla ──> Application Insights ──> Alerta de métrica ──────────> Action Group ──> 📧 correo
                    (request fallida)        alerta-fallos-agroeco-dev     ag-agroeco-dev
                                             "requests/failed > 0"
                                             cada 5 min, últimos 15 min
```

---

## 🧱 Qué se crea (en `infra/modulos/recursos.bicep`)

| Recurso | Nombre | Para qué |
|---|---|---|
| **Action Group** | `ag-agroeco-dev` | Define **a quién** se avisa y cómo: un correo |
| **Alerta de métrica** | `alerta-fallos-agroeco-dev` | Define **cuándo** se avisa: si hay al menos 1 ejecución fallida en los últimos 15 minutos |

Solo se crean si se pasa el parámetro `correoAlertas`. El correo es un parámetro `@secure()`: no está en ningún
archivo del repositorio ni se ve en el historial de despliegues del portal. Sí aparece, lógicamente, dentro del
propio Action Group.

### ¿Por qué una alerta de **métrica** y no de **logs**?

| Tipo de alerta | Cómo funciona | Coste mensual |
|---|---|---|
| **Métrica** `requests/failed` ✅ | Mira un contador que Application Insights ya calcula | **0 €**: vigila 1 serie temporal y Azure Monitor incluye **10 gratis al mes** |
| Búsqueda en logs (KQL) | Ejecuta una consulta cada X minutos | **De pago** desde la primera regla; el precio sube con la frecuencia |
| Correos del Action Group | — | **0 €**: los primeros **1.000 correos al mes** son gratis |

Cada ejecución de una Function, ya sea de temporizador o HTTP, queda registrada en Application Insights como una
*request*. Si la función lanza un error, la *request* cuenta como **fallida**. El proyecto solo tiene dos
funciones, así que cualquier fallo es de `pipeline_manual` o de `pipeline_mensual`. El correo trae un enlace a la
alerta; el detalle del error está en **Application Insights → Failures** o en **Logs**.

### Cambio en `pipeline_manual`

Antes, `pipeline_manual` capturaba el error y devolvía un 500 "controlado". Para Azure, esa ejecución podía contar
como **correcta**, y la alerta no la habría visto. Ahora registra el error y lo **vuelve a lanzar**, igual que
`pipeline_mensual`. El cliente sigue recibiendo un 500, pero sin el tipo de error; el detalle está en Application
Insights.

---

## 🔐 ¿Se puede desplegar con los permisos de GitHub?

Sí. El rol **Contributor** sobre `rg-agroeco-dev` permite crear cualquier recurso dentro del grupo, incluidos
`Microsoft.Insights/actionGroups` y `Microsoft.Insights/metricAlerts`. La alerta **no crea asignaciones de
roles**, que es lo único que Contributor no puede hacer.

Lo único que GitHub no puede hacer es **registrar el proveedor** `Microsoft.AlertsManagement` (gestiona las alertas
disparadas), porque es una acción de suscripción. Lo hace `desplegar.ps1` una sola vez, gratis.

## 📨 Cómo se pasa el correo

| Dónde | Cómo |
|---|---|
| `desplegar.ps1` | `.\scripts\desplegar.ps1 -IpCliente $MiIp -CorreoAlertas tu@correo.com` |
| `desplegar.sh` | `./scripts/desplegar.sh --ip <IP> --correo tu@correo.com` |
| GitHub Actions | Secreto `ALERTAS_CORREO` (*Settings → Secrets and variables → Actions*) |

Si no se pasa el correo, el despliegue **no crea ni borra** las alertas: Azure despliega en modo incremental y los
recursos que ya existen se mantienen.

---

## 🧪 Cómo probar la alerta (fallo controlado)

`pipeline_manual` tiene un interruptor de prueba: si la Function App tiene la variable de configuración
`PRUEBA_ALERTA=1`, falla a propósito **antes** de descargar nada. No toca el Storage ni la base de datos, y no
afecta al temporizador mensual.

```powershell
$Grupo = "rg-agroeco-dev"
$App   = az functionapp list --resource-group $Grupo --query "[0].name" -o tsv

# 1. Activa el fallo de prueba (la Function App se reinicia; gratis)
az functionapp config appsettings set --resource-group $Grupo --name $App --settings PRUEBA_ALERTA=1 --output none

# 2. Lanza el pipeline: debe terminar en [ERROR] con un 500
.\scripts\ejecutar_manual.ps1

# 3. Espera 5-10 minutos: llega el correo "Fired: Sev1 ... alerta-fallos-agroeco-dev"

# 4. Deshaz el cambio: borra la variable (la Function App se reinicia)
az functionapp config appsettings delete --resource-group $Grupo --name $App --setting-names PRUEBA_ALERTA --output none

# 5. Comprueba que vuelve a funcionar
.\scripts\ejecutar_manual.ps1
```

Unos 15-20 minutos después del fallo, cuando ya no hay fallos en la ventana, llega un segundo correo
**"Resolved"**: la alerta se cierra sola.

> Si lo olvidas, el siguiente despliegue de infraestructura también borra `PRUEBA_ALERTA`, porque el Bicep define
> la lista completa de variables de la Function App.

### Resultado de la prueba (10/11/2026)

- Con `PRUEBA_ALERTA=1`, `ejecutar_manual.ps1` terminó con un 500.
- Llegó el correo **"Fired: Sev1 Azure Monitor Alert alerta-fallos-agroeco-dev"** con *Metric value: 1*.
  Ver la captura `13_alerta_correo.png`.
- Después de borrar `PRUEBA_ALERTA`, `ejecutar_manual.ps1` volvió a cargar las mismas filas.

### Comprobarlo en el portal

- **Monitor → Alerts**: la alerta disparada, con severidad *Sev1*.
- **Monitor → Alerts → Alert rules**: `alerta-fallos-agroeco-dev`, *Enabled*.
- **Monitor → Alerts → Action groups**: `ag-agroeco-dev`, con el correo.
- **Application Insights → Failures**: la ejecución fallida y el error `RuntimeError`.
