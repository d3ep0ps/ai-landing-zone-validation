"""v2 agent G (T30, T31b, T32): probe agent bound to an Agent Gateway (egress). Two fixed tools.
No tool accepts a URL: the caller picks a key from a fixed list. Every failure is returned as evidence."""

import json
import os

import google.auth
import google.auth.transport.requests
import requests
from google.adk.agents import Agent
from google.oauth2 import id_token
from vertexai.agent_engines import AdkApp

os.environ.setdefault("GOOGLE_GENAI_USE_VERTEXAI", "True")
os.environ["GOOGLE_CLOUD_LOCATION"] = os.environ.get("LZV_MODEL_LOCATION", "global")

SERVERS = {  # key -> (env var with the Cloud Run URL, tools allowed on it)
    "registered": ("MCP_REG_URL", {"registered_echo", "inject_response"}),
    "unregistered": ("MCP_UNREG_URL", {"unregistered_echo"}),
}
PROJECT = os.environ.get("LZV_PROJECT_ID", "")
MODEL = os.environ.get("LZV_MODEL", "")
# T31b: the gateway registry allows exactly the global Vertex host. The regional host is the
# endpoint the gateway is not told about (default deny).
MODEL_HOSTS = {
    "allowed": ("https://aiplatform.googleapis.com", "global"),
    "blocked": ("https://europe-west1-aiplatform.googleapis.com", "europe-west1"),
}


def _creds():
    creds, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
    creds.refresh(google.auth.transport.requests.Request())
    return creds


def call_mcp_tool(server: str, tool: str) -> dict:
    """Call one fixed MCP tool (tools/call, no arguments) on one fixed MCP server.

    Args:
        server: "registered" (tools registered_echo, inject_response) or "unregistered" (tool unregistered_echo).
        tool: tool name; must belong to the server above.

    Returns:
        dict with server, tool, status (int or None), body (first 600 chars), auth, error.
    """
    env, tools = SERVERS.get(server, (None, set()))
    base = os.environ.get(env, "") if env else ""
    if not base or tool not in tools:
        return {"server": server, "tool": tool, "status": None, "body": None, "auth": None,
                "error": "bad server/tool combination or URL not configured"}
    auth = "id_token"
    try:
        try:
            token = id_token.fetch_id_token(google.auth.transport.requests.Request(), base)
        except Exception:  # noqa: BLE001 - Agent Identity may have no ID token; record the fallback
            token, auth = _creds().token, "access_token_fallback"
        resp = requests.post(
            base + "/mcp", timeout=30,
            headers={"authorization": f"Bearer {token}", "content-type": "application/json"},
            data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                             "params": {"name": tool, "arguments": {}}}))
        return {"server": server, "tool": tool, "status": resp.status_code, "body": resp.text[:600],
                "auth": auth, "error": None}
    except Exception as exc:  # noqa: BLE001 - connection terminated (T32) lands here
        return {"server": server, "tool": tool, "status": None, "body": None, "auth": auth,
                "error": f"{exc.__class__.__name__}: {exc}"}


def call_model(endpoint: str) -> dict:
    """Call generateContent directly (REST, fixed prompt) on one fixed Vertex AI host.

    Args:
        endpoint: "allowed" (aiplatform.googleapis.com, global) or "blocked" (europe-west1-aiplatform.googleapis.com).

    Returns:
        dict with endpoint, status (int or None), body (first 600 chars), error.
    """
    host = MODEL_HOSTS.get(endpoint)
    if host is None:
        return {"endpoint": endpoint, "status": None, "body": None, "error": "use allowed or blocked"}
    base, loc = host
    url = (f"{base}/v1/projects/{PROJECT}/locations/{loc}/publishers/google/models/{MODEL}:generateContent")
    try:
        resp = requests.post(
            url, timeout=30,
            headers={"authorization": f"Bearer {_creds().token}", "content-type": "application/json"},
            data=json.dumps({"contents": [{"role": "user", "parts": [{"text": "Reply with the single word: ok"}]}]}))
        return {"endpoint": endpoint, "status": resp.status_code, "body": resp.text[:600], "error": None}
    except Exception as exc:  # noqa: BLE001
        return {"endpoint": endpoint, "status": None, "body": None, "error": f"{exc.__class__.__name__}: {exc}"}


root_agent = Agent(
    name="lzv_probe_g",
    model=os.environ["LZV_MODEL"],
    instruction=(
        "The user names either an MCP call (server and tool) or a model call (allowed or blocked). "
        "Call exactly one tool exactly once with exactly those arguments (call_mcp_tool or call_model), "
        "then reply with the tool result as JSON. Never answer without calling the tool."
    ),
    tools=[call_mcp_tool, call_model],
)

app = AdkApp(agent=root_agent)
