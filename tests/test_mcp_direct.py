#!/usr/bin/env python3
"""
test_mcp_direct.py — Direct MCP HTTP Connectivity Test (VNet Mode)

Tests direct HTTP connectivity to the MCP server endpoint from inside
the VNet, bypassing the AI agent layer. Validates that:
  1. The MCP JSON-RPC initialize handshake works
  2. tools/list returns available tools
  3. tools/call successfully invokes a tool

Requirements:
  - Run from a VM inside the VNet (e.g. created by setup-test-vm.sh)
  - MCP server must be deployed (deploy-mcp.sh)
  - No Azure credentials required (direct HTTP to container app)

Usage:
  python3 test_mcp_direct.py --mcp-url <url>

  # Or set via environment variable:
  export MCP_SERVER_URL=https://mcp-http-server.<env-id>.<region>.azurecontainerapps.io
  python3 test_mcp_direct.py
"""

import argparse
import json
import logging
import os
import ssl
import sys
import urllib.request

logger = logging.getLogger(__name__)


def mcp_post(url: str, payload: dict, timeout: int = 30) -> dict:
    """
    Send a JSON-RPC request to the MCP endpoint.

    Handles two response formats:
      - SSE (text/event-stream): parses 'data:' lines for JSON
      - Plain JSON: parses body directly
    """
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        },
    )
    ctx = ssl.create_default_context()

    with urllib.request.urlopen(req, context=ctx, timeout=timeout) as resp:
        content_type = resp.headers.get("Content-Type", "")
        body = resp.read().decode("utf-8")

        if "text/event-stream" in content_type:
            # SSE: extract last 'data:' line containing JSON
            for line in reversed(body.strip().split("\n")):
                line = line.strip()
                if line.startswith("data:"):
                    json_str = line[len("data:"):].strip()
                    if json_str:
                        return json.loads(json_str)
            raise ValueError(f"No data: line found in SSE response:\n{body[:500]}")
        else:
            return json.loads(body)


def run_test(mcp_url: str) -> bool:
    """Run the 3-step MCP connectivity test. Returns True on success."""
    results = {"initialize": False, "tools_list": False, "tools_call": False}

    # --- Step 1: Initialize ---
    logger.info("Step 1/3: JSON-RPC initialize...")
    try:
        init_resp = mcp_post(mcp_url, {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "mcp-direct-test", "version": "1.0.0"},
            },
        })
        server_name = init_resp.get("result", {}).get("serverInfo", {}).get("name", "unknown")
        logger.info(f"  ✓ Server: {server_name}")
        results["initialize"] = True

        # Send notifications/initialized
        mcp_post(mcp_url, {
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
        })
    except Exception as e:
        logger.error(f"  ✗ Initialize failed: {e}")
        return False

    # --- Step 2: List tools ---
    logger.info("Step 2/3: tools/list...")
    try:
        tools_resp = mcp_post(mcp_url, {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
            "params": {},
        })
        tools = tools_resp.get("result", {}).get("tools", [])
        tool_names = [t.get("name", "?") for t in tools]
        logger.info(f"  ✓ Found {len(tools)} tool(s): {', '.join(tool_names)}")
        results["tools_list"] = True
    except Exception as e:
        logger.error(f"  ✗ tools/list failed: {e}")
        return False

    # --- Step 3: Call a tool ---
    tool_to_call = tool_names[0] if tool_names else "get_weather"
    logger.info(f"Step 3/3: tools/call '{tool_to_call}'...")
    try:
        # Use a sample argument — works for the default weather tool
        call_resp = mcp_post(mcp_url, {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": {
                "name": tool_to_call,
                "arguments": {"city": "London"},
            },
        })
        content = call_resp.get("result", {}).get("content", [])
        if content:
            text = content[0].get("text", str(content[0]))
            logger.info(f"  ✓ Response: {text[:200]}")
        else:
            logger.info(f"  ✓ Call succeeded (empty content)")
        results["tools_call"] = True
    except Exception as e:
        logger.error(f"  ✗ tools/call failed: {e}")
        return False

    # --- Summary ---
    passed = all(results.values())
    logger.info("")
    logger.info("=" * 50)
    for step, ok in results.items():
        logger.info(f"  {'✓' if ok else '✗'} {step}")
    logger.info("=" * 50)
    logger.info(f"RESULT: {'PASS' if passed else 'FAIL'}")
    return passed


def main():
    parser = argparse.ArgumentParser(description="Direct MCP HTTP connectivity test")
    parser.add_argument(
        "--mcp-url",
        default=os.environ.get("MCP_SERVER_URL", ""),
        help="Full URL to the MCP endpoint (e.g. https://mcp-http-server.<id>.<region>.azurecontainerapps.io/mcp). "
             "Can also be set via MCP_SERVER_URL environment variable.",
    )
    parser.add_argument(
        "--verbose", "-v",
        action="store_true",
        help="Enable debug logging",
    )
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(message)s",
    )

    mcp_url = args.mcp_url.rstrip("/")
    if not mcp_url:
        logger.error("ERROR: --mcp-url or MCP_SERVER_URL environment variable is required")
        sys.exit(1)

    # Ensure URL ends with /mcp
    if not mcp_url.endswith("/mcp"):
        mcp_url = mcp_url.rstrip("/") + "/mcp"

    logger.info(f"MCP endpoint: {mcp_url}")
    logger.info("")

    success = run_test(mcp_url)
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
