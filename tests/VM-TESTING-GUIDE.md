# VM-Based VNet Testing Guide

This guide explains how to create a Linux VM inside the VNet and run end-to-end tests
against private MCP and AI Foundry resources — useful when Cloud Shell VNet integration
isn't available or Conditional Access policies block `az login` from non-compliant devices.

---

## Why Use a VM?

| Scenario | VM Approach Solves It |
|----------|----------------------|
| Conditional Access blocks `az login` on jump-box VMs | Managed identity auth — no interactive login needed |
| Cloud Shell VNet integration unavailable | VM sits directly in the VNet subnet |
| Need to test direct MCP connectivity (private endpoint) | VM resolves private DNS zones automatically |
| Need persistent test environment | VM persists between sessions |

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│  VNet (192.168.0.0/16)                                   │
│                                                          │
│  ┌─────────────┐    ┌─────────────┐    ┌──────────────┐  │
│  │ vm-subnet   │    │ mcp-subnet  │    │ pe-subnet    │  │
│  │ (test-vm)   │───>│ (MCP server)│    │ (Private EPs)│  │
│  │             │    │             │    │              │  │
│  │ Managed ID  │    │ Container   │    │ AI Services  │  │
│  │ Python+SDK  │    │ App (8080)  │    │ Cosmos, etc. │  │
│  └─────────────┘    └─────────────┘    └──────────────┘  │
│        │                                      ▲          │
│        │         ┌─────────────┐              │          │
│        └────────>│ agent-subnet│──────────────┘          │
│                  │ (Data Proxy)│                          │
│                  └─────────────┘                          │
└──────────────────────────────────────────────────────────┘
```

**Test 1 — Direct MCP** (`test_mcp_direct.py`):
`VM → MCP Container App (private IP) → get_weather response`

**Test 2 — Agent + MCP** (`test_agent_mcp.py`):
`VM → Managed Identity → Data Proxy → Agent → MCP tool → response`

---

## Quick Start

### Prerequisites

- Template 19 deployed (the main Bicep template)
- MCP server deployed via `deploy-mcp.sh`
- Azure CLI authenticated locally with Owner/Contributor on the resource group
- A `vm-subnet` in the VNet (created by the template or manually)

### 1. Create the Test VM

```bash
# From your local machine (not the VM):
./setup-test-vm.sh --resource-group <your-rg>

# With custom options:
./setup-test-vm.sh -g <your-rg> --vm-name my-test-vm --vm-size Standard_B2s
```

The script:
1. Creates an Ubuntu 22.04 VM in `vm-subnet`
2. Installs Python 3, Azure CLI, and SDK packages via cloud-init
3. Enables system-assigned managed identity
4. Assigns **Cognitive Services User** (on AI Services) and **Azure AI Developer** (on RG)
5. Verifies DNS resolution to the MCP server's private IP

### 2. Deploy Test Scripts to the VM

```bash
RG="<your-resource-group>"
VM="test-vm"

# Copy test files onto the VM using az vm run-command
az vm run-command invoke -g $RG -n $VM \
  --command-id RunShellScript \
  --scripts "cat > /home/azureuser/test_mcp_direct.py << 'PYEOF'
$(cat test_mcp_direct.py)
PYEOF"

az vm run-command invoke -g $RG -n $VM \
  --command-id RunShellScript \
  --scripts "cat > /home/azureuser/test_agent_mcp.py << 'PYEOF'
$(cat test_agent_mcp.py)
PYEOF"
```

> **Note:** We use `az vm run-command` because SSH may be blocked by Conditional Access
> policies. If SSH works in your environment, use `scp` instead.

### 3. Run the Direct MCP Test

This test validates HTTP connectivity from the VM to the MCP container app
(no Azure credentials required):

```bash
# Discover MCP URL
MCP_FQDN=$(az containerapp show -g $RG -n mcp-http-server \
  --query "properties.configuration.ingress.fqdn" -o tsv)
MCP_URL="https://${MCP_FQDN}/mcp"

# Run test
az vm run-command invoke -g $RG -n $VM \
  --command-id RunShellScript \
  --scripts "python3 /home/azureuser/test_mcp_direct.py --mcp-url $MCP_URL"
```

**Expected output:**
```
MCP endpoint: https://mcp-http-server.<env>.<region>.azurecontainerapps.io/mcp

Step 1/3: JSON-RPC initialize...
  ✓ Server: WeatherMCP
Step 2/3: tools/list...
  ✓ Found 1 tool(s): get_weather
Step 3/3: tools/call 'get_weather'...
  ✓ Response: Current weather in London: ...

==================================================
  ✓ initialize
  ✓ tools_list
  ✓ tools_call
==================================================
RESULT: PASS
```

### 4. Run the Agent + MCP Test

This test validates the full agent chain using managed identity authentication:

```bash
# Discover project endpoint
AI_SERVICES=$(az cognitiveservices account list -g $RG --query "[0].name" -o tsv)
AI_ENDPOINT=$(az cognitiveservices account show -g $RG -n $AI_SERVICES \
  --query "properties.endpoint" -o tsv)
PROJECT=$(az resource list -g $RG --resource-type "Microsoft.CognitiveServices/accounts" \
  --query "[?kind=='AIProject'].name | [0]" -o tsv 2>/dev/null || echo "")

# If no AIProject found, construct from AI Services name suffix
if [ -z "$PROJECT" ]; then
  SUFFIX=$(echo $AI_SERVICES | grep -oP '[a-z0-9]+$')
  PROJECT_ENDPOINT="${AI_ENDPOINT}api/projects/project${SUFFIX}"
else
  PROJECT_ENDPOINT="${AI_ENDPOINT}api/projects/${PROJECT}"
fi

# Run test
az vm run-command invoke -g $RG -n $VM \
  --command-id RunShellScript \
  --scripts "python3 /home/azureuser/test_agent_mcp.py \
    --project-endpoint '$PROJECT_ENDPOINT' \
    --mcp-url '$MCP_URL' \
    --query 'What is the weather in Tokyo?'"
```

**Expected output:**
```
Project: https://aiservices....cognitiveservices.azure.com/api/projects/project...
MCP:     https://mcp-http-server.<env>.<region>.azurecontainerapps.io/mcp
Model:   gpt-4o

Creating AI Project client (managed identity)...
Creating agent with MCP tool...
  Agent ID: asst_abc123
Running query: 'What is the weather in Tokyo?'
  ✓ Response: The current weather in Tokyo is 20.3°C with partly cloudy skies...
  Agent cleaned up

==================================================
RESULT: PASS
==================================================
```

---

## Files Added

| File | Purpose |
|------|---------|
| [setup-test-vm.sh](setup-test-vm.sh) | Creates Ubuntu VM, installs deps, enables managed identity, assigns RBAC |
| [test_mcp_direct.py](test_mcp_direct.py) | Direct MCP JSON-RPC test (no Azure auth, stdlib only) |
| [test_agent_mcp.py](test_agent_mcp.py) | Agent + MCP tool test via managed identity (single query or interactive) |
| [VM-TESTING-GUIDE.md](VM-TESTING-GUIDE.md) | This guide |

---

## Troubleshooting

### DNS resolution fails

```bash
# Check from the VM:
az vm run-command invoke -g $RG -n $VM \
  --command-id RunShellScript \
  --scripts "nslookup mcp-http-server.<env>.<region>.azurecontainerapps.io"
```

The MCP FQDN should resolve to a **private IP** (e.g. 192.168.2.x). If it resolves to
a public IP, verify the private DNS zone `azurecontainerapps.io` is linked to the VNet.

### MCP connection refused / timeout

- Verify MCP container app is running: `az containerapp show -g $RG -n mcp-http-server --query "properties.runningStatus"`
- Check ingress is `internal`: `az containerapp ingress show -g $RG -n mcp-http-server`
- Try curl from VM: `az vm run-command invoke ... --scripts "curl -sk https://<fqdn>/mcp -d '{}' -H 'Content-Type: application/json'"`

### Agent test: "identity not found" or 401

- Managed identity needs ~5 minutes after creation for role propagation
- Verify identity exists: `az vm identity show -g $RG -n $VM`
- Verify roles: `az role assignment list --assignee <principal-id> -o table`

### Agent test: "model not found"

- Default model is `gpt-4o`. If your deployment uses a different name:
  ```bash
  --model "gpt-4o-mini"  # or whatever your deployment is named
  ```

### Conditional Access blocks SSH

This is expected in enterprise environments. Use `az vm run-command invoke` for all
operations — it routes through the Azure control plane, not SSH.

---

## Cleanup

```bash
# Delete the test VM and its resources
az vm delete -g $RG -n test-vm --yes
az network public-ip delete -g $RG -n test-vm-pip
az network nic delete -g $RG -n test-vmVMNic  # name may vary
az disk list -g $RG --query "[?starts_with(name,'test-vm')].name" -o tsv | \
  xargs -I{} az disk delete -g $RG -n {} --yes
```
