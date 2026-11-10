<#
.SYNOPSIS
    Despliega el proyecto en Azure: infraestructura (Bicep) y código de la Function.

.DESCRIPTION
    Pasos:
      1. Comprueba que has iniciado sesión con Azure CLI.
      2. Registra los proveedores de recursos necesarios (gratis, solo la primera vez).
      3. Despliega infra/main.bicep a nivel de suscripción.
         Azure CLI te pedirá la contraseña del administrador SQL (no se guarda en ningún archivo).
      4. Crea el paquete .zip de la Function (fuera de OneDrive, en la carpeta temporal).
      5. Sube el código a la Function App (Azure instala las dependencias: remote build).

.PARAMETER VistaPrevia
    Solo muestra qué se crearía o cambiaría (what-if). No crea nada.

.PARAMETER SoloCodigo
    Se salta la infraestructura y solo vuelve a subir el código.

.PARAMETER IpCliente
    Tu IP pública. Crea una regla en el firewall de SQL para conectarte desde tu ordenador o el portal.

.EXAMPLE
    .\scripts\desplegar.ps1 -VistaPrevia
    .\scripts\desplegar.ps1
    .\scripts\desplegar.ps1 -IpCliente 203.0.113.10
    .\scripts\desplegar.ps1 -SoloCodigo
#>
param(
    [switch]$VistaPrevia,
    [switch]$SoloCodigo,
    [string]$IpCliente = ""
)

$ErrorActionPreference = "Stop"

# Rutas: $PSScriptRoot es la carpeta scripts\. Join-Path y las comillas
# hacen que funcione aunque la ruta tenga espacios (como la carpeta de OneDrive).
$Raiz        = Split-Path -Parent $PSScriptRoot
$Plantilla   = Join-Path $Raiz "infra\main.bicep"
$ParamLocal  = Join-Path $Raiz "infra\main.parameters.local.json"
$ParamEjemplo = Join-Path $Raiz "infra\main.parameters.example.json"
$Empaquetar  = Join-Path $Raiz "scripts\empaquetar.py"
$Zip         = Join-Path $env:TEMP "agroeco-paquete.zip"   # fuera de OneDrive a propósito

$NombreDespliegue = "agroeco-dev"
$Ubicacion        = "spaincentral"   # dónde se guarda el registro del despliegue

# Si existe un archivo de parámetros local (ignorado por git), se usa ese
if (Test-Path $ParamLocal) { $Parametros = $ParamLocal } else { $Parametros = $ParamEjemplo }

# Los comandos externos (az, python) no detienen el script al fallar: hay que mirar $LASTEXITCODE
function Comprobar([string]$Paso) {
    if ($LASTEXITCODE -ne 0) { throw "Ha fallado: $Paso (código $LASTEXITCODE)" }
}

# ---------------------------------------------------------------------
# 1. Sesión de Azure CLI
# ---------------------------------------------------------------------
Write-Host "`n>>> 1. Comprobando la sesión de Azure CLI" -ForegroundColor Cyan
$Suscripcion = az account show --query name -o tsv
if ($LASTEXITCODE -ne 0) { throw "No has iniciado sesión. Ejecuta: az login" }
Write-Host "     Suscripción activa: $Suscripcion"

if (-not $SoloCodigo) {
    # -----------------------------------------------------------------
    # 2. Proveedores de recursos (gratis; si ya están registrados no hace nada)
    # -----------------------------------------------------------------
    Write-Host "`n>>> 2. Registrando proveedores de recursos" -ForegroundColor Cyan
    foreach ($Proveedor in @("Microsoft.Storage", "Microsoft.Web", "Microsoft.Sql",
                             "Microsoft.Insights", "Microsoft.OperationalInsights")) {
        Write-Host "     $Proveedor"
        az provider register --namespace $Proveedor --wait
        Comprobar "registrar $Proveedor"
    }

    # -----------------------------------------------------------------
    # 3. Infraestructura (Bicep)
    # -----------------------------------------------------------------
    $Argumentos = @("--name", $NombreDespliegue, "--location", $Ubicacion,
                    "--template-file", $Plantilla, "--parameters", "@$Parametros")
    if ($IpCliente) { $Argumentos += "ipCliente=$IpCliente" }

    if ($VistaPrevia) {
        Write-Host "`n>>> 3. Vista previa (what-if): NO se crea nada" -ForegroundColor Cyan
        Write-Host "     Azure CLI te pedirá la contraseña del administrador SQL (mín. 12 caracteres)."
        az deployment sub what-if @Argumentos
        Comprobar "what-if"
        return
    }

    Write-Host "`n>>> 3. Desplegando la infraestructura (tarda unos 5 minutos)" -ForegroundColor Cyan
    Write-Host "     Azure CLI te pedirá la contraseña del administrador SQL (mín. 12 caracteres,"
    Write-Host "     mayúsculas, minúsculas, números y símbolos; sin ; { } para no romper la cadena de conexión)."
    az deployment sub create @Argumentos --output none
    Comprobar "despliegue de la infraestructura"
}

# Nombres reales de los recursos (salidas del último despliegue)
$Grupo = az deployment sub show --name $NombreDespliegue --query properties.outputs.grupoRecursos.value -o tsv
Comprobar "leer las salidas del despliegue (¿has desplegado ya la infraestructura?)"
$App = az deployment sub show --name $NombreDespliegue --query properties.outputs.functionApp.value -o tsv
Comprobar "leer el nombre de la Function App"
Write-Host "     Grupo de recursos: $Grupo"
Write-Host "     Function App:      $App"

# ---------------------------------------------------------------------
# 4. Paquete del código
# ---------------------------------------------------------------------
Write-Host "`n>>> 4. Creando el paquete de la Function" -ForegroundColor Cyan
python "$Empaquetar" "$Zip"
Comprobar "crear el paquete"

# ---------------------------------------------------------------------
# 5. Subir el código (remote build: Azure instala requirements.txt en Linux)
# ---------------------------------------------------------------------
Write-Host "`n>>> 5. Subiendo el código a $App (tarda unos minutos)" -ForegroundColor Cyan
az functionapp deployment source config-zip --resource-group $Grupo --name $App --src "$Zip" --build-remote true --timeout 900 --output none
Comprobar "subir el código"

Write-Host "`n[OK] Despliegue terminado" -ForegroundColor Green
Write-Host "     Para ejecutar el pipeline ahora mismo: .\scripts\ejecutar_manual.ps1"
