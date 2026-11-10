// =====================================================================
// recursos.bicep
// Todos los recursos del proyecto, dentro del grupo de recursos:
//
//   1. Storage Account    -> contenedores raw, processed y despliegue
//   2. Log Analytics      -> almacén de logs (lo usa Application Insights)
//   3. Application Insights -> logs y monitorización de la Function
//   4. Azure SQL          -> servidor lógico + base de datos (oferta gratuita)
//   5. Function App       -> plan Flex Consumption + aplicación Python
//
// Coste: ver README, sección "Costes". Todo está configurado para el
// mínimo coste posible.
// =====================================================================

// Longitudes limitadas para que el nombre de la Storage Account (máx. 24) siempre quepa:
// 'st' (2) + prefijo (máx. 8) + entorno (máx. 4) + sufijo (5) = máx. 19
@minLength(3)
@maxLength(8)
param prefijo string
@minLength(1)
@maxLength(4)
param entorno string
@minLength(5)
@maxLength(5)
param sufijo string
param ubicacion string
param ubicacionSql string
param sqlUsuarioAdmin string
@secure()
param sqlContrasenaAdmin string
param ipCliente string
param etiquetas object

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
// (Fase 3: se sustituirá por identidad administrada.)
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

// Regla especial 0.0.0.0: permite conexiones desde servicios de Azure
// (la Function App no tiene una IP fija). Fase 3 puede endurecer esto.
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

// Cadena de conexión para el driver mssql-python. Solo admite una lista cerrada de
// palabras clave (Server, Database, UID, PWD, Encrypt, TrustServerCertificate...).
// "Connection Timeout" NO es válida: el tiempo de espera se pasa en el código
// (src/carga_sql.py -> mssql_python.connect(..., timeout=60)).
var cadenaSql = 'Server=tcp:${servidorSql.properties.fullyQualifiedDomainName},1433;Database=${baseDatos.name};UID=${sqlUsuarioAdmin};PWD=${sqlContrasenaAdmin};Encrypt=yes;TrustServerCertificate=no;'

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
          name: 'SQL_CADENA_CONEXION'                     // lo lee src/pipeline.py
          value: cadenaSql
        }
      ]
    }
  }
}

// Salidas (sin secretos)
output functionApp string = functionApp.name
output hostFunction string = functionApp.properties.defaultHostName
output storageAccount string = storage.name
output servidorSql string = servidorSql.properties.fullyQualifiedDomainName
output baseDatos string = baseDatos.name
