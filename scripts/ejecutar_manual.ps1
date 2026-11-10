<#
.SYNOPSIS
    Ejecuta el pipeline ahora mismo, sin esperar al día 1 del mes.

.DESCRIPTION
    Llama a la función HTTP "pipeline_manual" con su clave. Solo LEE datos de
    Azure (nombre de host y clave); no crea ni cambia recursos.

    Nota sobre Flex Consumption: Azure CLI devuelve el nombre de host en
    "properties.defaultHostName" (el campo "defaultHostName" de primer nivel
    sale vacío). El "Default domain" del portal también es válido.

.EXAMPLE
    .\scripts\ejecutar_manual.ps1
#>
$ErrorActionPreference = "Stop"

$NombreDespliegue = "agroeco-dev"

$Grupo = az deployment sub show --name $NombreDespliegue --query properties.outputs.grupoRecursos.value -o tsv
if ($LASTEXITCODE -ne 0 -or -not $Grupo) { throw "No encuentro el despliegue '$NombreDespliegue'. ¿Has ejecutado desplegar.ps1?" }
$App = az deployment sub show --name $NombreDespliegue --query properties.outputs.functionApp.value -o tsv

# Nombre de host (en Flex Consumption está dentro de "properties")
$HostFunction = az functionapp show --resource-group $Grupo --name $App --query properties.defaultHostName -o tsv
if (-not $HostFunction) { throw "No se ha podido leer el nombre de host de $App" }

# Clave de la función (no se muestra por pantalla)
$Clave = az functionapp function keys list --resource-group $Grupo --name $App --function-name pipeline_manual --query default -o tsv
if (-not $Clave) { throw "No se ha podido leer la clave de pipeline_manual (¿se ha desplegado el código?)" }

Write-Host ">>> Ejecutando el pipeline en https://$HostFunction/api/ejecutar" -ForegroundColor Cyan
Write-Host "    Puede tardar 1-3 minutos (la base de datos gratuita tiene que reanudarse)."
try {
    $Respuesta = Invoke-RestMethod -Method Post -Uri "https://$HostFunction/api/ejecutar?code=$Clave" -TimeoutSec 300
    Write-Host "[OK] Pipeline terminado:" -ForegroundColor Green
    $Respuesta | ConvertTo-Json -Depth 5
}
catch {
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "        Detalle: Application Insights (appi-agroeco-dev) -> Logs -> tabla 'traces' / 'exceptions'."
    exit 1
}
