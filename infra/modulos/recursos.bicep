// =====================================================================
// recursos.bicep
// Todos los recursos del proyecto, dentro del grupo de recursos:
//
//   1. Storage Account    -> contenedores raw, processed y despliegue
//   2. Log Analytics      -> almacén de logs (lo usa Application Insights)
//   3. Application Insights -> logs y monitorización de la Function
//   4. Azure SQL          -> servidor lógico + base de datos (oferta gratuita)
//                            + administrador de Microsoft Entra (Fase 3B)
//   5. Function App       -> plan Flex Consumption + aplicación Python
//                            + identidad administrada para entrar en SQL sin contraseña
//   6. Alertas            -> correo si falla la Function (solo si se pasa correoAlertas)
//
// Coste: ver README, sección "Costes". Todo está configurado para el
// mínimo coste posible.
//
// Se puede desplegar de dos formas:
//   - Desde main.bicep (scripts/desplegar.ps1): crea también el grupo de recursos.
//   - Directamente sobre el grupo (GitHub Actions):
//       az deployment group create -g rg-agroeco-dev --template-file infra/modulos/recursos.bicep ...
//     GitHub solo tiene permisos sobre el grupo, no sobre la suscripción.
// Por eso el sufijo y las etiquetas se calculan AQUÍ: así los nombres son los
// mismos se despliegue de una forma u otra.
// =====================================================================

// Longitudes limitadas para que el nombre de la Storage Account (máx. 24) siempre quepa:
// 'st' (2) + prefijo (máx. 8) + entorno (máx. 4) + sufijo (5) = máx. 19
@minLength(3)
@maxLength(8)
param prefijo string
@minLength(1)
@maxLength(4)
param entorno string
param ubicacion string
param ubicacionSql string
param sqlUsuarioAdmin string
@secure()
@minLength(12)
param sqlContrasenaAdmin string
param ipCliente string = ''

// ID de objeto (Object ID) de tu usuario de Microsoft Entra: será el administrador
// de Entra del servidor SQL (el que puede crear el usuario de la identidad de la
// Function). No es una contraseña, pero tampoco se guarda en el repositorio:
// desplegar.ps1 lo lee de tu sesión de Azure CLI y GitHub lo toma del secreto
// SQL_ADMIN_ENTRA_ID. Vacío = no se toca el administrador de Entra.
param sqlAdminEntraId string = ''

// Correo para las alertas. @secure() para que NO quede visible en el historial
// de despliegues del portal. Vacío = no se crean (ni se borran) las alertas.
@secure()
param correoAlertas string = ''

// Sufijo de 5 caracteres, siempre el mismo para la misma suscripción
// (solo en los nombres que deben ser únicos en todo Azure)
var sufijo = take(uniqueString(subscription().id, prefijo, entorno), 5)

var etiquetas = {
  proyecto: prefijo
  entorno: entorno
  gestionadoPor: 'bicep'
}

// ---------------------------------------------------------------------
// Nombres
// ---------------------------------------------------------------------
// Storage: solo minúsculas y números, 3-24 caracteres, único en Azure
var nombreStorage = 'st${prefijo}${entorno}${sufijo}'
var nombreLogAnalytics = 'log-${prefijo}-${entorno}'
var nombreAppInsights = 'appi-${prefijo}-${entorno}'
var nombreServidorSql = 'sql-${prefijo}-${entorno}-${sufijo}'   // único en Azure
var nombreBaseDatos = 'sqldb-${prefijo}'
var nombrePlan = 'asp-${prefijo}-${entorno}'
var nombreFunctionApp = 'func-${prefijo}-${entorno}-${sufijo}'   // único en Azure
var nombreGrupoAcciones = 'ag-${prefijo}-${entorno}'
var nombreAlertaFallos = 'alerta-fallos-${prefijo}-${entorno}'

var contenedorDespliegue = 'despliegue'   // aquí Flex Consumption guarda el paquete de código

// =====================================================================
// 1. Storage Account
// =====================================================================
// Standard_LRS = la opción más barata (3 copias en un mismo centro de datos)
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: nombreStorage
  location: ubicacion
  tags: etiquetas
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    accessTier: 'Hot'
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false   // ningún archivo es público
  }
}

resource servicioBlob 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource contenedorRaw 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: servicioBlob
  name: 'raw'
}

resource contenedorProcessed 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: servicioBlob
  name: 'processed'
}

resource contenedorCodigo 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: servicioBlob
  name: contenedorDespliegue
}

// Cadena de conexión construida con la clave de la cuenta.
// Solo se guarda en la configuración de la Function App, nunca en el repositorio.
// (La Fase 3B solo quita la contraseña de SQL. Pasar el Storage a identidad
// administrada exigiría asignaciones de roles: ver docs/identidad_sql.md.)
var cadenaStorage = 'DefaultEndpointsProtocol=https;AccountName=${storage.name};AccountKey=${storage.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'

// =====================================================================
// 2. Log Analytics + 3. Application Insights
// =====================================================================
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: nombreLogAnalytics
  location: ubicacion
  tags: etiquetas
  properties: {
    sku: {
      name: 'PerGB2018'        // pago por uso (los primeros 5 GB/mes son gratis)
    }
    retentionInDays: 30        // 30 días de retención no tienen coste extra
    workspaceCapping: {
      dailyQuotaGb: json('0.1') // tope de seguridad: máx. 0,1 GB de logs al día
    }
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: nombreAppInsights
  location: ubicacion
  tags: etiquetas
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
}

// =====================================================================
// 4. Azure SQL Database (oferta gratuita)
// =====================================================================
// El servidor lógico es gratis: solo agrupa bases de datos y guarda el firewall.
resource servidorSql 'Microsoft.Sql/servers@2023-08-01' = {
  name: nombreServidorSql
  location: ubicacionSql
  tags: etiquetas
  properties: {
    administratorLogin: sqlUsuarioAdmin
    administratorLoginPassword: sqlContrasenaAdmin
    version: '12.0'
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
  }
}

// Oferta gratuita: 100.000 vCore-segundos + 32 GB al mes, para siempre.
// Si se agota el cupo, la base de datos se PAUSA hasta el mes siguiente
// (AutoPause) en lugar de cobrar. NO cambiar a 'BillOverUsage'.
//
// La configuración coincide con la plantilla que genera el portal para la
// base de datos gratuita ("Download a template for automation").
//
// REGIÓN: la oferta gratuita NO está disponible en Spain Central para la
// suscripción de prueba (error "ProvisioningDisabled"), por eso el servidor
// y la base de datos usan ubicacionSql = francecentral. Ver README,
// "Decisiones técnicas". Para comprobar una región: en la API de capacidades
// de SQL, el SKU GP_S_Gen5_2 debe incluir "supportedFreeLimitExhaustionBehaviors".
resource baseDatos 'Microsoft.Sql/servers/databases@2023-08-01' = {
  parent: servidorSql
  name: nombreBaseDatos
  location: ubicacionSql
  tags: etiquetas
  sku: {
    // Nombre completo del objetivo de servicio: General Purpose (GP),
    // Serverless (S), hardware Gen5, máximo 2 vCores (_2).
    // Equivale a name 'GP_S_Gen5' + family 'Gen5' + capacity 2 (la forma de la documentación).
    name: 'GP_S_Gen5_2'
    tier: 'GeneralPurpose'
  }
  properties: {
    useFreeLimit: true
    freeLimitExhaustionBehavior: 'AutoPause'
    minCapacity: json('0.5')                     // mínimo 0,5 vCores cuando está activa
    autoPauseDelay: 60                           // valor del portal; en la oferta gratuita Azure lo fija en 15 min
    maxSizeBytes: 34359738368                    // 32 GB, el máximo de la oferta gratuita
    zoneRedundant: false                         // sin copias en otras zonas (no lo admite la oferta gratuita)
    collation: 'SQL_Latin1_General_CP1_CI_AS'    // intercalación por defecto (no distingue mayúsculas)
    requestedBackupStorageRedundancy: 'Local'    // copias de seguridad LRS, la opción más barata
  }
}

// Administrador de Microsoft Entra del servidor (Fase 3B). Sin él, ninguna
// identidad de Entra (ni tu usuario ni la de la Function) puede entrar en SQL.
// Se mantiene también el usuario SQL con contraseña (sqlUsuarioAdmin) como
// acceso de emergencia; la Function ya NO lo usa.
// "login" es solo el nombre que se muestra; Azure identifica al usuario por "sid".
resource adminEntra 'Microsoft.Sql/servers/administrators@2023-08-01' = if (!empty(sqlAdminEntraId)) {
  parent: servidorSql
  name: 'ActiveDirectory'
  properties: {
    administratorType: 'ActiveDirectory'
    login: 'admin-entra-${prefijo}'
    sid: sqlAdminEntraId
    tenantId: tenant().tenantId
  }
}

// Regla especial 0.0.0.0: permite conexiones desde servicios de Azure.
// Se MANTIENE aunque la Function use identidad administrada: la identidad cambia
// CÓMO se autentica, no DESDE DÓNDE se conecta, y la Function (Flex Consumption,
// sin red virtual) no tiene una IP fija. Ver docs/identidad_sql.md.
resource firewallAzure 'Microsoft.Sql/servers/firewallRules@2023-08-01' = {
  parent: servidorSql
  name: 'AllowAllWindowsAzureIps'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

// Solo se crea si se pasa el parámetro ipCliente
resource firewallCliente 'Microsoft.Sql/servers/firewallRules@2023-08-01' = if (!empty(ipCliente)) {
  parent: servidorSql
  name: 'ip-cliente'
  properties: {
    startIpAddress: ipCliente
    endIpAddress: ipCliente
  }
}

// Cadena de conexión para el driver mssql-python, SIN usuario ni contraseña:
// "Authentication=ActiveDirectoryMSI" hace que el driver pida un token a la
// identidad administrada de la Function (con la librería azure-identity).
// Solo admite una lista cerrada de palabras clave: "Connection Timeout" NO es
// válida; el tiempo de espera se pasa en el código (src/carga_sql.py).
var cadenaSql = 'Server=tcp:${servidorSql.properties.fullyQualifiedDomainName},1433;Database=${baseDatos.name};Authentication=ActiveDirectoryMSI;Encrypt=yes;TrustServerCertificate=no;'

// =====================================================================
// 5. Function App (Flex Consumption, Linux, Python)
// =====================================================================
resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: nombrePlan
  location: ubicacion
  tags: etiquetas
  kind: 'functionapp'
  sku: {
    tier: 'FlexConsumption'
    name: 'FC1'
  }
  properties: {
    reserved: true   // obligatorio: Linux
  }
}

resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: nombreFunctionApp
  location: ubicacion
  // Además de las etiquetas comunes, Azure usa la etiqueta "hidden-link" para que
  // el portal enlace la Function App con su Application Insights (menú
  // "Application Insights" y pestaña "Monitoring"). La añade el portal por su
  // cuenta; si no la declaramos aquí, cada despliegue la borraría.
  tags: union(etiquetas, {
    'hidden-link: /app-insights-resource-id': appInsights.id
  })
  kind: 'functionapp,linux'
  // Identidad administrada asignada por el sistema (gratis): Azure crea una
  // identidad de Microsoft Entra con el MISMO nombre que la Function App y la
  // borra si se borra la Function. Con ella la Function entra en SQL sin contraseña.
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storage.properties.primaryEndpoints.blob}${contenedorCodigo.name}'
          authentication: {
            type: 'StorageAccountConnectionString'
            storageAccountConnectionStringName: 'DEPLOYMENT_STORAGE_CONNECTION_STRING'
          }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 1   // nunca más de 1 instancia a la vez: limita el coste
        instanceMemoryMB: 2048    // tamaño recomendado (pandas necesita memoria)
      }
      runtime: {
        name: 'python'
        version: '3.14'
      }
    }
    siteConfig: {
      // Configuración que la Function lee como variables de entorno.
      // En Flex Consumption NO se usan FUNCTIONS_WORKER_RUNTIME ni
      // FUNCTIONS_EXTENSION_VERSION (los sustituye functionAppConfig).
      appSettings: [
        {
          name: 'AzureWebJobsStorage'                     // lo necesita el runtime (p. ej. el temporizador)
          value: cadenaStorage
        }
        {
          name: 'DEPLOYMENT_STORAGE_CONNECTION_STRING'    // acceso al contenedor del código
          value: cadenaStorage
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'ALMACENAMIENTO_DATOS'                    // lo lee src/pipeline.py
          value: cadenaStorage
        }
        {
          name: 'SQL_CADENA_CONEXION'                     // lo lee src/pipeline.py (sin contraseña)
          value: cadenaSql
        }
      ]
    }
  }
}

// =====================================================================
// 6. Alertas: correo si falla pipeline_manual o pipeline_mensual
// =====================================================================
// Se crean solo si se pasa el parámetro correoAlertas.
var crearAlertas = !empty(correoAlertas)

// Action Group: A QUIÉN se avisa y cómo (aquí, un correo).
// Coste: los primeros 1.000 correos al mes son gratis.
resource grupoAcciones 'Microsoft.Insights/actionGroups@2023-01-01' = if (crearAlertas) {
  name: nombreGrupoAcciones
  location: 'global'
  tags: etiquetas
  properties: {
    groupShortName: take(prefijo, 12)   // aparece en el asunto del correo (máx. 12 caracteres)
    enabled: true
    emailReceivers: [
      {
        name: 'correo-aviso'
        emailAddress: correoAlertas
        useCommonAlertSchema: true      // formato de correo estándar de Azure Monitor
      }
    ]
  }
}

// Alerta de MÉTRICA sobre Application Insights: "Failed requests" (requests/failed).
// Cada ejecución de la Function (temporizador o HTTP) se registra como una
// "request"; si la función lanza un error, cuenta como fallida.
// En este proyecto solo hay dos funciones, así que cualquier fallo es de
// pipeline_manual o pipeline_mensual.
//
// Coste: 0 €. Una alerta de métrica sin dimensiones vigila 1 serie temporal y
// Azure Monitor incluye 10 gratis al mes. (Una alerta de búsqueda en logs
// costaría dinero cada mes según la frecuencia; por eso se usa esta.)
resource alertaFallos 'Microsoft.Insights/metricAlerts@2018-03-01' = if (crearAlertas) {
  name: nombreAlertaFallos
  location: 'global'
  tags: etiquetas
  properties: {
    description: 'Avisa por correo si falla una ejecución de pipeline_manual o pipeline_mensual.'
    severity: 1                   // 0 = crítica ... 4 = informativa
    enabled: true
    scopes: [
      appInsights.id
    ]
    evaluationFrequency: 'PT5M'   // se comprueba cada 5 minutos
    windowSize: 'PT15M'           // mirando los últimos 15 minutos
    autoMitigate: true            // se cierra sola cuando deja de haber fallos
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'ejecuciones-fallidas'
          metricNamespace: 'microsoft.insights/components'
          metricName: 'requests/failed'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0            // con 1 fallo ya avisa
        }
      ]
    }
    actions: [
      {
        actionGroupId: grupoAcciones.id
      }
    ]
  }
}

// Salidas (sin secretos)
output functionApp string = functionApp.name
output hostFunction string = functionApp.properties.defaultHostName
output storageAccount string = storage.name
output servidorSql string = servidorSql.properties.fullyQualifiedDomainName
output baseDatos string = baseDatos.name
