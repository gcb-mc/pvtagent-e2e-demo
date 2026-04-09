# Agent via Private Networking: e2e-demo

End-to-end lab for deploying and testing a **fully private MCP server** integrated with **Azure AI Foundry agents**. Built on top of [Foundry Samples Template 19 (Hybrid Private Resources Agent Setup)](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/19-hybrid-private-resources-agent-setup).

## What This Repo Contains

This repo extracts and extends Template 19 from [microsoft-foundry/foundry-samples](https://github.com/microsoft-foundry/foundry-samples) to demonstrate a complete private-networking scenario: deploying an MCP tool server on a VNet-isolated Container Apps environment and calling it from an Azure AI Foundry agent through the Data Proxy.

### Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│  Secure Access (VPN Gateway / ExpressRoute / Azure Bastion)         │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                ┌──────────────▼──────────────┐
                │      AI Services Account     │
                │   (public access: DISABLED)  │
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
                │  agent-subnet  ← Data Proxy  │
                │  pe-subnet     ← Private     │
                │    endpoints (Search,        │
                │    Cosmos DB, Storage)        │
                │  mcp-subnet    ← Container   │
                │    Apps (internal-only)       │
                │    ┌────────────────────┐    │
                │    │  weather-mcp       │    │
                │    │  FastMCP :8080/mcp │    │
                │    └────────────────────┘    │
                │                              │
                │  Private DNS Zones           │
                └──────────────────────────────┘

        ┌─────────────────┐     ┌─────────────────┐
        │  ACR (Basic)    │     │  Key Vault       │
        │  weather-mcp    │     │  WEATHER-API-KEY  │
        │  :latest        │     │  (RBAC-enabled)   │
        └─────────────────┘     └─────────────────┘
```

### Data Flow

```
User ("What's the weather in London?")
  → Foundry Agent (gpt-4o-mini + MCPTool)
    → Data Proxy (networkInjections)
      → Private VNet → mcp-subnet
        → weather-mcp Container App (:8080/mcp)
          → WeatherAPI (external)
            → Response back through the chain
```

## Repository Structure

```
├── README.md                   ← This file
├── TEMPLATE-README.md          ← Original Template 19 documentation
│
├── main.bicep                  ← Infrastructure orchestrator
├── main.bicepparam             ← Deployment parameters
├── main.json                   ← ARM template (compiled)
├── azuredeploy.json            ← ARM deployment template
├── azuredeploy.parameters.json ← ARM parameters
├── add-project.bicep           ← Add additional projects
├── add-project.bicepparam
├── metadata.json
│
├── createCapHost.sh            ← Create Capability Host (agent orchestration)
├── deleteCapHost.sh            ← Delete Capability Host
├── get-existing-resources.ps1  ← Discover deployed resource names via CLI
│
├── modules-network-secured/    ← Bicep modules
│   ├── ai-account-identity.bicep       ← AI Services + networkInjections
│   ├── vnet.bicep                      ← VNet with 3 subnets
│   ├── private-endpoint-and-dns.bicep  ← PEs for Search, Cosmos, Storage
│   ├── standard-dependent-resources.bicep
│   └── ...
│
├── mcp-http-server/            ← MCP server reference/config
│
├── diagrams/                   ← Architecture diagrams
│
└── tests/                      ← E2E testing & MCP deployment
    ├── README.md               ← Detailed walkthrough of what was built
    ├── TESTING-GUIDE.md        ← Step-by-step testing instructions
    ├── CLOUDSHELL-NOTEBOOK-GUIDE.md
    ├── deploy-mcp.sh           ← Automated MCP deployment (ACR, Key Vault, CAE, DNS)
    ├── teardown-mcp.sh         ← Cleanup MCP resources only
    ├── test_agents_v2.py       ← Agent SDK tests (basic agent)
    ├── test_mcp_tools_agents_v2.py  ← Agent + MCP tool tests (weather)
    ├── test_ai_search_tool_agents_v2.py
    └── test_e2e_cloudshell.ipynb    ← Interactive notebook for Cloud Shell
```

## Quick Start

### Prerequisites

- Azure CLI authenticated (`az login`)
- Owner or Contributor role on the target subscription
- Sufficient quota for `gpt-4o-mini` (or `gpt-4o`) deployment
- A [WeatherAPI](https://www.weatherapi.com/) key (free tier works)

### 1. Deploy the Infrastructure

```bash
RESOURCE_GROUP="rg-hybrid-agent-test"
LOCATION="swedencentral"

az group create --name $RESOURCE_GROUP --location $LOCATION

az deployment group create \
  --resource-group $RESOURCE_GROUP \
  --template-file main.bicep \
  --parameters location=$LOCATION
```

### 2. Deploy the Private MCP Server

```bash
cd tests
./deploy-mcp.sh --resource-group $RESOURCE_GROUP --weather-api-key <your-key>
```

This script:
- Creates an Azure Container Registry and builds the weather MCP image
- Creates a Key Vault and stores the API key
- Creates an internal-only Container Apps environment on `mcp-subnet`
- Deploys the MCP server with Key Vault secret references
- Sets up Private DNS for the Container Apps domain

### 3. Run E2E Tests

Tests must run from within the VNet (VPN Gateway, ExpressRoute, or Azure Bastion):

```bash
pip install azure-ai-projects azure-identity openai

export MCP_SERVER_PRIVATE="https://<fqdn>/mcp"
export PROJECT_ENDPOINT="https://<ai-services>.services.ai.azure.com/api/projects/<project>"

python test_mcp_tools_agents_v2.py --test all --retry 3
```

### 4. Cleanup

```bash
# MCP resources only
./teardown-mcp.sh --resource-group $RESOURCE_GROUP --yes

# Everything
az group delete --name $RESOURCE_GROUP --yes --no-wait
```

## Key Docs

| Document | Description |
|----------|-------------|
| [tests/README.md](tests/README.md) | Full walkthrough of the MCP layer built on top of Template 19 |
| [tests/TESTING-GUIDE.md](tests/TESTING-GUIDE.md) | Step-by-step SDK testing instructions |
| [tests/CLOUDSHELL-NOTEBOOK-GUIDE.md](tests/CLOUDSHELL-NOTEBOOK-GUIDE.md) | Running tests via Cloud Shell notebook |
| [TEMPLATE-README.md](TEMPLATE-README.md) | Original Template 19 documentation |

## Origin

This repo is derived from [microsoft-foundry/foundry-samples](https://github.com/microsoft-foundry/foundry-samples), specifically the `infrastructure/infrastructure-setup-bicep/19-hybrid-private-resources-agent-setup` template. The original template provides the VNet, private endpoints, AI Services account, and Data Proxy configuration. This repo adds the MCP server deployment, Key Vault integration, and end-to-end test suite, based on the github repo from Matt Felton (also at Microsoft) found at [mcp-server template](https://github.com/mattfeltonma/python-basic-as-hell-mcp-server).

## License

See the original [Foundry Samples LICENSE](https://github.com/microsoft-foundry/foundry-samples/blob/main/LICENSE).
