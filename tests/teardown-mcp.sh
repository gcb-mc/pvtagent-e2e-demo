#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# teardown-mcp.sh — Remove MCP server resources without deleting the RG
#
# Removes ONLY:
#   - Container App (mcp-http-server)
#   - Container Apps Environment (mcp-env)
#   - ACR (mcpacr*)
#   - Key Vault (mcpkv*)
#   - Managed Identity (mcp-identity)
#   - Private DNS zone + VNet link (Container Apps domain)
#
# Does NOT touch:
#   - VNet, subnets, AI Services, Cosmos DB, Storage, AI Search, etc.
#
# Usage:
#   ./teardown-mcp.sh --resource-group <rg> [--yes]
###############################################################################

RESOURCE_GROUP=""
AUTO_CONFIRM=false
IDENTITY_NAME="mcp-identity"
CAE_NAME="mcp-env"
CONTAINER_APP_NAME="mcp-http-server"
ACR_PREFIX="mcpacr"
KV_PREFIX="mcpkv"

# ── Parse arguments ──────────────────────────────────────────────────────────
usage() {
  echo "Usage: $0 --resource-group <rg> [--yes]"
  echo ""
  echo "Required:"
  echo "  --resource-group, -g   Resource group containing MCP resources"
  echo ""
  echo "Optional:"
  echo "  --yes, -y              Skip confirmation prompt"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --resource-group|-g) RESOURCE_GROUP="$2"; shift 2 ;;
    --yes|-y)            AUTO_CONFIRM=true; shift ;;
    -h|--help)           usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

[[ -z "$RESOURCE_GROUP" ]] && { echo "ERROR: --resource-group is required"; usage; }

# ── Generate same unique suffix as deploy-mcp.sh ─────────────────────────────
UNIQUE_SUFFIX=$(echo -n "${RESOURCE_GROUP}" | md5sum | cut -c1-6)
ACR_NAME="${ACR_PREFIX}${UNIQUE_SUFFIX}"
KV_NAME="${KV_PREFIX}${UNIQUE_SUFFIX}"

# ── Discover resources ───────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo " Teardown MCP Resources"
echo "============================================================"
echo " Resource Group:  $RESOURCE_GROUP"
echo ""
echo " Resources to remove:"

RESOURCES_FOUND=()

# Container App
if az containerapp show -g "$RESOURCE_GROUP" -n "$CONTAINER_APP_NAME" &>/dev/null; then
  echo "  ✓ Container App:    $CONTAINER_APP_NAME"
  RESOURCES_FOUND+=("containerapp:$CONTAINER_APP_NAME")
else
  echo "  - Container App:    $CONTAINER_APP_NAME (not found)"
fi

# Container Apps Environment
if az containerapp env show -g "$RESOURCE_GROUP" -n "$CAE_NAME" &>/dev/null; then
  echo "  ✓ CAE:              $CAE_NAME"
  RESOURCES_FOUND+=("cae:$CAE_NAME")
  # Get DNS zone name before we delete the environment
  DEFAULT_DOMAIN=$(az containerapp env show -g "$RESOURCE_GROUP" -n "$CAE_NAME" --query "properties.defaultDomain" -o tsv 2>/dev/null || true)
else
  echo "  - CAE:              $CAE_NAME (not found)"
  DEFAULT_DOMAIN=""
fi

# ACR
if az acr show --name "$ACR_NAME" -g "$RESOURCE_GROUP" &>/dev/null; then
  echo "  ✓ ACR:              $ACR_NAME"
  RESOURCES_FOUND+=("acr:$ACR_NAME")
else
  echo "  - ACR:              $ACR_NAME (not found)"
fi

# Key Vault
if az keyvault show --name "$KV_NAME" -g "$RESOURCE_GROUP" &>/dev/null; then
  echo "  ✓ Key Vault:        $KV_NAME"
  RESOURCES_FOUND+=("kv:$KV_NAME")
else
  echo "  - Key Vault:        $KV_NAME (not found)"
fi

# Managed Identity
if az identity show --name "$IDENTITY_NAME" -g "$RESOURCE_GROUP" &>/dev/null; then
  echo "  ✓ Identity:         $IDENTITY_NAME"
  RESOURCES_FOUND+=("identity:$IDENTITY_NAME")
else
  echo "  - Identity:         $IDENTITY_NAME (not found)"
fi

# Private DNS zone
if [[ -n "$DEFAULT_DOMAIN" ]] && az network private-dns zone show -g "$RESOURCE_GROUP" -n "$DEFAULT_DOMAIN" &>/dev/null; then
  echo "  ✓ DNS Zone:         $DEFAULT_DOMAIN"
  RESOURCES_FOUND+=("dns:$DEFAULT_DOMAIN")
else
  echo "  - DNS Zone:         (not found or CAE not present)"
fi

echo ""
echo " Resources NOT affected:"
echo "  - VNet, subnets, AI Services, Cosmos DB, Storage, AI Search"
echo "============================================================"

if [[ ${#RESOURCES_FOUND[@]} -eq 0 ]]; then
  echo ""
  echo "No MCP resources found. Nothing to delete."
  exit 0
fi

# ── Confirmation ─────────────────────────────────────────────────────────────
if [[ "$AUTO_CONFIRM" != true ]]; then
  echo ""
  read -rp "Delete these ${#RESOURCES_FOUND[@]} resource(s)? (y/N): " CONFIRM
  if [[ "$CONFIRM" != [yY] ]]; then
    echo "Aborted."
    exit 0
  fi
fi

echo ""
echo "Deleting MCP resources..."

# ── Delete in dependency order ───────────────────────────────────────────────

# 1. Container App first (depends on CAE)
if az containerapp show -g "$RESOURCE_GROUP" -n "$CONTAINER_APP_NAME" &>/dev/null; then
  echo "  Deleting Container App '$CONTAINER_APP_NAME'..."
  az containerapp delete \
    -g "$RESOURCE_GROUP" \
    -n "$CONTAINER_APP_NAME" \
    --yes
  echo "  ✓ Container App deleted."
fi

# 2. Container Apps Environment (after app is gone)
if az containerapp env show -g "$RESOURCE_GROUP" -n "$CAE_NAME" &>/dev/null; then
  echo "  Deleting Container Apps Environment '$CAE_NAME'..."
  az containerapp env delete \
    -g "$RESOURCE_GROUP" \
    -n "$CAE_NAME" \
    --yes
  echo "  ✓ Container Apps Environment deleted."
fi

# 3. Private DNS zone + VNet link
if [[ -n "$DEFAULT_DOMAIN" ]] && az network private-dns zone show -g "$RESOURCE_GROUP" -n "$DEFAULT_DOMAIN" &>/dev/null; then
  # Delete VNet link first
  if az network private-dns link vnet show -g "$RESOURCE_GROUP" -z "$DEFAULT_DOMAIN" -n "containerapp-link" &>/dev/null; then
    echo "  Deleting VNet link 'containerapp-link'..."
    az network private-dns link vnet delete \
      -g "$RESOURCE_GROUP" \
      -z "$DEFAULT_DOMAIN" \
      -n "containerapp-link" \
      --yes
    echo "  ✓ VNet link deleted."
  fi

  echo "  Deleting Private DNS zone '$DEFAULT_DOMAIN'..."
  az network private-dns zone delete \
    -g "$RESOURCE_GROUP" \
    -n "$DEFAULT_DOMAIN" \
    --yes
  echo "  ✓ Private DNS zone deleted."
fi

# 4. ACR
if az acr show --name "$ACR_NAME" -g "$RESOURCE_GROUP" &>/dev/null; then
  echo "  Deleting ACR '$ACR_NAME'..."
  az acr delete \
    --name "$ACR_NAME" \
    -g "$RESOURCE_GROUP" \
    --yes
  echo "  ✓ ACR deleted."
fi

# 5. Key Vault (soft-delete means it goes to "deleted" state)
if az keyvault show --name "$KV_NAME" -g "$RESOURCE_GROUP" &>/dev/null; then
  echo "  Deleting Key Vault '$KV_NAME'..."
  az keyvault delete \
    --name "$KV_NAME" \
    -g "$RESOURCE_GROUP"
  echo "  ✓ Key Vault deleted (soft-deleted; purge with: az keyvault purge --name $KV_NAME)."
fi

# 6. Managed Identity (last, as it may have role assignments cleared automatically)
if az identity show --name "$IDENTITY_NAME" -g "$RESOURCE_GROUP" &>/dev/null; then
  echo "  Deleting Managed Identity '$IDENTITY_NAME'..."
  az identity delete \
    --name "$IDENTITY_NAME" \
    -g "$RESOURCE_GROUP"
  echo "  ✓ Managed Identity deleted."
fi

echo ""
echo "============================================================"
echo " TEARDOWN COMPLETE"
echo "============================================================"
echo " All MCP resources removed from $RESOURCE_GROUP."
echo " Bicep-deployed resources (VNet, AI Services, etc.) are intact."
echo "============================================================"
