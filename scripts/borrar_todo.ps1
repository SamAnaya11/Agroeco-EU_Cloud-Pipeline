<#
.SYNOPSIS
    Borra el grupo de recursos completo del proyecto (y TODO lo que contiene).

.DESCRIPTION
    Elimina: Storage Account (con todos los datos de raw/ y processed/), servidor
    y base de datos SQL, Function App y su plan, Application Insights y Log Analytics.
    NO se puede deshacer. Pide confirmación escribiendo el nombre del grupo.

    No borra el presupuesto (está a nivel de suscripción y es gratis). Para borrarlo:
        az consumption budget delete --budget-name presupuesto-agroeco

.EXAMPLE
    .\scripts\borrar_todo.ps1
#>
param(
    [string]$Grupo = "rg-agroeco-dev"
)

$ErrorActionPreference = "Stop"

$Existe = az group exists --name $Grupo
if ($LASTEXITCODE -ne 0) { throw "No has iniciado sesión. Ejecuta: az login" }
if ($Existe -ne "true") {
    Write-Host "El grupo de recursos '$Grupo' no existe. No hay nada que borrar."
    return
}

Write-Host "`nSe van a BORRAR estos recursos de forma PERMANENTE:" -ForegroundColor Yellow
az resource list --resource-group $Grupo --query "[].{Nombre:name, Tipo:type}" -o table

$Respuesta = Read-Host "`nEscribe el nombre del grupo ($Grupo) para confirmar, o pulsa Enter para cancelar"
if ($Respuesta -ne $Grupo) {
    Write-Host "Cancelado. No se ha borrado nada." -ForegroundColor Green
    return
}

Write-Host "Borrando $Grupo (puede tardar 5-10 minutos)..."
az group delete --name $Grupo --yes
if ($LASTEXITCODE -ne 0) { throw "Ha fallado el borrado del grupo de recursos" }

Write-Host "[OK] Grupo de recursos '$Grupo' eliminado." -ForegroundColor Green
Write-Host "     El presupuesto 'presupuesto-agroeco' sigue activo (es gratis)."
