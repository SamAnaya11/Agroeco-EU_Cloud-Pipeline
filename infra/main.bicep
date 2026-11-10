// =====================================================================
// main.bicep
// Punto de entrada de la infraestructura. Se despliega a nivel de
// SUSCRIPCIÓN porque crea el grupo de recursos; después crea todo lo demás
// dentro de ese grupo con el módulo modulos/recursos.bicep.
//
// Convención de nombres (ver docs/arquitectura.md):
//   <abreviatura>-<prefijo>-<entorno>[-<sufijo>]
//   - abreviatura: la recomendada por Microsoft (rg, st, sql, func...)
//   - prefijo:     agroeco
//   - entorno:     dev
//   - sufijo:      5 caracteres calculados a partir de la suscripción; solo
//                  en recursos cuyo nombre debe ser único en todo Azure.
//
// Uso:  scripts/desplegar.ps1  (o scripts/desplegar.sh)
// =====================================================================

targetScope = 'subscription'

@description('Prefijo común de todos los recursos.')
@minLength(3)
@maxLength(8)
param prefijo string = 'agroeco'

@description('Entorno (dev, prod...). Forma parte de los nombres.')
@maxLength(4)
param entorno string = 'dev'

@description('Región de Azure de todos los recursos.')
param ubicacion string = 'spaincentral'

@description('Región del servidor y la base de datos SQL. En este proyecto es francecentral (ver main.parameters.example.json) porque la oferta gratuita no está disponible en spaincentral para la suscripción de prueba.')
param ubicacionSql string = ubicacion

@description('Usuario administrador del servidor SQL (no puede ser admin, sa, root...).')
param sqlUsuarioAdmin string = 'agroecoadmin'

@description('Contraseña del administrador SQL. NO se guarda en ningún archivo: Azure CLI la pide al desplegar.')
@secure()
@minLength(12)
param sqlContrasenaAdmin string

@description('Opcional: tu IP pública, para consultar la base de datos desde tu ordenador o el portal. Vacío = sin regla.')
param ipCliente string = ''

// Sufijo de 5 caracteres, siempre el mismo para la misma suscripción
var sufijo = take(uniqueString(subscription().id, prefijo, entorno), 5)

var etiquetas = {
  proyecto: prefijo
  entorno: entorno
  gestionadoPor: 'bicep'
}

resource grupo 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${prefijo}-${entorno}'
  location: ubicacion
  tags: etiquetas
}

module recursos 'modulos/recursos.bicep' = {
  name: 'recursos-${prefijo}-${entorno}'
  scope: grupo
  params: {
    prefijo: prefijo
    entorno: entorno
    sufijo: sufijo
    ubicacion: ubicacion
    ubicacionSql: ubicacionSql
    sqlUsuarioAdmin: sqlUsuarioAdmin
    sqlContrasenaAdmin: sqlContrasenaAdmin
    ipCliente: ipCliente
    etiquetas: etiquetas
  }
}

// Salidas (sin secretos): las usan los scripts de despliegue
output grupoRecursos string = grupo.name
output functionApp string = recursos.outputs.functionApp
output hostFunction string = recursos.outputs.hostFunction
output storageAccount string = recursos.outputs.storageAccount
output servidorSql string = recursos.outputs.servidorSql
output baseDatos string = recursos.outputs.baseDatos
