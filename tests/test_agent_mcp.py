#!/usr/bin/env python3
"""
test_agent_mcp.py — Agent + MCP Tool Test via Managed Identity

Tests the full end-to-end agent chain from inside the VNet:
  VM → Managed Identity auth → AI Foundry Data Proxy → Agent → MCP Tool

This validates:
  1. Managed identity authentication works from the VM
  2. Agent creation with MCP tool succeeds
  3. Agent can invoke the MCP tool and return results
  4. Full private network path (Data Proxy → VNet → MCP container)

Requirements:
  - Run from a VM with system-assigned managed identity
  - VM identity must have: Cognitive Services User + Azure AI Developer roles
  - MCP server deployed (deploy-mcp.sh)
  - Python packages: azure-ai-projects, azure-identity, openai

Usage:
  # Single query mode (default):
  python3 test_agent_mcp.py --project-endpoint <endpoint> --mcp-url <url>

  # Interactive chat mode:
  python3 test_agent_mcp.py --project-endpoint <endpoint> --mcp-url <url> --interactive

  # Via environment variables:
  export PROJECT_ENDPOINT=https://<ai-services>.cognitiveservices.azure.com/api/projects/<project>
  export MCP_SERVER_URL=https://mcp-http-server.<env-id>.<region>.azurecontainerapps.io
  python3 test_agent_mcp.py
"""

import argparse
import json
import logging
import os
import sys

logger = logging.getLogger(__name__)


def create_agent_client(project_endpoint: str):
    """Create an AIProjectClient with managed identity auth."""
    from azure.ai.projects import AIProjectClient
    from azure.identity import ManagedIdentityCredential

    credential = ManagedIdentityCredential()
    client = AIProjectClient(
        endpoint=project_endpoint,
        credential=credential,
    )
    return client, credential


def run_single_query(project_endpoint: str, mcp_url: str, model: str, query: str) -> bool:
    """Run a single agent query with the MCP tool. Returns True on success."""
    from azure.ai.projects.models import MCPTool, PromptAgentDefinition

    logger.info("Creating AI Project client (managed identity)...")
    client, _ = create_agent_client(project_endpoint)

    # Ensure MCP URL ends with /mcp
    if not mcp_url.endswith("/mcp"):
        mcp_url = mcp_url.rstrip("/") + "/mcp"

    logger.info(f"Creating agent with MCP tool...")
    logger.info(f"  Model: {model}")
    logger.info(f"  MCP:   {mcp_url}")

    mcp_tool = MCPTool(
        server_label="mcp-weather",
        server_url=mcp_url,
        require_approval="never",
    )

    with client:
        openai_client = client.get_openai_client()
        with openai_client:
            agent = client.agents.create_version(
                agent_name="mcp-vm-test-agent",
                definition=PromptAgentDefinition(
                    model=model,
                    instructions="You are a helpful assistant. Use the MCP tools to answer questions.",
                    tools=[mcp_tool],
                ),
            )
            logger.info(f"  Agent ID: {agent.id}")

            # Create a conversation
            conversation = openai_client.conversations.create()
            logger.info(f"Running query: '{query}'")

            # Send request
            response = openai_client.responses.create(
                conversation=conversation.id,
                input=query,
                extra_body={"agent_reference": {"name": agent.name, "type": "agent_reference"}},
            )

            # Handle MCP approval if needed
            for item in response.output:
                if hasattr(item, 'type') and item.type == "mcp_approval_request":
                    from openai.types.responses import ResponseInputParam
                    from openai.types.responses.response_input_param import McpApprovalResponse
                    input_list = [
                        McpApprovalResponse(
                            type="mcp_approval_response",
                            approve=True,
                            approval_request_id=item.id,
                        )
                    ]
                    response = openai_client.responses.create(
                        input=input_list,
                        previous_response_id=response.id,
                        extra_body={"agent_reference": {"name": agent.name, "type": "agent_reference"}},
                    )

            output_text = response.output_text
            if output_text:
                logger.info(f"  ✓ Response: {output_text[:300]}")
                return True
            else:
                logger.error("  ✗ No output text in response")
                return False


def run_interactive(project_endpoint: str, mcp_url: str, model: str):
    """Run an interactive chat session with the agent."""
    from azure.ai.projects.models import MCPTool

    logger.info("Creating AI Project client (managed identity)...")
    client, _ = create_agent_client(project_endpoint)

    if not mcp_url.endswith("/mcp"):
        mcp_url = mcp_url.rstrip("/") + "/mcp"

    mcp_tool = MCPTool(
        server_label="mcp-weather",
        server_url=mcp_url,
        require_approval="never",
    )

    agent = client.agents.create_agent(
        model=model,
        name="mcp-vm-chat-agent",
        instructions="You are a helpful assistant. Use the MCP tools to answer questions about weather.",
        tools=mcp_tool.definitions,
        headers={"x-ms-enable-preview": "true"},
    )
    logger.info(f"Agent created: {agent.id}")

    thread = client.agents.threads.create()
    print("\nInteractive mode — type 'quit' to exit\n")

    try:
        while True:
            try:
                user_input = input("You: ").strip()
            except (EOFError, KeyboardInterrupt):
                break
            if not user_input or user_input.lower() in ("quit", "exit", "q"):
                break

            client.agents.messages.create(
                thread_id=thread.id, role="user", content=user_input,
            )
            run = client.agents.runs.create_and_process(
                thread_id=thread.id,
                agent_id=agent.id,
                tool_resources=mcp_tool.resources,
            )

            if run.status == "completed":
                messages = client.agents.messages.list(thread_id=thread.id)
                for msg in messages.data:
                    if msg.role == "assistant":
                        for block in msg.content:
                            if hasattr(block, "text"):
                                print(f"\nAgent: {block.text.value}\n")
                        break
            else:
                print(f"\n[Run failed: {run.status}]\n")
    finally:
        client.agents.delete_agent(agent.id)
        logger.info("Agent cleaned up")


def main():
    parser = argparse.ArgumentParser(description="Agent + MCP tool test via managed identity")
    parser.add_argument(
        "--project-endpoint",
        default=os.environ.get("PROJECT_ENDPOINT", ""),
        help="AI Foundry project endpoint. Can also set via PROJECT_ENDPOINT env var.",
    )
    parser.add_argument(
        "--mcp-url",
        default=os.environ.get("MCP_SERVER_URL", ""),
        help="MCP server URL. Can also set via MCP_SERVER_URL env var.",
    )
    parser.add_argument(
        "--model",
        default=os.environ.get("MODEL_NAME", "gpt-4o"),
        help="Model deployment name (default: gpt-4o)",
    )
    parser.add_argument(
        "--query",
        default="What is the weather in Tokyo?",
        help="Query to send in single-query mode (default: 'What is the weather in Tokyo?')",
    )
    parser.add_argument(
        "--interactive", "-i",
        action="store_true",
        help="Run in interactive chat mode",
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

    if not args.project_endpoint:
        logger.error("ERROR: --project-endpoint or PROJECT_ENDPOINT env var is required")
        sys.exit(1)
    if not args.mcp_url:
        logger.error("ERROR: --mcp-url or MCP_SERVER_URL env var is required")
        sys.exit(1)

    logger.info(f"Project: {args.project_endpoint}")
    logger.info(f"MCP:     {args.mcp_url}")
    logger.info(f"Model:   {args.model}")
    logger.info("")

    if args.interactive:
        run_interactive(args.project_endpoint, args.mcp_url, args.model)
    else:
        success = run_single_query(args.project_endpoint, args.mcp_url, args.model, args.query)
        logger.info("")
        logger.info("=" * 50)
        logger.info(f"RESULT: {'PASS' if success else 'FAIL'}")
        logger.info("=" * 50)
        sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
