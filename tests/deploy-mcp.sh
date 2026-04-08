#!/usr/bin/env bash
set -euo pipefail

# Disable MSYS/Git Bash automatic path conversion (Windows).
# Without this, arguments like --scope /subscriptions/... get mangled into C:/subscriptions/...
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

###############################################################################
# deploy-mcp.sh — Deploy a private MCP server on Template 19's mcp-subnet
#
# Deploys mattfeltonma/python-basic-as-hell-mcp-server (FastMCP weather tool)
# as a fully private Container App with Key Vault secret integration.
#
# Steps:
#   1. Confirm mcp-subnet delegation to Microsoft.App/environments
#   2. Build & push Docker image to a new ACR via az acr build
#   3. Store WEATHER_API_KEY in a new Key Vault
#   4. Create private Container Apps environment on mcp-subnet (internal-only)
#   5. Deploy MCP container and output private FQDN
#
# Usage:
#   ./deploy-mcp.sh --resource-group <rg> --weather-api-key <key> [--location <loc>]
#
# Prerequisites:
#   - Azure CLI authenticated with Owner/Contributor on the subscription
#   - Template 19 already deployed (VNet with mcp-subnet must exist)
#   - A free Weather API key from https://www.weatherapi.com/
###############################################################################

# ── Defaults ─────────────────────────────────────────────────────────────────
RESOURCE_GROUP=""
WEATHER_API_KEY=""
LOCATION=""
MCP_SUBNET_NAME="mcp-subnet"
ACR_PREFIX="mcpacr"
KV_PREFIX="mcpkv"
IDENTITY_NAME="mcp-identity"
CAE_NAME="mcp-env"
CONTAINER_APP_NAME="mcp-http-server"
IMAGE_NAME="weather-mcp"
IMAGE_TAG="latest"
MCP_REPO="https://github.com/mattfeltonma/python-basic-as-hell-mcp-server.git"

# ── Parse arguments ──────────────────────────────────────────────────────────
usage() {
  echo "Usage: $0 --resource-group <rg> --weather-api-key <key> [--location <loc>]"
  echo ""
  echo "Required:"
  echo "  --resource-group, -g   Resource group where Template 19 is deployed"
  echo "  --weather-api-key      WeatherAPI key (from https://www.weatherapi.com/)"
  echo ""
  echo "Optional:"
  echo "  --location, -l         Azure region (auto-detected from resource group if omitted)"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --resource-group|-g) RESOURCE_GROUP="$2"; shift 2 ;;
    --weather-api-key)   WEATHER_API_KEY="$2"; shift 2 ;;
    --location|-l)       LOCATION="$2"; shift 2 ;;
    -h|--help)           usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

[[ -z "$RESOURCE_GROUP" ]] && { echo "ERROR: --resource-group is required"; usage; }
[[ -z "$WEATHER_API_KEY" ]] && { echo "ERROR: --weather-api-key is required"; usage; }

# ── Auto-detect location from resource group ─────────────────────────────────
if [[ -z "$LOCATION" ]]; then
  LOCATION=$(az group show --name "$RESOURCE_GROUP" --query "location" -o tsv)
  echo "Auto-detected location: $LOCATION"
fi

# ── Generate unique suffix ───────────────────────────────────────────────────
# Use sha256sum with fallback to md5sum for portability (Windows Git Bash may lack md5sum)
if command -v sha256sum &>/dev/null; then
  UNIQUE_SUFFIX=$(echo -n "${RESOURCE_GROUP}" | sha256sum | cut -c1-6)
elif command -v md5sum &>/dev/null; then
  UNIQUE_SUFFIX=$(echo -n "${RESOURCE_GROUP}" | md5sum | cut -c1-6)
else
  # Fallback: use cksum (POSIX)
  UNIQUE_SUFFIX=$(echo -n "${RESOURCE_GROUP}" | cksum | awk '{print $1}' | cut -c1-6)
fi
ACR_NAME="${ACR_PREFIX}${UNIQUE_SUFFIX}"
KV_NAME="${KV_PREFIX}${UNIQUE_SUFFIX}"

echo ""
echo "============================================================"
echo " Deploy Private MCP Server"
echo "============================================================"
echo " Resource Group:  $RESOURCE_GROUP"
echo " Location:        $LOCATION"
echo " ACR Name:        $ACR_NAME"
echo " Key Vault Name:  $KV_NAME"
echo " Identity:        $IDENTITY_NAME"
echo " CAE Name:        $CAE_NAME"
echo " Container App:   $CONTAINER_APP_NAME"
echo "============================================================"
echo ""

###############################################################################
# STEP 1: Confirm mcp-subnet delegation
###############################################################################
echo "──────────────────────────────────────────────────────────────"
echo "STEP 1: Confirm mcp-subnet delegation"
echo "──────────────────────────────────────────────────────────────"

# Find the VNet in the resource group
VNET_NAME=$(az network vnet list -g "$RESOURCE_GROUP" --query "[0].name" -o tsv)
if [[ -z "$VNET_NAME" ]]; then
  echo "ERROR: No VNet found in resource group $RESOURCE_GROUP"
  echo "       Deploy Template 19 (main.bicep) first."
  exit 1
fi
echo "Found VNet: $VNET_NAME"

# Check mcp-subnet exists and has correct delegation
DELEGATION=$(az network vnet subnet show \
  -g "$RESOURCE_GROUP" \
  --vnet-name "$VNET_NAME" \
  -n "$MCP_SUBNET_NAME" \
  --query "delegations[0].serviceName" -o tsv 2>/dev/null || true)

if [[ -z "$DELEGATION" ]]; then
  echo "ERROR: Subnet '$MCP_SUBNET_NAME' not found in VNet '$VNET_NAME'"
  echo "       Ensure Template 19 was deployed with mcp-subnet."
  exit 1
fi

if [[ "$DELEGATION" != "Microsoft.App/environments" ]]; then
  echo "ERROR: Subnet '$MCP_SUBNET_NAME' delegation is '$DELEGATION'"
  echo "       Expected: Microsoft.App/environments"
  exit 1
fi

MCP_SUBNET_ID=$(az network vnet subnet show \
  -g "$RESOURCE_GROUP" \
  --vnet-name "$VNET_NAME" \
  -n "$MCP_SUBNET_NAME" \
  --query "id" -o tsv)

echo "✓ mcp-subnet confirmed with Microsoft.App/environments delegation"
echo "  Subnet ID: $MCP_SUBNET_ID"
echo ""

###############################################################################
# STEP 2: Build & push Docker image
###############################################################################
echo "──────────────────────────────────────────────────────────────"
echo "STEP 2: Build & push Docker image"
echo "──────────────────────────────────────────────────────────────"

# 2a. Create ACR if it doesn't exist
if az acr show --name "$ACR_NAME" -g "$RESOURCE_GROUP" &>/dev/null; then
  echo "ACR '$ACR_NAME' already exists, skipping creation."
else
  echo "Creating ACR '$ACR_NAME' (Basic SKU)..."
  az acr create \
    --name "$ACR_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --sku Basic \
    --location "$LOCATION" \
    --admin-enabled false
  echo "✓ ACR created."
fi

# 2b. Clone repo and build image in ACR (no local Docker required)
TEMP_DIR=$(mktemp -d)
echo "Cloning MCP server repo to $TEMP_DIR..."
git clone --depth 1 "$MCP_REPO" "$TEMP_DIR/mcp-server"

echo "Building image in ACR (az acr build)..."
az acr build \
  --registry "$ACR_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --image "${IMAGE_NAME}:${IMAGE_TAG}" \
  --platform linux/amd64 \
  "$TEMP_DIR/mcp-server"

rm -rf "$TEMP_DIR"
echo "✓ Image ${ACR_NAME}.azurecr.io/${IMAGE_NAME}:${IMAGE_TAG} built and pushed."
echo ""

# 2c. Create managed identity if it doesn't exist
if az identity show --name "$IDENTITY_NAME" -g "$RESOURCE_GROUP" &>/dev/null; then
  echo "Managed identity '$IDENTITY_NAME' already exists, skipping creation."
else
  echo "Creating managed identity '$IDENTITY_NAME'..."
  az identity create \
    --name "$IDENTITY_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION"
  echo "✓ Managed identity created."
fi

IDENTITY_ID=$(az identity show --name "$IDENTITY_NAME" -g "$RESOURCE_GROUP" --query "id" -o tsv)
IDENTITY_PRINCIPAL=$(az identity show --name "$IDENTITY_NAME" -g "$RESOURCE_GROUP" --query "principalId" -o tsv)
IDENTITY_CLIENT_ID=$(az identity show --name "$IDENTITY_NAME" -g "$RESOURCE_GROUP" --query "clientId" -o tsv)

if [[ -z "$IDENTITY_ID" || -z "$IDENTITY_PRINCIPAL" || -z "$IDENTITY_CLIENT_ID" ]]; then
  echo "ERROR: Failed to retrieve managed identity properties."
  echo "  IDENTITY_ID=$IDENTITY_ID"
  echo "  IDENTITY_PRINCIPAL=$IDENTITY_PRINCIPAL"
  echo "  IDENTITY_CLIENT_ID=$IDENTITY_CLIENT_ID"
  echo "  Check: az identity show --name $IDENTITY_NAME -g $RESOURCE_GROUP"
  exit 1
fi

# 2d. Assign AcrPull role
ACR_ID=$(az acr show --name "$ACR_NAME" -g "$RESOURCE_GROUP" --query "id" -o tsv)
if [[ -z "$ACR_ID" ]]; then
  echo "ERROR: Failed to retrieve ACR resource ID for '$ACR_NAME'."
  echo "  Existing ACRs in resource group:"
  az acr list -g "$RESOURCE_GROUP" --query "[].name" -o tsv 2>/dev/null || echo "  (none found)"
  echo "  Computed ACR_NAME=$ACR_NAME (suffix=$UNIQUE_SUFFIX)"
  echo "  Ensure the ACR was created in Step 2a and the name matches."
  exit 1
fi

EXISTING_ACR_ROLE=$(az role assignment list --assignee "$IDENTITY_PRINCIPAL" --scope "$ACR_ID" --role AcrPull --query "[0].id" -o tsv 2>/dev/null || true)
if [[ -n "$EXISTING_ACR_ROLE" ]]; then
  echo "AcrPull role already assigned, skipping."
else
  echo "Assigning AcrPull role to identity..."
  echo "  Assignee (principalId): $IDENTITY_PRINCIPAL"
  echo "  Scope (ACR ID):         $ACR_ID"
  az role assignment create \
    --assignee-object-id "$IDENTITY_PRINCIPAL" \
    --assignee-principal-type ServicePrincipal \
    --role AcrPull \
    --scope "$ACR_ID"
  echo "Waiting 30s for role assignment propagation..."
  sleep 30
fi
echo "✓ Identity '$IDENTITY_NAME' has AcrPull on ACR."
echo ""

###############################################################################
# STEP 3: Store WEATHER_API_KEY in Key Vault
###############################################################################
echo "──────────────────────────────────────────────────────────────"
echo "STEP 3: Store secret in Key Vault"
echo "──────────────────────────────────────────────────────────────"

# 3a. Create Key Vault if it doesn't exist
if az keyvault show --name "$KV_NAME" -g "$RESOURCE_GROUP" &>/dev/null; then
  echo "Key Vault '$KV_NAME' already exists, skipping creation."
else
  echo "Creating Key Vault '$KV_NAME'..."
  az keyvault create \
    --name "$KV_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --enable-rbac-authorization true
  echo "✓ Key Vault created."
fi

KV_ID=$(az keyvault show --name "$KV_NAME" -g "$RESOURCE_GROUP" --query "id" -o tsv)
if [[ -z "$KV_ID" ]]; then
  echo "ERROR: Failed to retrieve Key Vault resource ID for '$KV_NAME'."
  echo "  Check: az keyvault show --name $KV_NAME -g $RESOURCE_GROUP"
  exit 1
fi

# 3b. Grant current user Key Vault Secrets Officer role to set secrets
CURRENT_USER=$(az ad signed-in-user show --query "id" -o tsv 2>/dev/null || true)
if [[ -n "$CURRENT_USER" ]]; then
  EXISTING_USER_ROLE=$(az role assignment list --assignee "$CURRENT_USER" --scope "$KV_ID" --role "Key Vault Secrets Officer" --query "[0].id" -o tsv 2>/dev/null || true)
  if [[ -z "$EXISTING_USER_ROLE" ]]; then
    echo "Granting current user Key Vault Secrets Officer role..."
    echo "  Assignee (user): $CURRENT_USER"
    echo "  Scope (KV ID):   $KV_ID"
    az role assignment create \
      --assignee-object-id "$CURRENT_USER" \
      --assignee-principal-type User \
      --role "Key Vault Secrets Officer" \
      --scope "$KV_ID"
    echo "Waiting 30s for role assignment propagation..."
    sleep 30
  fi
fi

# 3c. Store the weather API key
echo "Storing WEATHER-API-KEY in Key Vault..."
az keyvault secret set \
  --vault-name "$KV_NAME" \
  --name "WEATHER-API-KEY" \
  --value "$WEATHER_API_KEY" \
  --output none
echo "✓ Secret stored."

# 3d. Grant managed identity Key Vault Secrets User role
EXISTING_KV_ROLE=$(az role assignment list --assignee "$IDENTITY_PRINCIPAL" --scope "$KV_ID" --role "Key Vault Secrets User" --query "[0].id" -o tsv 2>/dev/null || true)
if [[ -n "$EXISTING_KV_ROLE" ]]; then
  echo "Key Vault Secrets User role already assigned, skipping."
else
  echo "Granting identity Key Vault Secrets User role..."
  echo "  Assignee (principalId): $IDENTITY_PRINCIPAL"
  echo "  Scope (KV ID):          $KV_ID"
  az role assignment create \
    --assignee-object-id "$IDENTITY_PRINCIPAL" \
    --assignee-principal-type ServicePrincipal \
    --role "Key Vault Secrets User" \
    --scope "$KV_ID"
  echo "Waiting 30s for role assignment propagation..."
  sleep 30
fi
echo "✓ Identity '$IDENTITY_NAME' has Key Vault Secrets User on vault."
echo ""

# Get secret URI for Container App reference
KV_SECRET_URI=$(az keyvault secret show --vault-name "$KV_NAME" --name "WEATHER-API-KEY" --query "id" -o tsv)
echo "  Secret URI: $KV_SECRET_URI"
echo ""

###############################################################################
# STEP 4: Create private Container Apps environment on mcp-subnet
###############################################################################
echo "──────────────────────────────────────────────────────────────"
echo "STEP 4: Create private Container Apps environment"
echo "──────────────────────────────────────────────────────────────"

if az containerapp env show -g "$RESOURCE_GROUP" -n "$CAE_NAME" &>/dev/null; then
  echo "Container Apps environment '$CAE_NAME' already exists, skipping creation."
else
  echo "Creating internal-only Container Apps environment on mcp-subnet..."
  az containerapp env create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$CAE_NAME" \
    --location "$LOCATION" \
    --infrastructure-subnet-resource-id "$MCP_SUBNET_ID" \
    --internal-only true
  echo "✓ Container Apps environment created (internal-only)."
fi

# Get environment properties for DNS setup
MCP_STATIC_IP=$(az containerapp env show -g "$RESOURCE_GROUP" -n "$CAE_NAME" --query "properties.staticIp" -o tsv)
DEFAULT_DOMAIN=$(az containerapp env show -g "$RESOURCE_GROUP" -n "$CAE_NAME" --query "properties.defaultDomain" -o tsv)
echo "  Static IP: $MCP_STATIC_IP"
echo "  Default Domain: $DEFAULT_DOMAIN"

# 4b. Set up private DNS zone
VNET_ID=$(az network vnet show -g "$RESOURCE_GROUP" -n "$VNET_NAME" --query "id" -o tsv)

if az network private-dns zone show -g "$RESOURCE_GROUP" -n "$DEFAULT_DOMAIN" &>/dev/null; then
  echo "Private DNS zone '$DEFAULT_DOMAIN' already exists, skipping."
else
  echo "Creating private DNS zone '$DEFAULT_DOMAIN'..."
  az network private-dns zone create \
    -g "$RESOURCE_GROUP" \
    -n "$DEFAULT_DOMAIN"
  echo "✓ Private DNS zone created."
fi

# Link DNS zone to VNet
if az network private-dns link vnet show -g "$RESOURCE_GROUP" -z "$DEFAULT_DOMAIN" -n "containerapp-link" &>/dev/null; then
  echo "VNet link 'containerapp-link' already exists, skipping."
else
  echo "Linking DNS zone to VNet..."
  az network private-dns link vnet create \
    -g "$RESOURCE_GROUP" \
    -z "$DEFAULT_DOMAIN" \
    -n "containerapp-link" \
    -v "$VNET_ID" \
    --registration-enabled false
  echo "✓ VNet link created."
fi

# Add wildcard A record
EXISTING_A=$(az network private-dns record-set a show -g "$RESOURCE_GROUP" -z "$DEFAULT_DOMAIN" -n "*" --query "aRecords[0].ipv4Address" -o tsv 2>/dev/null || true)
if [[ "$EXISTING_A" == "$MCP_STATIC_IP" ]]; then
  echo "Wildcard A record already points to $MCP_STATIC_IP, skipping."
else
  echo "Adding wildcard A record → $MCP_STATIC_IP..."
  az network private-dns record-set a add-record \
    -g "$RESOURCE_GROUP" \
    -z "$DEFAULT_DOMAIN" \
    -n "*" \
    -a "$MCP_STATIC_IP"
  echo "✓ Wildcard A record created."
fi
echo ""

###############################################################################
# STEP 5: Deploy MCP container
###############################################################################
echo "──────────────────────────────────────────────────────────────"
echo "STEP 5: Deploy MCP container"
echo "──────────────────────────────────────────────────────────────"

if az containerapp show -g "$RESOURCE_GROUP" -n "$CONTAINER_APP_NAME" &>/dev/null; then
  echo "Container app '$CONTAINER_APP_NAME' already exists, updating..."
  az containerapp update \
    --resource-group "$RESOURCE_GROUP" \
    --name "$CONTAINER_APP_NAME" \
    --image "${ACR_NAME}.azurecr.io/${IMAGE_NAME}:${IMAGE_TAG}"
  echo "✓ Container app updated."
else
  echo "Creating container app '$CONTAINER_APP_NAME'..."

  # Deploy with Key Vault secret reference
  az containerapp create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$CONTAINER_APP_NAME" \
    --environment "$CAE_NAME" \
    --image "${ACR_NAME}.azurecr.io/${IMAGE_NAME}:${IMAGE_TAG}" \
    --target-port 8080 \
    --ingress external \
    --min-replicas 1 \
    --max-replicas 3 \
    --user-assigned "$IDENTITY_ID" \
    --registry-server "${ACR_NAME}.azurecr.io" \
    --registry-identity "$IDENTITY_ID" \
    --secrets "weather-api-key=keyvaultref:${KV_SECRET_URI},identityref:${IDENTITY_ID}" \
    --env-vars "WEATHER_API_KEY=secretref:weather-api-key"

  echo "✓ Container app created."
fi

# Get the private FQDN
MCP_FQDN=$(az containerapp show -g "$RESOURCE_GROUP" -n "$CONTAINER_APP_NAME" --query "properties.configuration.ingress.fqdn" -o tsv)
MCP_URL="https://${MCP_FQDN}/mcp"

echo ""
echo "============================================================"
echo " DEPLOYMENT COMPLETE"
echo "============================================================"
echo ""
echo " Private MCP Server FQDN: $MCP_FQDN"
echo " MCP Endpoint URL:        $MCP_URL"
echo ""
echo " To use with test scripts, run:"
echo ""
echo "   export MCP_SERVER_PRIVATE=\"$MCP_URL\""
echo ""
echo " Then run the tests:"
echo ""
echo "   python test_mcp_tools_agents_v2.py --test private --retry 3"
echo ""
echo " Note: This MCP server is only accessible from within the VNet."
echo " Use VPN Gateway, ExpressRoute, or Azure Bastion to connect."
echo "============================================================"
