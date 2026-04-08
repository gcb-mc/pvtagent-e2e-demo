# Running E2E Tests from Azure Cloud Shell

Step-by-step instructions for testing the Private MCP Server E2E Lab using a Jupyter notebook in Azure Cloud Shell.

---

## Prerequisites

Before starting, confirm you have:

- [ ] Template 19 deployed to a resource group (e.g., `rg-hybrid-agent-test`)
- [ ] MCP server deployed via `deploy-mcp.sh` (see [TESTING-GUIDE.md](TESTING-GUIDE.md) Step 4)
- [ ] Test data in AI Search index (see [TESTING-GUIDE.md](TESTING-GUIDE.md) Step 3)
- [ ] Owner or Contributor role on the Azure subscription
- [ ] A WeatherAPI.com key stored in Key Vault (done by `deploy-mcp.sh`)

---

## Step 1: Open Azure Cloud Shell

1. Go to [https://shell.azure.com](https://shell.azure.com) or click the Cloud Shell icon in the Azure Portal toolbar
2. Select **Bash** as the shell type
3. If prompted, create a storage account for Cloud Shell

---

## Step 2: Upload the Notebook

### Option A: Upload directly

1. In Cloud Shell, click the **Upload/Download** button (up-arrow icon in the toolbar)
2. Upload `test_e2e_cloudshell.ipynb` from the `tests/` directory
3. It lands in your home directory (`~/`)

### Option B: Clone the repository

```bash
cd ~/clouddrive
git clone <your-repo-url> secure-agents-lab
cd secure-agents-lab/foundry-samples/infrastructure/infrastructure-setup-bicep/19-hybrid-private-resources-agent-setup/tests/
```

---

## Step 3: Open Jupyter in Cloud Shell

Azure Cloud Shell ships with Jupyter pre-installed. Start it:

```bash
jupyter notebook --no-browser --port=8888
```

Cloud Shell will display a URL with a token. Click **Web Preview** (the globe icon in the Cloud Shell toolbar) and set the port to **8888**. This opens the Jupyter UI in your browser.

Navigate to the `test_e2e_cloudshell.ipynb` notebook and open it.

> **Alternative:** If you prefer JupyterLab:
> ```bash
> jupyter lab --no-browser --port=8888
> ```

---

## Step 4: Configure the Notebook

In the first code cell (**Cell 2 — Configuration**), review and update:

| Variable | Default | What to Change |
|----------|---------|----------------|
| `RESOURCE_GROUP` | `rg-hybrid-agent-test` | Your resource group name |
| `CONNECTIVITY_MODE` | `"public"` | `"public"` (standard Cloud Shell) or `"vnet"` (Cloud Shell with VNet integration) |
| `MODEL_NAME` | `gpt-4o-mini` | Your deployed model name |
| `AI_SEARCH_INDEX_NAME` | `test-index` | Your search index name |
| `MAX_RETRIES` | `3` | Retry count for MCP agent test |

---

## Step 5: Run All Cells Sequentially

Execute cells in order. Here's what each does:

| Cell | Name | What Happens |
|------|------|-------------|
| 2 | Configuration | Sets variables and validates them |
| 3 | Resource Discovery | Auto-discovers all Azure resource names and endpoints via `az` CLI. **If any value is empty, it prints exactly what failed and stops.** |
| 4 | Switch to Public Access | *(public mode only)* Enables public network access on AI Services. Skipped in vnet mode. |
| 5 | Install Dependencies | Installs `azure-ai-projects`, `azure-identity`, `openai` |
| 6 | Initialize SDK Clients | Creates credential + project client + OpenAI client |
| 7 | **Test 1**: OpenAI Responses API | Direct API call — validates basic connectivity |
| 8 | **Test 2**: Basic Agent | Creates agent, sends prompt, validates response |
| 9 | **Test 3**: MCP Tool via Agent | Agent calls private MCP server through Data Proxy. Retries automatically for Hyena routing issue. |
| 10 | **Test 4**: AI Search Tool via Agent | Agent queries private AI Search through Data Proxy |
| 11 | **Test 5**: Direct MCP Connectivity | *(vnet mode only)* Raw HTTP to MCP server. Skipped in public mode. |
| 12 | Test Summary | Prints pass/fail table |
| 13 | Revert to Private Access | *(public mode only)* Restores private network access. **Always run this when done.** |

---

## Step 6: Review Results

After running all cells, the **Test Summary** cell prints:

```
============================================================
TEST SUMMARY
============================================================
  1_responses_api: ✓ PASSED
  2_basic_agent:   ✓ PASSED
  3_mcp_tool:      ✓ PASSED
  4_ai_search:     ✓ PASSED
  5_mcp_direct:    ⏭ SKIPPED    (public mode)

  4/4 tests passed
============================================================
ALL TESTS PASSED
============================================================
```

---

## Step 7: Revert to Private Access

**Do not skip this step if you used `public` connectivity mode.**

Run the last cell (**Cleanup — Revert to Private Access**). It:
1. Sets `publicNetworkAccess: Disabled` on AI Services
2. Sets `networkAcls.defaultAction: Deny`
3. Verifies the change
4. Closes SDK clients

If the cell fails, revert manually:

```bash
az cognitiveservices account update \
  -g rg-hybrid-agent-test \
  -n <AI_SERVICES_NAME> \
  --api-properties publicNetworkAccess=Disabled
```

---

## Troubleshooting

### Resource Discovery fails with empty value

The notebook validates every `az` CLI result. If a value is empty, it prints:
- **What failed** (e.g., "AI Services account name")
- **The az command** that returned empty
- **Stderr output** from the command
- **A hint** (e.g., "Is Template 19 deployed?")

Common fixes:
- Verify the resource group name is correct
- Confirm Template 19 was deployed: `az cognitiveservices account list -g <rg>`
- Confirm MCP server was deployed: `az containerapp list -g <rg> -o table`

### Test 1 fails (Responses API)

- In **public mode**: Check that the "Switch to Public Access" cell succeeded
- In **vnet mode**: Verify Cloud Shell VNet integration is configured and the AI Services private endpoint is reachable

### Test 3 fails (MCP Tool via Agent)

This test has built-in retries (`MAX_RETRIES=3`). If all retries fail:

| Error | Cause | Fix |
|-------|-------|-----|
| `TaskCanceledException` | Hyena cluster routing — Data Proxy on 1 of 2 scale units | Re-run the cell. ~50% success rate per attempt. |
| `424 Failed Dependency` | DNS resolution — Data Proxy can't resolve Container Apps DNS | Verify private DNS zone exists: `az network private-dns zone list -g <rg>` |
| `400 Bad Request` | Wrong MCP URL | Check the MCP_SERVER_URL printed in the Resource Discovery cell |

### Test 4 fails (AI Search)

- Verify the search index exists and has documents
- Check the connection name matches: go to Azure Portal → AI Foundry → Project → Connections
- Verify private endpoint is healthy: `az network private-endpoint list -g <rg> --query "[?contains(name,'search')]"`

### Jupyter won't start in Cloud Shell

```bash
# Install if missing
pip install jupyter notebook

# Try with explicit IP binding
jupyter notebook --no-browser --port=8888 --ip=0.0.0.0
```

### Cloud Shell times out

Cloud Shell has a 20-minute idle timeout. If it disconnects mid-test:
1. Reconnect to Cloud Shell
2. Restart Jupyter
3. Re-run all cells from the top (the notebook is stateless — each section rediscovers resources)

---

## Files Reference

| File | Purpose |
|------|---------|
| `test_e2e_cloudshell.ipynb` | **This notebook** — Cloud Shell E2E testing |
| `deploy-mcp.sh` | Deploy MCP server (run before notebook) |
| `teardown-mcp.sh` | Remove MCP resources (run after notebook) |
| `test_agents_v2.py` | CLI test script — same tests as notebook |
| `test_mcp_tools_agents_v2.py` | CLI test script — MCP-focused with retries |
| `TESTING-GUIDE.md` | Full setup guide (prerequisites, deployment, testing) |
| `README.md` | Architecture documentation |
