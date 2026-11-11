#!/usr/bin/env bash
# =====================================================================
# desplegar.sh  (Linux, macOS, Git Bash o Azure Cloud Shell)
# Despliega el proyecto en Azure: infraestructura (Bicep) y código.
# Hace lo mismo que desplegar.ps1; ver los comentarios de ese archivo.
#
# Uso:
#   ./scripts/desplegar.sh                       # infraestructura + código
#   ./scripts/desplegar.sh --vista-previa        # what-if, no crea nada
#   ./scripts/desplegar.sh --solo-codigo         # solo sube el código
#   ./scripts/desplegar.sh --ip 203.0.113.10     # añade tu IP al firewall SQL
#   ./scripts/desplegar.sh --correo tu@correo.com  # crea la alerta si falla la Function
# =====================================================================
set -euo pipefail   # parar ante cualquier error

VISTA_PREVIA=false
SOLO_CODIGO=false
IP_CLIENTE=""
CORREO_ALERTAS=""
while [ $# -gt 0 ]; do
    case "$1" in
        --vista-previa) VISTA_PREVIA=true ;;
        --solo-codigo)  SOLO_CODIGO=true ;;
        --ip)           IP_CLIENTE="$2"; shift ;;
        --correo)       CORREO_ALERTAS="$2"; shift ;;
        *) echo "Opción desconocida: $1"; exit 1 ;;
    esac
    shift
done

# Rutas entre comillas siempre: la carpeta del proyecto puede tener espacios
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLANTILLA="$RAIZ/infra/main.bicep"
PARAMETROS="$RAIZ/infra/main.parameters.example.json"
[ -f "$RAIZ/infra/main.parameters.local.json" ] && PARAMETROS="$RAIZ/infra/main.parameters.local.json"
ZIP="${TMPDIR:-/tmp}/agroeco-paquete.zip"     # fuera de OneDrive a propósito
NOMBRE_DESPLIEGUE="agroeco-dev"
UBICACION="spaincentral"
PYTHON="$(command -v python3 || command -v python)"

echo ">>> 1. Comprobando la sesión de Azure CLI"
az account show --query name -o tsv || { echo "Ejecuta antes: az login"; exit 1; }

if [ "$SOLO_CODIGO" = false ]; then
    echo ">>> 2. Registrando proveedores de recursos (gratis)"
    for proveedor in Microsoft.Storage Microsoft.Web Microsoft.Sql Microsoft.Insights Microsoft.OperationalInsights Microsoft.AlertsManagement; do
        echo "     $proveedor"
        az provider register --namespace "$proveedor" --wait
    done

    ARGUMENTOS=(--name "$NOMBRE_DESPLIEGUE" --location "$UBICACION"
                --template-file "$PLANTILLA" --parameters "@$PARAMETROS")
    [ -n "$IP_CLIENTE" ] && ARGUMENTOS+=("ipCliente=$IP_CLIENTE")
    [ -n "$CORREO_ALERTAS" ] && ARGUMENTOS+=("correoAlertas=$CORREO_ALERTAS")

    if [ "$VISTA_PREVIA" = true ]; then
        echo ">>> 3. Vista previa (what-if): NO se crea nada. Te pedirá la contraseña SQL."
        az deployment sub what-if "${ARGUMENTOS[@]}"
        exit 0
    fi

    echo ">>> 3. Desplegando la infraestructura (unos 5 minutos). Te pedirá la contraseña SQL"
    echo "     (mín. 12 caracteres; sin ; { } para no romper la cadena de conexión)."
    az deployment sub create "${ARGUMENTOS[@]}" --output none
fi

GRUPO="$(az deployment sub show --name "$NOMBRE_DESPLIEGUE" --query properties.outputs.grupoRecursos.value -o tsv)"
APP="$(az deployment sub show --name "$NOMBRE_DESPLIEGUE" --query properties.outputs.functionApp.value -o tsv)"
echo "     Grupo de recursos: $GRUPO"
echo "     Function App:      $APP"

echo ">>> 4. Creando el paquete de la Function"
"$PYTHON" "$RAIZ/scripts/empaquetar.py" "$ZIP"

echo ">>> 5. Subiendo el código a $APP (remote build, unos minutos)"
az functionapp deployment source config-zip --resource-group "$GRUPO" --name "$APP" \
    --src "$ZIP" --build-remote true --timeout 900 --output none

echo "[OK] Despliegue terminado. Para ejecutar el pipeline ahora: ./scripts/ejecutar_manual.sh"
