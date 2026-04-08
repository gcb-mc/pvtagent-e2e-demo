# Private MCP Server E2E Lab — What We Built on Top of Template 19

This document explains everything we added on top of the original [Template 19 (Hybrid Private Resources Agent Setup)](../README.md) to deploy and test a **fully private MCP server** integrated with Azure AI Foundry agents.

---

## Original Template 19 — What It Provides

Template 19 deploys an Azure AI Foundry account with:

- **VNet with 3 subnets**: `agent-subnet` (Data Proxy), `pe-subnet` (private endpoints), `mcp-subnet` (Container Apps)
- **AI Services account** with public network access disabled (default) and Data Proxy configured via `networkInjections`
- **Backend resources on private endpoints**: AI Search, Cosmos DB, Storage
- **Private DNS zones** for all privatelink domains
- **Project + Capability Host** for agent orchestration
- **RBAC role assignments** for the project managed identity

What it does **NOT** create:
- No Azure Container Registry (ACR)
- No Key Vault (code is commented out in `standard-dependent-resources.bicep`)
- No Container Apps environment or MCP server
- No outputs from `main.bicep` — resource discovery must happen via CLI

---

## What We Added — The MCP Layer

We built a fully private MCP server deployment on top of template 19's infrastructure, using the [python-basic-as-hell-mcp-server](https://github.com/mattfeltonma/python-basic-as-hell-mcp-server) by Matt Felton.

### The MCP Server

| Property | Value |
|----------|-------|
| **Repository** | [mattfeltonma/python-basic-as-hell-mcp-server](https://github.com/mattfeltonma/python-basic-as-hell-mcp-server) |
| **Framework** | [FastMCP](https://gofastmcp.com/) 3.1.1 |
| **Transport** | Streamable HTTP (required by Azure AI Agents) |
| **Endpoint** | `/mcp` |
| **Port** | 8080 |
| **Tool** | `get_weather(city: str)` — returns current weather from [WeatherAPI](https://www.weatherapi.com/) |
| **Auth** | JWT verifier (commented out for testing) |
| **Base Image** | `python:3.12-slim` |

### Architecture

```
┌───────────────────────────────────────────────────────────────────┐
│  VPN Gateway / ExpressRoute / Azure Bastion                       │
└──────────────────────────────┬────────────────────────────────────┘
                               │
                ┌──────────────▼──────────────┐
                │      AI Services Account     │
                │   (publicNetworkAccess:      │
                │        DISABLED)             │
                │                              │
                │  ┌────────────────────────┐  │
                │  │   Data Proxy / Agent   │  │
                │  │      ToolServer        │  │
                │  └───────────┬────────────┘  │
                └──────────────┼──────────────┘
                               │ networkInjections
                ┌──────────────▼──────────────┐
                │     Private VNet             │
                │                              │
                │  ┌──────────────────────┐    │
                │  │   agent-subnet       │    │  ← Data Proxy injected here
                │  └──────────────────────┘    │
                │                              │
                │  ┌──────────────────────┐    │
                │  │   pe-subnet          │    │  ← Private endpoints:
                │  │  • AI Search PE      │    │    Search, Cosmos, Storage,
                │  │  • Cosmos DB PE      │    │    AI Services
                │  │  • Storage PE        │    │
                │  └──────────────────────┘    │
                │                              │
                │  ┌──────────────────────┐    │
                │  │   mcp-subnet         │    │  ← NEW: Container Apps
                │  │  ┌────────────────┐  │    │    Environment (internal)
                │  │  │  mcp-env (CAE) │  │    │
                │  │  │  internal-only │  │    │
                │  │  │                │  │    │
                │  │  │ ┌────────────┐ │  │    │
                │  │  │ │ weather-mcp│ │  │    │  ← FastMCP server
                │  │  │ │ :8080/mcp  │ │  │    │    (get_weather tool)
                │  │  │ └────────────┘ │  │    │
                │  │  └────────────────┘  │    │
                │  └──────────────────────┘    │
                │                              │
                │  ┌──────────────────────┐    │
                │  │  Private DNS Zones   │    │  ← NEW: Container Apps
                │  │  • privatelink.*     │    │    domain DNS zone
                │  │  • <cae-domain>      │    │
                │  └──────────────────────┘    │
                └──────────────────────────────┘

        ┌─────────────────┐     ┌─────────────────┐
        │  ACR (Basic)    │     │  Key Vault       │
        │  weather-mcp    │     │  WEATHER-API-KEY  │  ← NEW resources
        │  :latest        │     │  (RBAC-enabled)   │    created by script
        └─────────────────┘     └─────────────────┘
```

### Data Flow: Agent → MCP Tool

```
User ("What's the weather in London?")
  → Foundry Agent (gpt-4o-mini + MCPTool)
    → Data Proxy (networkInjections)
      → Private VNet (agent-subnet)
        → mcp-subnet (internal CAE)
          → weather-mcp Container App (:8080/mcp)
            → WeatherAPI (external, via container egress)
              → Response back through the chain
```

---

## Step-by-Step: What Was Done

### Step 1: Confirmed mcp-subnet Delegation

Template 19's `vnet.bicep` already creates the `mcp-subnet` with `Microsoft.App/environments` delegation. The deploy script validates this at runtime:

```bash
az network vnet subnet show -g <rg> --vnet-name <vnet> -n mcp-subnet \
  --query "delegations[0].serviceName"
# Expected: "Microsoft.App/environments"
```

### Step 2: Built & Pushed Docker Image

Since template 19 doesn't include an ACR, the deploy script creates one and builds the image using `az acr build` (no local Docker required):

```bash
# Clone the weather MCP server
git clone --depth 1 https://github.com/mattfeltonma/python-basic-as-hell-mcp-server.git /tmp/mcp-server

# Build in ACR (cloud build)
az acr build --registry <acr> --image weather-mcp:latest --platform linux/amd64 /tmp/mcp-server
```

A user-assigned managed identity (`mcp-identity`) is created with `AcrPull` role to allow the Container App to pull the image.

### Step 3: Stored Secrets in Key Vault

Instead of passing `WEATHER_API_KEY` as a plain environment variable, we:

1. Created a Key Vault with RBAC authorization enabled
2. Stored the API key as a secret (`WEATHER-API-KEY`)
3. Granted `mcp-identity` the `Key Vault Secrets User` role
4. The Container App references the secret via Key Vault reference:
   ```
   --secrets "weather-api-key=keyvaultref:<secret-uri>,identityref:<identity-id>"
   --env-vars "WEATHER_API_KEY=secretref:weather-api-key"
   ```

### Step 4: Created Private Container Apps Environment

The Container Apps environment is deployed on `mcp-subnet` with `--internal-only true`:

- **No public IP** — the environment gets only a private static IP
- **Private DNS zone** created for the Container Apps default domain
- **VNet link** connects the DNS zone to the VNet
- **Wildcard A record** (`*`) points to the static IP

This means the MCP server FQDN is only resolvable from within the VNet.

### Step 5: Deployed the MCP Container

The weather MCP server runs as a Container App with:

- Image from the private ACR (pulled via managed identity)
- Port 8080 with "external" ingress (external within the internal-only CAE = VNet-scoped)
- `WEATHER_API_KEY` injected from Key Vault
- Min 1 replica for availability

The private FQDN is: `https://mcp-http-server.<cae-default-domain>/mcp`

### Step 6: Registered MCP with Foundry Agent (Python SDK)

The test scripts create an agent with `MCPTool` pointing to the private FQDN:

```python
mcp_tool = MCPTool(
    server_label="weather-mcp",
    server_url="https://mcp-http-server.<domain>/mcp",
    require_approval="never",
)

agent = project_client.agents.create_version(
    agent_name="mcp-test-agent",
    definition=PromptAgentDefinition(
        model="gpt-4o-mini",
        instructions="When asked about weather, use the get_weather tool.",
        tools=[mcp_tool],
    ),
)
```

The agent routes MCP calls through the Data Proxy → private VNet → MCP server.

### Step 7: Verified End-to-End Private Connectivity

Two verification paths:

1. **Direct HTTP connectivity** — Sends MCP JSON-RPC requests (initialize → tools/list → tools/call get_weather) directly to the private FQDN
2. **Agent via Data Proxy** — Creates an agent, sends "What's the weather in London?", validates the response contains weather data routed through the full private chain

---

## Files We Created / Modified

### New Files

| File | Purpose |
|------|---------|
| [`tests/deploy-mcp.sh`](deploy-mcp.sh) | Automated deployment script (Steps 1–5). Creates ACR, Key Vault, CAE, Container App, DNS. |
| [`tests/teardown-mcp.sh`](teardown-mcp.sh) | Cleanup script. Removes only MCP resources, keeps all Bicep-deployed infrastructure. |
| [`tests/README.md`](README.md) | This file. Documents everything we built on top of template 19. |

### Modified Files

| File | Changes |
|------|---------|
| [`tests/test_mcp_tools_agents_v2.py`](test_mcp_tools_agents_v2.py) | Switched from multi-auth MCP (`/noauth/mcp`, `add` tool) to weather MCP (`/mcp`, `get_weather` tool). Private-only mode. |
| [`tests/test_agents_v2.py`](test_agents_v2.py) | Same endpoint/tool updates. Agent prompt now asks for weather instead of math. |
| [`tests/TESTING-GUIDE.md`](TESTING-GUIDE.md) | Step 4 rewritten for weather MCP + Key Vault + deploy/teardown scripts. Step 5 updated. |

### Unchanged (Template 19 Originals)

| File | Role |
|------|------|
| `main.bicep` | Orchestrates VNet, AI Services, backend resources, project, capability host |
| `modules-network-secured/vnet.bicep` | Creates VNet with agent-subnet, pe-subnet, mcp-subnet |
| `modules-network-secured/ai-account-identity.bicep` | AI Services with networkInjections for Data Proxy |
| `modules-network-secured/private-endpoint-and-dns.bicep` | Private endpoints for Search, Cosmos, Storage |
| All other Bicep modules | Role assignments, project identity, capability host, etc. |

---

## Quick Start

```bash
# 1. Deploy Template 19 (if not already done)
RESOURCE_GROUP="rg-hybrid-agent-test"
LOCATION="swedencentral"
az group create --name $RESOURCE_GROUP --location $LOCATION
az deployment group create \
  --resource-group $RESOURCE_GROUP \
  --template-file main.bicep \
  --parameters location=$LOCATION

# 2. Deploy the private MCP server
cd tests
./deploy-mcp.sh --resource-group $RESOURCE_GROUP --weather-api-key <your-key>

# 3. Export the MCP URL from the deploy output
export MCP_SERVER_PRIVATE="https://<fqdn>/mcp"
export PROJECT_ENDPOINT="https://<ai-services>.services.ai.azure.com/api/projects/<project>"

# 4. Run tests (from within VNet — VPN/Bastion required)
pip install azure-ai-projects azure-identity openai
python test_mcp_tools_agents_v2.py --test all --retry 3

# 5. Cleanup MCP resources only
./teardown-mcp.sh --resource-group $RESOURCE_GROUP --yes

# 6. Cleanup everything
az group delete --name $RESOURCE_GROUP --yes --no-wait
```

---

## Known Issues

| Issue | Cause | Workaround |
|-------|-------|------------|
| ~50% `TaskCanceledException` on agent tests | Hyena cluster has 2 scale units, Data Proxy only on 1 | Use `--retry 3` flag |
| Portal shows "New Foundry Not Supported" | Network injection not supported in portal UI | Use SDK testing |
| Tests require VNet connectivity | Everything is private (by design) | Connect via VPN Gateway, ExpressRoute, or Azure Bastion |

---

## References

- [Template 19 README](../README.md) — Original template documentation
- [TESTING-GUIDE.md](TESTING-GUIDE.md) — Detailed step-by-step testing instructions
- [python-basic-as-hell-mcp-server](https://github.com/mattfeltonma/python-basic-as-hell-mcp-server) — The MCP server we deployed
- [FastMCP](https://gofastmcp.com/) — The MCP framework used by the weather server
- [Azure AI Foundry Private Link](https://learn.microsoft.com/en-us/azure/ai-foundry/how-to/configure-private-link) — Private networking docs
- [Container Apps Internal Environments](https://learn.microsoft.com/en-us/azure/container-apps/vnet-custom-internal) — Internal-only CAE docs
