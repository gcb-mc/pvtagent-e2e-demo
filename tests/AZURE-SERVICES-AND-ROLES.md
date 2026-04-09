# Azure Services & RBAC Roles Reference

This document lists all Azure services required for the Foundry Agent + MCP connection,
and the RBAC role assignments needed across all identities.

---

## Table 1 — Azure Services

| # | Service | Resource Type | Created By | Purpose |
|---|---------|--------------|------------|---------|
| 1 | **AI Services Account** | `Microsoft.CognitiveServices/accounts` (kind: AIServices) | Bicep template | Hosts model deployments, projects, agents. Public access **disabled**, Data Proxy routes via `networkInjections` |
| 2 | **Model Deployment** | `Microsoft.CognitiveServices/accounts/deployments` | Bicep template | GPT-4o-mini (GlobalStandard, 30 TPM) — the LLM the agent uses |
| 3 | **AI Foundry Project** | `Microsoft.CognitiveServices/accounts/projects` | Bicep template | Agent workspace with system-assigned managed identity |
| 4 | **Capability Host** | `Microsoft.CognitiveServices/accounts/projects/capabilityHosts` | Bicep template | Binds vector store (AI Search), blob storage, and thread storage (Cosmos DB) to the project |
| 5 | **Project Connections** (×3) | `Microsoft.CognitiveServices/accounts/projects/connections` | Bicep template | Connects project to Cosmos DB, Storage, and AI Search (AAD auth) |
| 6 | **Cosmos DB** | `Microsoft.DocumentDB/databaseAccounts` | Bicep template | Thread/conversation storage for agents. Public access **disabled**, local auth disabled |
| 7 | **AI Search** | `Microsoft.Search/searchServices` | Bicep template | Vector store for agent file search. Standard SKU, public access **disabled** |
| 8 | **Storage Account** | `Microsoft.Storage/storageAccounts` | Bicep template | Blob storage for agent files/artifacts. Public access **disabled**, shared key disabled |
| 9 | **Virtual Network** | `Microsoft.Network/virtualNetworks` | Bicep template | VNet with subnets: `agent-subnet` (Data Proxy), `pe-subnet` (private endpoints), `mcp-subnet` (Container Apps), `vm-subnet` (test VM) |
| 10 | **Private Endpoints** (×4) | `Microsoft.Network/privateEndpoints` | Bicep template | Private connectivity for AI Services, AI Search, Storage (blob), Cosmos DB |
| 11 | **Private DNS Zones** (×7) | `Microsoft.Network/privateDnsZones` | Bicep template | DNS resolution for `privatelink.cognitiveservices.azure.com`, `privatelink.openai.azure.com`, `privatelink.services.ai.azure.com`, `privatelink.search.windows.net`, `privatelink.blob.core.windows.net`, `privatelink.documents.azure.com`, `privatelink.analysis.windows.net` |
| 12 | **Container Registry** | `Microsoft.ContainerRegistry/registries` | deploy-mcp.sh | ACR (Basic) — stores the MCP server Docker image |
| 13 | **Key Vault** | `Microsoft.KeyVault/vaults` | deploy-mcp.sh | Stores `WEATHER_API_KEY` secret, RBAC-enabled |
| 14 | **MCP Managed Identity** | `Microsoft.ManagedIdentity/userAssignedIdentities` | deploy-mcp.sh | User-assigned identity for MCP container (ACR pull + Key Vault access) |
| 15 | **Container Apps Environment** | `Microsoft.App/managedEnvironments` | deploy-mcp.sh | Internal-only CAE on `mcp-subnet` — no public IP |
| 16 | **MCP Container App** | `Microsoft.App/containerApps` | deploy-mcp.sh | FastMCP weather server (`/mcp`, port 8080). Secret injected from Key Vault |
| 17 | **Container Apps DNS Zone** | `Microsoft.Network/privateDnsZones` | deploy-mcp.sh | Private DNS for the CAE default domain (wildcard A record → static IP) |
| 18 | **Test VM** | `Microsoft.Compute/virtualMachines` | setup-test-vm.sh | Ubuntu 22.04 in `vm-subnet` — Python, az CLI, SDK. System-assigned managed identity |

---

## Table 2 — RBAC Role Assignments

| # | Role | Assigned To | Scope | Purpose |
|---|------|------------|-------|---------|
| 1 | **Search Index Data Contributor** | Project managed identity (system) | AI Search service | Read/write search indexes for agent vector store |
| 2 | **Search Service Contributor** | Project managed identity (system) | AI Search service | Manage search service resources |
| 3 | **Storage Blob Data Contributor** | Project managed identity (system) | Storage account | Read/write blobs for agent file storage |
| 4 | **Storage Blob Data Owner** | Project managed identity (system) | Storage account (conditional: `*-azureml-agent` containers) | Full control over agent-specific blob containers |
| 5 | **Cosmos DB Operator** | Project managed identity (system) | Cosmos DB account | Manage Cosmos DB resources (control plane) |
| 6 | **Cosmos DB Built-in Data Contributor** | Project managed identity (system) | Cosmos DB account | Read/write data in Cosmos DB (data plane) for thread storage |
| 7 | **AcrPull** | MCP identity (user-assigned) | Container Registry | Pull MCP server Docker image |
| 8 | **Key Vault Secrets Officer** | Deployer user (current signed-in user) | Key Vault | Write the Weather API key secret during deployment |
| 9 | **Key Vault Secrets User** | MCP identity (user-assigned) | Key Vault | Read the Weather API key secret at container runtime |
| 10 | **Cognitive Services User** | Test VM managed identity (system) | AI Services account | Authenticate to AI Foundry from the VM |
| 11 | **Azure AI Developer** | Test VM managed identity (system) | Resource group | Create/manage agents and run conversations |

---

## Identity Summary

| Identity | Type | Roles |
|----------|------|-------|
| **AI Foundry Project** | System-assigned managed identity | Search Index Data Contributor, Search Service Contributor, Storage Blob Data Contributor, Storage Blob Data Owner, Cosmos DB Operator, Cosmos DB Built-in Data Contributor |
| **MCP Container App** (`mcp-identity`) | User-assigned managed identity | AcrPull, Key Vault Secrets User |
| **Test VM** (`test-vm`) | System-assigned managed identity | Cognitive Services User, Azure AI Developer |
| **Deployer** (human user) | Azure AD user | Key Vault Secrets Officer (temporary, during deployment only) |
