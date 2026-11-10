// =====================================================================
// presupuesto.bicep
// Presupuesto mensual con alertas por correo para TODA la suscripción.
//
// Se despliega a nivel de suscripción (no dentro de un grupo de recursos),
// por eso sigue existiendo aunque borres el grupo de recursos del proyecto.
//
// Un presupuesto NO detiene los recursos ni bloquea el gasto: solo avisa.
// Crear un presupuesto es gratis.
//
// Uso (ver README / docs para la explicación completa):
//   az deployment sub create --location northeurope \
//     --template-file infra/presupuesto.bicep \
//     --parameters correoAviso=tu_correo@ejemplo.com
// =====================================================================

targetScope = 'subscription'

@description('Nombre del presupuesto.')
param nombrePresupuesto string = 'presupuesto-agroeco'

@description('Importe máximo mensual. Va en la moneda de facturación de tu suscripción (EUR si facturas en euros).')
param importe int = 5

@description('Correo que recibirá los avisos. Se pasa al desplegar; no se guarda en el repositorio.')
param correoAviso string

@description('Primer día del mes actual (formato AAAA-MM-DD). Se calcula solo; Azure exige que sea día 1.')
param fechaInicio string = '${utcNow('yyyy-MM')}-01'

resource presupuesto 'Microsoft.Consumption/budgets@2023-11-01' = {
  name: nombrePresupuesto
  properties: {
    category: 'Cost'
    amount: importe
    timeGrain: 'Monthly' // el contador se reinicia cada mes
    timePeriod: {
      startDate: fechaInicio
      // sin endDate: Azure lo fija automáticamente a 10 años
    }
    notifications: {
      // Aviso temprano: ya has gastado el 50 % (2,50 €)
      real_50: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 50
        thresholdType: 'Actual'
        contactEmails: [ correoAviso ]
      }
      // Ya has gastado el 80 % (4 €)
      real_80: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 80
        thresholdType: 'Actual'
        contactEmails: [ correoAviso ]
      }
      // Has llegado al 100 % (5 €)
      real_100: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 100
        thresholdType: 'Actual'
        contactEmails: [ correoAviso ]
      }
      // Previsión: Azure calcula que a final de mes superarás los 5 €
      prevision_100: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 100
        thresholdType: 'Forecasted'
        contactEmails: [ correoAviso ]
      }
    }
  }
}

output nombre string = presupuesto.name
output inicio string = fechaInicio
