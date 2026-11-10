#!/usr/bin/env bash
# =====================================================================
# ejecutar_manual.sh  (Linux, macOS, Git Bash o Azure Cloud Shell)
# Ejecuta el pipeline ahora mismo llamando a la función HTTP "pipeline_manual".
# Solo LEE datos de Azure (nombre de host y clave); no crea ni cambia recursos.
#
# Nota sobre Flex Consumption: el nombre de host está en
# "properties.defaultHostName" (el campo de primer nivel sale vacío).
# =====================================================================
set -euo pipefail

NOMBRE_DESPLIEGUE="agroeco-dev"

GRUPO="$(az deployment sub show --name "$NOMBRE_DESPLIEGUE" --query properties.outputs.grupoRecursos.value -o tsv)"
APP="$(az deployment sub show --name "$NOMBRE_DESPLIEGUE" --query properties.outputs.functionApp.value -o tsv)"
HOST_FUNCTION="$(az functionapp show --resource-group "$GRUPO" --name "$APP" --query properties.defaultHostName -o tsv)"
CLAVE="$(az functionapp function keys list --resource-group "$GRUPO" --name "$APP" --function-name pipeline_manual --query default -o tsv)"

echo ">>> Ejecutando el pipeline en https://$HOST_FUNCTION/api/ejecutar (1-3 minutos)"
curl --fail-with-body --silent --show-error --max-time 300 -X POST \
    "https://$HOST_FUNCTION/api/ejecutar?code=$CLAVE"
echo
echo "[OK] Si ves el resumen con las filas por tabla, el pipeline ha funcionado."
