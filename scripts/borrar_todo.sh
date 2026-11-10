#!/usr/bin/env bash
# =====================================================================
# borrar_todo.sh  (Linux, macOS, Git Bash o Azure Cloud Shell)
# Borra el grupo de recursos completo del proyecto. NO se puede deshacer.
# Pide confirmación escribiendo el nombre del grupo.
# No borra el presupuesto (gratis). Para borrarlo:
#   az consumption budget delete --budget-name presupuesto-agroeco
#
# Uso: ./scripts/borrar_todo.sh [nombre-del-grupo]
# =====================================================================
set -euo pipefail

GRUPO="${1:-rg-agroeco-dev}"

if [ "$(az group exists --name "$GRUPO")" != "true" ]; then
    echo "El grupo de recursos '$GRUPO' no existe. No hay nada que borrar."
    exit 0
fi

echo "Se van a BORRAR estos recursos de forma PERMANENTE:"
az resource list --resource-group "$GRUPO" --query "[].{Nombre:name, Tipo:type}" -o table

read -r -p "Escribe el nombre del grupo ($GRUPO) para confirmar, o pulsa Enter para cancelar: " RESPUESTA
if [ "$RESPUESTA" != "$GRUPO" ]; then
    echo "Cancelado. No se ha borrado nada."
    exit 0
fi

echo "Borrando $GRUPO (puede tardar 5-10 minutos)..."
az group delete --name "$GRUPO" --yes
echo "[OK] Grupo de recursos '$GRUPO' eliminado. El presupuesto sigue activo (es gratis)."
