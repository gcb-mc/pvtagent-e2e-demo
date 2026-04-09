# Hybrid Private Resources - Testing Guide

This guide covers testing Azure AI Foundry agents with tools that access private resources (AI Search, MCP servers). By default, the Foundry (AI Services) resource has **public network access disabled**. You can optionally [switch to public access](#switching-the-foundry-resource-to-public-access) for easier development.

> **Private Foundry (default):** You need a secure connection (VPN Gateway, ExpressRoute, or Azure Bastion) to reach the Foundry resource and run SDK tests. See [Connecting to a Private Foundry Resource](#connecting-to-a-private-foundry-resource).

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Connecting to a Private Foundry Resource](#connecting-to-a-private-foundry-resource)
3. [Switching the Foundry Resource to Public Access](#switching-the-foundry-resource-to-public-access)
4. [Step 1: Deploy the Template](#step-1-deploy-the-template)
5. [Step 2: Verify Private Endpoints](#step-2-verify-private-endpoints)
6. [Step 3: Create Test Data in AI Search](#step-3-create-test-data-in-ai-search)
7. [Step 4: Deploy MCP Server](#step-4-deploy-mcp-server)
8. [Step 5: Test via SDK](#step-5-test-via-sdk)
9. [Step 6: VM-Based VNet Testing](#step-6-vm-based-vnet-testing)
10. [Troubleshooting](#troubleshooting)
11. [Test Results Summary](#test-results-summary)

---

## Prerequisites

- Azure CLI installed and authenticated
- Owner or Contributor role on the subscription
- Python 3.10+ (for SDK testing)

---

## Connecting to a Private Foundry Resource

When the Foundry resource has public network access **disabled** (the default), you must connect to the Azure VNet before you can reach the Foundry endpoint for SDK testing or portal access.

Azure provides three methods:

| Method | Use Case |
|--------|----------|
| **Azure VPN Gateway** | Connect from your local machine/network over an encrypted tunnel |
| **Azure ExpressRoute** | Private, dedicated connection from on-premises infrastructure |
| **Azure Bastion** | Access a jump box VM on the VNet securely through the Azure portal |

For step-by-step setup instructions, see: [Securely connect to Azure AI Foundry](https://learn.microsoft.com/en-us/azure/ai-foundry/how-to/configure-private-link?view=foundry#securely-connect-to-foundry).

Once connected to the VNet, all SDK commands and portal interactions in this guide will work as documented.

---

## Switching the Foundry Resource to Public Access

If your security policy permits, you can enable public network access on the Foundry resource so that SDK tests and portal access work directly from the internet without VPN/ExpressRoute/Bastion.

In `modules-network-secured/ai-account-identity.bicep`, change:

```bicep
// Change from:
publicNetworkAccess: 'Disabled'
// To:
publicNetworkAccess: 'Enabled'

// Also change:
defaultAction: 'Deny'
// To:
defaultAction: 'Allow'
```

Then redeploy the template. Backend resources (AI Search, Cosmos DB, Storage) remain on private endpoints regardless of this setting.

To revert to private, set `publicNetworkAccess: 'Disabled'` and `defaultAction: 'Deny'`, then redeploy.

---

## Step 1: Deploy the Template

```bash
# Set variables
RESOURCE_GROUP="rg-hybrid-agent-test"
LOCATION="westus2"

# Create resource group
az group create --name $RESOURCE_GROUP --location $LOCATION

# Deploy the template
az deployment group create \
  --resource-group $RESOURCE_GROUP \
  --template-file main.bicep \
  --parameters location=$LOCATION

# Get the deployment outputs
AI_SERVICES_NAME=$(az cognitiveservices account list -g $RESOURCE_GROUP --query "[0].name" -o tsv)
echo "AI Services: $AI_SERVICES_NAME"
```

---

## Step 2: Verify Private Endpoints

Confirm that backend resources have private endpoints:

```bash
# List private endpoints
az network private-endpoint list -g $RESOURCE_GROUP -o table

# Expected: Private endpoints for:
# - AI Search (*search-private-endpoint)
# - Cosmos DB (*cosmosdb-private-endpoint)
# - Storage (*storage-private-endpoint)
# - AI Services (*-private-endpoint)

# If public access is ENABLED, verify AI Services is publicly accessible:
AI_ENDPOINT=$(az cognitiveservices account show -g $RESOURCE_GROUP -n $AI_SERVICES_NAME --query "properties.endpoint" -o tsv)
curl -I $AI_ENDPOINT
# Should return HTTP 200 (accessible from internet)

# If public access is DISABLED (default), the curl above will fail.
# You must connect via VPN/ExpressRoute/Bastion to reach the endpoint.
# See: Connecting to a Private Foundry Resource
```

---

## Step 3: Create Test Data in AI Search

Since AI Search has a private endpoint, you need to access it from within the VNet or temporarily allow public access.

### Option A: Temporarily Enable Public Access on AI Search

```bash
AI_SEARCH_NAME=$(az search service list -g $RESOURCE_GROUP --query "[0].name" -o tsv)

# Temporarily enable public access
az search service update -g $RESOURCE_GROUP -n $AI_SEARCH_NAME \
  --public-network-access enabled

# Get admin key
ADMIN_KEY=$(az search admin-key show -g $RESOURCE_GROUP --service-name $AI_SEARCH_NAME --query "primaryKey" -o tsv)

# Create test index
curl -X POST "https://${AI_SEARCH_NAME}.search.windows.net/indexes?api-version=2023-11-01" \
  -H "Content-Type: application/json" \
  -H "api-key: ${ADMIN_KEY}" \
  -d '{
    "name": "test-index",
    "fields": [
      {"name": "id", "type": "Edm.String", "key": true},
      {"name": "content", "type": "Edm.String", "searchable": true}
    ]
  }'

# Add a test document
curl -X POST "https://${AI_SEARCH_NAME}.search.windows.net/indexes/test-index/docs/index?api-version=2023-11-01" \
  -H "Content-Type: application/json" \
  -H "api-key: ${ADMIN_KEY}" \
  -d '{
    "value": [
      {"@search.action": "upload", "id": "1", "content": "This is a test document for validating AI Search integration with Azure AI Foundry agents."}
    ]
  }'

# Disable public access again
az search service update -g $RESOURCE_GROUP -n $AI_SEARCH_NAME \
  --public-network-access disabled
```

---

## Step 4: Deploy MCP Server

Deploy the [weather MCP server](https://github.com/mattfeltonma/python-basic-as-hell-mcp-server) as a fully private Container App with Key Vault secret integration.

> **Important**: Azure AI Agents require MCP servers that implement the **Streamable HTTP transport** (JSON-RPC over HTTP with session management). This FastMCP server provides this at the `/mcp` endpoint.

### Prerequisites

- A free Weather API key from [weatherapi.com](https://www.weatherapi.com/)
- Template 19 deployed (VNet with `mcp-subnet` must exist)

### Quick Start (Automated)

```bash
# Deploy everything with one command:
./deploy-mcp.sh --resource-group $RESOURCE_GROUP --weather-api-key <your-weather-api-key>

# The script will output the private MCP URL. Export it:
export MCP_SERVER_PRIVATE="https://<fqdn>/mcp"

# To tear down MCP resources only (keeps VNet, AI Services, etc.):
./teardown-mcp.sh --resource-group $RESOURCE_GROUP --yes
```

The `deploy-mcp.sh` script performs steps 4.1–4.5 below automatically. Read on for manual steps or details.

### 4.1 Build and Push Docker Image to ACR

```bash
# Create ACR
UNIQUE_SUFFIX=$(echo -n "$RESOURCE_GROUP" | md5sum | cut -c1-6)
ACR_NAME="mcpacr${UNIQUE_SUFFIX}"
az acr create --name $ACR_NAME --resource-group $RESOURCE_GROUP --sku Basic --location $LOCATION

# Clone the weather MCP server repo and build in ACR (no local Docker needed)
TEMP_DIR=$(mktemp -d)
git clone --depth 1 https://github.com/mattfeltonma/python-basic-as-hell-mcp-server.git "$TEMP_DIR/mcp-server"
az acr build --registry $ACR_NAME --resource-group $RESOURCE_GROUP \
  --image weather-mcp:latest --platform linux/amd64 "$TEMP_DIR/mcp-server"
rm -rf "$TEMP_DIR"

# Create user-assigned identity with AcrPull role
az identity create --name mcp-identity --resource-group $RESOURCE_GROUP --location $LOCATION
IDENTITY_ID=$(az identity show --name mcp-identity -g $RESOURCE_GROUP --query "id" -o tsv)
IDENTITY_PRINCIPAL=$(az identity show --name mcp-identity -g $RESOURCE_GROUP --query "principalId" -o tsv)
ACR_ID=$(az acr show --name $ACR_NAME -g $RESOURCE_GROUP --query "id" -o tsv)
az role assignment create --assignee $IDENTITY_PRINCIPAL --role AcrPull --scope $ACR_ID
sleep 30
```

### 4.2 Store Secret in Key Vault

```bash
KV_NAME="mcpkv${UNIQUE_SUFFIX}"
az keyvault create --name $KV_NAME --resource-group $RESOURCE_GROUP --location $LOCATION \
  --enable-rbac-authorization true

# Grant yourself Secrets Officer to set secrets
CURRENT_USER=$(az ad signed-in-user show --query "id" -o tsv)
KV_ID=$(az keyvault show --name $KV_NAME -g $RESOURCE_GROUP --query "id" -o tsv)
az role assignment create --assignee $CURRENT_USER --role "Key Vault Secrets Officer" --scope $KV_ID
sleep 30

# Store the weather API key
az keyvault secret set --vault-name $KV_NAME --name "WEATHER-API-KEY" --value "<your-weather-api-key>"

# Grant managed identity Key Vault Secrets User
az role assignment create --assignee $IDENTITY_PRINCIPAL --role "Key Vault Secrets User" --scope $KV_ID
sleep 30
```

### 4.3 Create Private Container Apps Environment

```bash
VNET_NAME=$(az network vnet list -g $RESOURCE_GROUP --query "[0].name" -o tsv)
MCP_SUBNET_ID=$(az network vnet subnet show -g $RESOURCE_GROUP --vnet-name $VNET_NAME -n "mcp-subnet" --query "id" -o tsv)

# Create internal-only Container Apps environment (no public internet exposure)
az containerapp env create \
  --resource-group $RESOURCE_GROUP \
  --name "mcp-env" \
  --location $LOCATION \
  --infrastructure-subnet-resource-id $MCP_SUBNET_ID \
  --internal-only true
```

### 4.4 Configure Private DNS

```bash
MCP_STATIC_IP=$(az containerapp env show -g $RESOURCE_GROUP -n "mcp-env" --query "properties.staticIp" -o tsv)
DEFAULT_DOMAIN=$(az containerapp env show -g $RESOURCE_GROUP -n "mcp-env" --query "properties.defaultDomain" -o tsv)

# Create private DNS zone and link to VNet
az network private-dns zone create -g $RESOURCE_GROUP -n $DEFAULT_DOMAIN
VNET_ID=$(az network vnet show -g $RESOURCE_GROUP -n $VNET_NAME --query "id" -o tsv)
az network private-dns link vnet create \
  -g $RESOURCE_GROUP -z $DEFAULT_DOMAIN -n "containerapp-link" -v $VNET_ID --registration-enabled false

# Add wildcard A record
az network private-dns record-set a add-record -g $RESOURCE_GROUP -z $DEFAULT_DOMAIN -n "*" -a $MCP_STATIC_IP
```

### 4.5 Deploy the MCP Container

```bash
# Get Key Vault secret URI
KV_SECRET_URI=$(az keyvault secret show --vault-name $KV_NAME --name "WEATHER-API-KEY" --query "id" -o tsv)

# Deploy container app with Key Vault secret reference
az containerapp create \
  --resource-group $RESOURCE_GROUP \
  --name "mcp-http-server" \
  --environment "mcp-env" \
  --image "${ACR_NAME}.azurecr.io/weather-mcp:latest" \
  --target-port 8080 \
  --ingress external \
  --min-replicas 1 \
  --max-replicas 3 \
  --user-assigned $IDENTITY_ID \
  --registry-server "${ACR_NAME}.azurecr.io" \
  --registry-identity $IDENTITY_ID \
  --secrets "weather-api-key=keyvaultref:${KV_SECRET_URI},identityref:${IDENTITY_ID}" \
  --env-vars "WEATHER_API_KEY=secretref:weather-api-key"

# Get the private MCP server URL
MCP_FQDN=$(az containerapp show -g $RESOURCE_GROUP -n "mcp-http-server" --query "properties.configuration.ingress.fqdn" -o tsv)
echo "MCP Server URL: https://${MCP_FQDN}/mcp"
```

> **Note**: The ingress is "external" but since the Container Apps environment is `internal-only`, this means the FQDN is only reachable from within the VNet. There is no public internet exposure.

---

## Step 5: Test via SDK

Five test scripts are provided for different scenarios:

| Script | Description | Env Vars |
|--------|-------------|----------|
| `test_agents_v2.py` | Full test suite: MCP connectivity, OpenAI API, basic agent, AI Search, MCP tools (runs all 5 tests sequentially, no CLI flags) | `PROJECT_ENDPOINT`, `MCP_SERVER_URL`, `AI_SEARCH_CONNECTION_NAME` |
| `test_mcp_tools_agents_v2.py` | Focused MCP testing: connectivity + agent test via Data Proxy (supports `--test` and `--retry`) | `PROJECT_ENDPOINT`, `MCP_SERVER_PRIVATE` |
| `test_ai_search_tool_agents_v2.py` | Focused AI Search testing: connectivity + agent test (supports `--test` and `--retry`) | `PROJECT_ENDPOINT`, `AI_SEARCH_CONNECTION_NAME`, `AI_SEARCH_INDEX_NAME`, `AI_SEARCH_ENDPOINT` |
| `test_mcp_direct.py` | Direct MCP HTTP connectivity test (VNet only, no Azure credentials needed) | `MCP_SERVER_URL` or `--mcp-url` |
| `test_agent_mcp.py` | Agent + MCP test via managed identity from a VM inside the VNet | `PROJECT_ENDPOINT`, `MCP_SERVER_URL` or `--project-endpoint` / `--mcp-url` |

### 5.1 Install Dependencies

```bash
pip install azure-ai-projects azure-identity openai
```

### 5.2 Configure Environment

```bash
# Set the project endpoint (get from Azure Portal -> AI Services -> Projects -> Properties)
export PROJECT_ENDPOINT="https://<ai-services>.services.ai.azure.com/api/projects/<project>"

# For test_agents_v2.py (uses MCP_SERVER_URL):
export MCP_SERVER_URL="https://<private-mcp-fqdn>/mcp"

# For test_mcp_tools_agents_v2.py (uses MCP_SERVER_PRIVATE):
export MCP_SERVER_PRIVATE="https://<private-mcp-fqdn>/mcp"

# For AI Search tests (optional — auto-detected from project connections if not set):
export AI_SEARCH_CONNECTION_NAME="<connection-name>"
export AI_SEARCH_INDEX_NAME="test-index"
# Only needed for the direct connectivity test (requires VNet access):
export AI_SEARCH_ENDPOINT="https://<search-service>.search.windows.net"
```

> **Note**: `test_agents_v2.py` reads `MCP_SERVER_URL` while `test_mcp_tools_agents_v2.py` reads `MCP_SERVER_PRIVATE`. Set both to the same value if running both scripts.

### 5.3 Run Full Test Suite

`test_agents_v2.py` runs **all 5 tests sequentially** with no CLI flags:

```bash
# Runs: MCP connectivity → OpenAI Responses API → Basic Agent → AI Search → MCP Tool
python test_agents_v2.py
```

The 5 tests in order:

| # | Test | What It Validates |
|---|------|-------------------|
| 1 | MCP Server Connectivity | Direct HTTP session flow to MCP server (requires VNet access) |
| 2 | OpenAI Responses API | Direct model call without an agent — verifies API access works |
| 3 | Basic Agent | Agent creation + conversation using Responses API (no tools) |
| 4 | AI Search Tool | Agent with AI Search tool queries private AI Search via Data Proxy |
| 5 | MCP Tool | Agent with MCP tool calls private MCP server via Data Proxy |

### 5.4 Run MCP-Focused Tests

```bash
# Run all MCP tests (connectivity + private agent test)
python test_mcp_tools_agents_v2.py

# Test only direct HTTP connectivity
python test_mcp_tools_agents_v2.py --test connectivity

# Test only agent → MCP via Data Proxy
python test_mcp_tools_agents_v2.py --test private

# With retries (useful for transient Hyena cluster routing issues)
python test_mcp_tools_agents_v2.py --test private --retry 3
```

### 5.5 Run AI Search-Focused Tests

```bash
# Run all AI Search tests (connectivity + agent test)
python test_ai_search_tool_agents_v2.py

# Test only direct REST API connectivity (requires VNet access + AI_SEARCH_ENDPOINT set)
python test_ai_search_tool_agents_v2.py --test connectivity

# Test only agent → AI Search via Data Proxy
python test_ai_search_tool_agents_v2.py --test agent

# With retries
python test_ai_search_tool_agents_v2.py --retry 3
```

### 5.6 Understanding Test Results

**MCP Connectivity Test**: Direct HTTP test to verify the MCP server responds correctly:
- Sends `initialize` request and captures `mcp-session-id` header
- Sends `tools/list` to enumerate available tools (expects `get_weather`)
- Sends `tools/call` to execute the `get_weather` tool with `{"city": "London"}`

**MCP Tool via Agent Test**: Tests the full agent workflow:
- Creates an agent with MCP tool configuration pointing to the private FQDN
- Sends "What is the current weather in London?" which triggers the `get_weather` tool
- The agent routes through the Data Proxy → private VNet → MCP server
- Validates the agent returns weather data

> **Known Issue**: Agent tests may fail ~50% of the time with `TaskCanceledException` due to Hyena cluster routing. The Data Proxy is only deployed on one of two scale units, and the load balancer routes in round-robin fashion. Use `--retry` to mitigate.

---

## Step 6: VM-Based VNet Testing

For scenarios where VPN Gateway or Cloud Shell VNet integration isn't available (e.g., Conditional Access blocks `az login`), you can create a Linux VM inside the VNet and test using managed identity authentication.

See [VM-TESTING-GUIDE.md](VM-TESTING-GUIDE.md) for the full walkthrough.

### Quick Start

```bash
# Create test VM with managed identity and pre-installed SDK packages
./setup-test-vm.sh --resource-group $RESOURCE_GROUP

# SSH into the VM
ssh azureuser@<vm-public-ip>

# Run direct MCP connectivity test (no Azure credentials needed)
python3 test_mcp_direct.py --mcp-url https://mcp-http-server.<env-id>.<region>.azurecontainerapps.io/mcp

# Run agent + MCP test via managed identity
python3 test_agent_mcp.py \
  --project-endpoint https://<ai-services>.cognitiveservices.azure.com/api/projects/<project> \
  --mcp-url https://mcp-http-server.<env-id>.<region>.azurecontainerapps.io/mcp

# Interactive chat mode
python3 test_agent_mcp.py --project-endpoint <endpoint> --mcp-url <url> --interactive
```

### VM Test Scripts

| Script | Purpose | Auth |
|--------|---------|------|
| `test_mcp_direct.py` | Direct HTTP connectivity to MCP server (3-step JSON-RPC flow) | None (direct HTTP) |
| `test_agent_mcp.py` | Full agent + MCP tool chain via Data Proxy | Managed Identity |
| `setup-test-vm.sh` | Creates Ubuntu VM in `vm-subnet` with Python, SDK, and managed identity | Azure CLI (local) |

> **Note**: `test_agent_mcp.py` uses the **Agents v1 API** (create_agent/threads/messages pattern) with `ManagedIdentityCredential`, while the SDK test scripts (`test_agents_v2.py`, etc.) use the **Agents v2 API** (create_version/conversations/responses pattern) with `DefaultAzureCredential`.

### Reference Documentation

- [VM-TESTING-GUIDE.md](VM-TESTING-GUIDE.md) — Full VM setup, SSH, and test instructions
- [AZURE-SERVICES-AND-ROLES.md](AZURE-SERVICES-AND-ROLES.md) — Complete list of all Azure services and RBAC role assignments
- [CLOUDSHELL-NOTEBOOK-GUIDE.md](CLOUDSHELL-NOTEBOOK-GUIDE.md) — Testing via Cloud Shell notebook

---

## Troubleshooting

### Agent Can't Access AI Search

1. **Verify private endpoint exists**:
   ```bash
   az network private-endpoint list -g $RESOURCE_GROUP --query "[?contains(name,'search')]"
   ```

2. **Check Data Proxy configuration**:
   ```bash
   az cognitiveservices account show -g $RESOURCE_GROUP -n $AI_SERVICES_NAME \
     --query "properties.networkInjections"
   ```

3. **Verify AI Search connection in project**:
   - Go to the portal → Project → Settings → Connections
   - Confirm AI Search connection exists

### MCP Tool Fails with TaskCanceledException

This is a **known issue** with the Hyena cluster infrastructure:
- The Data Proxy is deployed on only **one of two scale units**
- The load balancer routes requests in **round-robin** fashion
- ~50% of requests hit the wrong scale unit and get `TaskCanceledException`

**Workaround**: Use `--retry` flag when running tests:
```bash
python test_mcp_tools_agents_v2.py --test private --retry 3
```

### MCP Tool Fails with 400 Bad Request

Check the error message for details:
- **404 Not Found**: Verify the MCP server URL includes the correct path (`/mcp`)
- **DNS resolution**: Ensure private DNS zone is configured correctly for Container Apps

### MCP Server Not Responding

1. **Check container app health**:
   ```bash
   az containerapp show -g $RESOURCE_GROUP -n "mcp-http-server" --query "properties.runningStatus"
   ```

2. **Check container logs**:
   ```bash
   az containerapp logs show -g $RESOURCE_GROUP -n "mcp-http-server" --tail 50
   ```

3. **Verify ingress port is 8080** (not 80):
   ```bash
   az containerapp ingress show -g $RESOURCE_GROUP -n "mcp-http-server" --query "targetPort"
   ```

### Portal Shows "New Foundry Not Supported"

This is expected when network injection is configured. Use SDK testing instead - it works perfectly with network injection.

---

## Test Results Summary

### Test Scripts

| Script | Purpose |
|--------|---------|
| `test_agents_v2.py` | Full test suite: MCP connectivity, OpenAI API, basic agent, AI Search, MCP (5 tests, no CLI flags) |
| `test_mcp_tools_agents_v2.py` | Focused MCP testing with `--test` and `--retry` support |
| `test_ai_search_tool_agents_v2.py` | Focused AI Search testing with `--test` and `--retry` support |
| `test_mcp_direct.py` | Direct MCP HTTP connectivity from VNet (no Azure credentials) |
| `test_agent_mcp.py` | Agent + MCP via managed identity from VNet VM (v1 API, interactive mode) |
| `deploy-mcp.sh` | Automated MCP server deployment (Steps 4.1–4.5) |
| `teardown-mcp.sh` | MCP-only resource cleanup (keeps Bicep resources) |
| `setup-test-vm.sh` | Creates test VM in VNet with managed identity and SDK packages |

### Validated ✅

| Test | Script | Status | Notes |
|------|--------|--------|-------|
| OpenAI Responses API (direct) | `test_agents_v2.py` | ✅ Pass | Works from anywhere (public access) |
| Basic Agent (no tools) | `test_agents_v2.py` | ✅ Pass | Works from anywhere (public access) |
| AI Search Tool via Agent | `test_agents_v2.py`, `test_ai_search_tool_agents_v2.py` | ✅ Pass | Data Proxy routes to private endpoint |
| MCP Connectivity (direct HTTP) | `test_agents_v2.py`, `test_mcp_tools_agents_v2.py`, `test_mcp_direct.py` | ✅ Pass | Server responds with `get_weather` tool |
| MCP Tool via Agent (private) | `test_agents_v2.py`, `test_mcp_tools_agents_v2.py` | ✅ Pass* | *~50% fail rate due to Hyena routing |
| MCP Direct from VM | `test_mcp_direct.py` | ✅ Pass | Requires VM in VNet (no credentials) |
| Agent + MCP from VM | `test_agent_mcp.py` | ✅ Pass | Uses managed identity (v1 API) |

### Known Limitations ⚠️

| Issue | Cause | Workaround |
|-------|-------|------------|
| ~50% TaskCanceledException | Hyena cluster has 2 scale units, Data Proxy only on 1 | Use `--retry` flag |
| Portal "New Foundry" blocked | Network injection not supported in portal | Use SDK testing |

### Architecture Notes

1. **AI Search Tool works** because it uses Azure Private Endpoints with built-in DNS integration (`privatelink.search.windows.net`).

2. **MCP uses Streamable HTTP transport** - The weather MCP server (FastMCP) implements proper session management with `mcp-session-id` headers required by Azure's MCP client.

3. **Container Apps require port 8080** - The weather MCP image runs on port 8080.

4. **Use `/mcp` endpoint** - FastMCP exposes streamable-http at `/mcp` by default.

5. **Secrets in Key Vault** - The `WEATHER_API_KEY` is stored in Key Vault and referenced by the Container App via a managed identity, not plain environment variables.

### SDK Notes ⚠️

- **SDK version**: These scripts require `azure-ai-projects >= 2.0.1`.
- **Class rename**: `AzureAISearchAgentTool` was renamed to `AzureAISearchTool` in SDK v2.0.1. Scripts have been updated accordingly.
- **Deprecated `extra_body` key**: The `"agent"` key in `extra_body` was deprecated in favor of `"agent_reference"`. Scripts have been updated to use `extra_body={"agent_reference": {"name": ..., "type": "agent_reference"}}`.
- **VM scripts use v1 API**: `test_agent_mcp.py` uses the Agents v1 API (`create_agent`/`threads`/`messages`) with `ManagedIdentityCredential`, since VM environments may not support `DefaultAzureCredential` interactive flows.

---

## Cleanup

### Remove MCP Resources Only

```bash
# Remove only MCP-related resources (Container App, CAE, ACR, Key Vault, identity, DNS)
# Keeps VNet, AI Services, Cosmos DB, Storage, AI Search intact
./teardown-mcp.sh --resource-group $RESOURCE_GROUP --yes
```

### Delete Everything

```bash
# Delete all resources including the resource group
az group delete --name $RESOURCE_GROUP --yes --no-wait
```
