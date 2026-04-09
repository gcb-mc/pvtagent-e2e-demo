#!/usr/bin/env bash
# =============================================================================
# setup-test-vm.sh — Create an Ubuntu VM inside the VNet for private testing
#
# Creates a Linux VM in the existing vm-subnet with:
#   - Python 3, Azure CLI, and SDK packages pre-installed (via cloud-init)
#   - System-assigned managed identity with Cognitive Services User + Azure AI Developer roles
#   - Public IP for outbound internet (package downloads) and SSH access
#   - Resolves private DNS zones (MCP Container App, AI Services, etc.)
#
# Usage:
#   ./setup-test-vm.sh --resource-group <rg> [--vm-name test-vm] [--vm-size Standard_B2s]
#
# Prerequisites:
#   - Template 19 deployed with a vm-subnet in the VNet
#   - MCP server deployed via deploy-mcp.sh
#   - Azure CLI authenticated with Owner/Contributor role
# =============================================================================

set -euo pipefail

# --- Defaults ---
VM_NAME="test-vm"
VM_SIZE="Standard_B2s"
VM_IMAGE="Canonical:0001-com-ubuntu-server-jammy:22_04-lts:latest"
ADMIN_USER="azureuser"
SUBNET_NAME="vm-subnet"

# --- Parse arguments ---
usage() {
    echo "Usage: $0 --resource-group <rg> [--vm-name <name>] [--vm-size <size>] [--subnet <subnet>]"
    echo ""
    echo "Options:"
    echo "  --resource-group, -g   Resource group name (required)"
    echo "  --vm-name              VM name (default: test-vm)"
    echo "  --vm-size              VM size (default: Standard_B2s)"
    echo "  --subnet               Subnet name (default: vm-subnet)"
    echo "  --help, -h             Show this help"
    exit 1
}

RESOURCE_GROUP=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --resource-group|-g) RESOURCE_GROUP="$2"; shift 2 ;;
        --vm-name) VM_NAME="$2"; shift 2 ;;
        --vm-size) VM_SIZE="$2"; shift 2 ;;
        --subnet) SUBNET_NAME="$2"; shift 2 ;;
        --help|-h) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

if [[ -z "$RESOURCE_GROUP" ]]; then
    echo "ERROR: --resource-group is required"
    usage
fi

echo "============================================================"
echo "Setting up test VM in VNet"
echo "============================================================"
echo "  Resource Group: $RESOURCE_GROUP"
echo "  VM Name:        $VM_NAME"
echo "  VM Size:        $VM_SIZE"
echo "  Subnet:         $SUBNET_NAME"
echo ""

# --- Discover VNet ---
VNET_NAME=$(az network vnet list -g "$RESOURCE_GROUP" --query "[0].name" -o tsv)
LOCATION=$(az group show --name "$RESOURCE_GROUP" --query location -o tsv)
echo "✓ VNet: $VNET_NAME (location: $LOCATION)"

# --- Verify subnet exists ---
SUBNET_PREFIX=$(az network vnet subnet show -g "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" -n "$SUBNET_NAME" --query addressPrefix -o tsv 2>/dev/null || true)
if [[ -z "$SUBNET_PREFIX" ]]; then
    echo "ERROR: Subnet '$SUBNET_NAME' not found in VNet '$VNET_NAME'."
    echo "  Available subnets:"
    az network vnet subnet list -g "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" --query "[].name" -o tsv | sed 's/^/    /'
    exit 1
fi
echo "✓ Subnet: $SUBNET_NAME ($SUBNET_PREFIX)"

# --- Check if VM already exists ---
EXISTING_VM=$(az vm show -g "$RESOURCE_GROUP" -n "$VM_NAME" --query "name" -o tsv 2>/dev/null || true)
if [[ -n "$EXISTING_VM" ]]; then
    echo "⚠ VM '$VM_NAME' already exists. Delete it first or use a different name."
    echo "  To delete: az vm delete -g $RESOURCE_GROUP -n $VM_NAME --yes"
    exit 1
fi

# --- Create cloud-init config ---
CLOUD_INIT_FILE=$(mktemp /tmp/cloud-init-XXXXX.yaml)
cat > "$CLOUD_INIT_FILE" << 'CLOUD_INIT'
#cloud-config
package_update: true
packages:
  - python3
  - python3-pip
  - ca-certificates
  - curl
  - apt-transport-https
  - lsb-release
  - gnupg
runcmd:
  - curl -sL https://aka.ms/InstallAzureCLIDeb | bash
  - pip3 install azure-ai-projects azure-identity openai
CLOUD_INIT
echo "✓ Cloud-init config created"

# --- Create VM ---
echo ""
echo "Creating VM (this takes 1-2 minutes)..."
VM_OUTPUT=$(az vm create \
    -g "$RESOURCE_GROUP" \
    -n "$VM_NAME" \
    -l "$LOCATION" \
    --image "$VM_IMAGE" \
    --size "$VM_SIZE" \
    --vnet-name "$VNET_NAME" \
    --subnet "$SUBNET_NAME" \
    --admin-username "$ADMIN_USER" \
    --generate-ssh-keys \
    --public-ip-address "${VM_NAME}-pip" \
    --custom-data "@${CLOUD_INIT_FILE}" \
    --query "{publicIpAddress:publicIpAddress, privateIpAddress:privateIpAddress}" \
    -o json)

PUBLIC_IP=$(echo "$VM_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['publicIpAddress'])")
PRIVATE_IP=$(echo "$VM_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['privateIpAddress'])")
echo "✓ VM created"
echo "  Public IP:  $PUBLIC_IP"
echo "  Private IP: $PRIVATE_IP"

rm -f "$CLOUD_INIT_FILE"

# --- Enable managed identity ---
echo ""
echo "Enabling managed identity..."
MI_PRINCIPAL=$(az vm identity assign -g "$RESOURCE_GROUP" -n "$VM_NAME" --query "systemAssignedIdentity" -o tsv)
echo "✓ Managed identity: $MI_PRINCIPAL"

# --- Assign RBAC roles ---
echo ""
echo "Assigning RBAC roles (Cognitive Services User + Azure AI Developer)..."

AI_SERVICES_NAME=$(az cognitiveservices account list -g "$RESOURCE_GROUP" --query "[0].name" -o tsv)
AI_SERVICES_ID=$(az cognitiveservices account show -g "$RESOURCE_GROUP" -n "$AI_SERVICES_NAME" --query id -o tsv)
RG_ID=$(az group show -n "$RESOURCE_GROUP" --query id -o tsv)

az role assignment create --assignee "$MI_PRINCIPAL" --role "Cognitive Services User" --scope "$AI_SERVICES_ID" -o none
az role assignment create --assignee "$MI_PRINCIPAL" --role "Azure AI Developer" --scope "$RG_ID" -o none
echo "✓ Roles assigned on $AI_SERVICES_NAME"

# --- Wait for cloud-init ---
echo ""
echo "Waiting for cloud-init to finish (installing Python, az CLI, SDK)..."
echo "  This may take 3-5 minutes. Checking status..."

for i in $(seq 1 30); do
    STATUS=$(az vm run-command invoke -g "$RESOURCE_GROUP" -n "$VM_NAME" \
        --command-id RunShellScript \
        --scripts "cloud-init status 2>/dev/null | grep -oP '(?<=status: )\\w+'" \
        --query "value[0].message" -o tsv 2>/dev/null | grep -oE 'done|error|running' | head -1 || echo "running")

    if [[ "$STATUS" == "done" ]]; then
        echo "✓ Cloud-init completed"
        break
    elif [[ "$STATUS" == "error" ]]; then
        echo "⚠ Cloud-init reported an error. Attempting manual install..."
        az vm run-command invoke -g "$RESOURCE_GROUP" -n "$VM_NAME" \
            --command-id RunShellScript \
            --scripts "curl -sL https://aka.ms/InstallAzureCLIDeb | bash; pip3 install azure-ai-projects azure-identity openai" \
            --query "value[0].message" -o tsv > /dev/null 2>&1
        echo "✓ Manual install completed"
        break
    fi
    echo "  Still running... ($i/30)"
    sleep 10
done

# --- Verify installation ---
echo ""
echo "Verifying installation..."
VERIFY=$(az vm run-command invoke -g "$RESOURCE_GROUP" -n "$VM_NAME" \
    --command-id RunShellScript \
    --scripts "python3 --version; az --version | head -1; python3 -c 'import azure.ai.projects; print(\"SDK OK\")'" \
    --query "value[0].message" -o tsv)
echo "$VERIFY" | grep -E "Python|azure-cli|SDK" | sed 's/^/  /'

# --- Verify DNS resolution for MCP ---
MCP_FQDN=$(az containerapp show -g "$RESOURCE_GROUP" -n mcp-http-server --query "properties.configuration.ingress.fqdn" -o tsv 2>/dev/null || echo "")
if [[ -n "$MCP_FQDN" ]]; then
    echo ""
    echo "Verifying MCP DNS resolution..."
    DNS_CHECK=$(az vm run-command invoke -g "$RESOURCE_GROUP" -n "$VM_NAME" \
        --command-id RunShellScript \
        --scripts "nslookup $MCP_FQDN | grep -A1 'Name:' | head -2" \
        --query "value[0].message" -o tsv)
    echo "$DNS_CHECK" | grep -E "Name:|Address:" | sed 's/^/  /'
fi

# --- Summary ---
echo ""
echo "============================================================"
echo "VM SETUP COMPLETE"
echo "============================================================"
echo "  VM Name:        $VM_NAME"
echo "  Public IP:      $PUBLIC_IP (SSH: ssh $ADMIN_USER@$PUBLIC_IP)"
echo "  Private IP:     $PRIVATE_IP"
echo "  Identity:       $MI_PRINCIPAL"
echo "  Roles:          Cognitive Services User, Azure AI Developer"
echo ""
echo "Installed:"
echo "  - Python 3, pip"
echo "  - Azure CLI"
echo "  - azure-ai-projects, azure-identity, openai"
echo ""
echo "Next steps:"
echo "  # Run direct MCP test (no auth required):"
echo "  az vm run-command invoke -g $RESOURCE_GROUP -n $VM_NAME \\"
echo "    --command-id RunShellScript --scripts 'python3 /home/$ADMIN_USER/test_mcp_direct.py'"
echo ""
echo "  # Run agent test with managed identity:"
echo "  az vm run-command invoke -g $RESOURCE_GROUP -n $VM_NAME \\"
echo "    --command-id RunShellScript --scripts 'python3 /home/$ADMIN_USER/test_agent_mcp.py'"
echo ""
echo "  # Or SSH in (if Conditional Access allows):"
echo "  ssh $ADMIN_USER@$PUBLIC_IP"
echo "============================================================"
