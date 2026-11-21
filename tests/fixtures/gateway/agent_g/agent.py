"""v2 agent G (T30, T31b, T32; v3h T47, T49, T53): probe agent bound to an Agent Gateway (egress). Four fixed tools.
No tool accepts a URL: the caller picks a key from a fixed list. Every failure is returned as evidence."""

import hashlib
import json
import os
import re
import socket
import ssl
import threading
from datetime import timezone

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
    # T31R v2 (run 10): an unregistered host that serves the global model (EU multi-region REP host,
    # locations/global; read-only check 2026-11-21: countTokens and generateContent 200 from the operator).
    "blocked_global": ("https://aiplatform.eu.rep.googleapis.com", "global"),
}


def _creds():
    creds, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
    creds.refresh(google.auth.transport.requests.Request())
    return creds


def _cnf_present(token: str):
    """True if the JWT payload has a cnf (binding) claim. Unverified decode; no token material leaves."""
    try:
        import base64
        part = token.split(".")[1]
        return "cnf" in json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)))
    except Exception:  # noqa: BLE001
        return None


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
    # T53 v3 (plan 3b): unbound ID token for this call only. The default is certificate-bound, Cloud Run enforces
    # the cnf binding, and the gateway re-originates TLS, so a bound token gets 401 (gw 1).
    auth, cnf = "id_token_unbound", None
    try:
        try:
            token = id_token.fetch_id_token(google.auth.transport.requests.Request(), base, bind_id_token=False)
            cnf = _cnf_present(token)
        except Exception:  # noqa: BLE001 - Agent Identity may have no ID token; record the fallback
            token, auth = _creds().token, "access_token_fallback"
        resp = requests.post(
            base + "/mcp", timeout=30,
            headers={"authorization": f"Bearer {token}", "content-type": "application/json"},
            data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                             "params": {"name": tool, "arguments": {}}}))
        return {"server": server, "tool": tool, "status": resp.status_code, "body": resp.text[:600],
                "auth": auth, "cnf_present": cnf, "error": None}
    except Exception as exc:  # noqa: BLE001 - connection terminated (T32) lands here
        return {"server": server, "tool": tool, "status": None, "body": None, "auth": auth,
                "cnf_present": cnf, "error": f"{exc.__class__.__name__}: {exc}"}


def call_model(endpoint: str) -> dict:
    """Call generateContent directly (REST, fixed prompt) on one fixed Vertex AI host.

    Args:
        endpoint: "allowed" (aiplatform.googleapis.com, global), "blocked" (europe-west1-aiplatform.googleapis.com)
            or "blocked_global" (aiplatform.eu.rep.googleapis.com, global).

    Returns:
        dict with endpoint, status (int or None), body (first 600 chars), error.
    """
    host = MODEL_HOSTS.get(endpoint)
    if host is None:
        return {"endpoint": endpoint, "status": None, "body": None, "error": "use allowed, blocked or blocked_global"}
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


def _short(text) -> str:
    return re.sub(r"(ya29\.[\w.\-]+|eyJ[\w.\-]{20,})", "[redacted]", str(text or "")).replace("\n", " ")[:300]


def _binding_state() -> dict:
    """What google-auth decides about token binding in this runtime (private helpers; any failure is recorded)."""
    out = {"env_runtime_bound": os.environ.get("GOOGLE_API_ENABLE_RUNTIME_BOUND_TOKEN"),
           "env_prevent_sharing": os.environ.get("GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES")}
    try:
        import google.auth.version as gav
        out["google_auth"] = gav.__version__
    except Exception as exc:  # noqa: BLE001
        out["google_auth"] = f"unknown: {exc.__class__.__name__}"
    try:
        from google.auth import _agent_identity_utils as aiu
        cert = aiu.get_agent_identity_certificate_and_bytes()
        out["agent_cert_present"] = bool(cert and cert[0] is not None)
        fn = getattr(aiu, "should_request_bound_token", None)
        if not out["agent_cert_present"]:
            out["should_request_bound_token"] = False  # no agent certificate: the library requests an unbound token
        elif fn is not None:
            out["should_request_bound_token"] = bool(fn(cert[0]))
    except Exception as exc:  # noqa: BLE001
        out["binding_probe_error"] = _short(f"{exc.__class__.__name__}: {exc}")
    return out


def replay_check(mode: str) -> dict:
    """T49: one model call through the gateway with the agent's own token, then send that token to the replay service.

    Args:
        mode: must be "gateway".

    Returns:
        dict with statuses, token SHA-256 prefix and expiry, binding state and the replay result. Never the token.
    """
    if mode != "gateway":
        return {"status": None, "error": "use mode gateway"}
    url = os.environ.get("LZV_REPLAY_URL", "")
    out: dict = {"mode": mode, "status": None, "error": ""}
    out.update(_binding_state())
    try:
        creds = _creds()
        token = creds.token
        out["token_sha12"] = hashlib.sha256(token.encode()).hexdigest()[:12]
        out["token_expiry"] = creds.expiry.replace(tzinfo=timezone.utc).isoformat() if creds.expiry else None
        path = f"/v1/projects/{PROJECT}/locations/global/publishers/google/models/{MODEL}:generateContent"
        body = {"contents": [{"role": "user", "parts": [{"text": "Reply with the single word: ok"}]}]}
        # s1: same call as call_model("allowed"): regular host, no client certificate, egress through the gateway.
        own = requests.post(f"https://aiplatform.googleapis.com{path}", timeout=30,
                            headers={"authorization": f"Bearer {token}"}, json=body)
        out["own_gw_status"] = own.status_code
        if own.status_code != 200:
            out["own_gw_error"] = _short(own.text)
        # Observation: the mTLS host with the agent's client certificate (also through the gateway).
        try:
            sess = google.auth.transport.requests.AuthorizedSession(creds)
            sess.configure_mtls_channel()
            m = sess.post(f"https://aiplatform.mtls.googleapis.com{path}", timeout=30, json=body)
            out["own_mtls_status"], out["own_mtls"] = m.status_code, sess.is_mtls
            out["own_mtls_token_same"] = creds.token == token
        except Exception as exc:  # noqa: BLE001
            out["own_mtls_error"] = _short(f"{exc.__class__.__name__}: {exc}")
        if not url:
            out["error"] = "LZV_REPLAY_URL not set"
            return out
        # s2: the replay service (other project, invoker IAM off, no agent certificate) replays the same token.
        resp = requests.post(url.rstrip("/") + "/replay", timeout=60,
                             json={"token": token, "project": PROJECT, "model": MODEL, "location": "global"})
        out["replay_http_status"] = resp.status_code
        try:
            rj = resp.json()
        except ValueError:
            rj = {"raw": _short(resp.text)}
        rj.pop("token", None)
        out["replay"] = {k: (_short(v) if isinstance(v, str) else v) for k, v in rj.items()}
        out["status"] = rj.get("status") if isinstance(rj, dict) else None
    except Exception as exc:  # noqa: BLE001 - a gateway refusal of the replay host lands here
        out["error"] = _short(f"{exc.__class__.__name__}: {exc}")
    return out


def _deadline(fn, seconds: float = 20.0) -> dict:
    box: dict = {}
    t = threading.Thread(target=lambda: box.update(fn()), daemon=True)
    t.start()
    t.join(seconds)
    return box if not t.is_alive() else {"status": None, "error": f"no answer within {seconds:.0f} s"}


def _probe_unreg() -> dict:
    base = os.environ.get("MCP_UNREG_URL", "")
    try:
        r = requests.post(base + "/mcp", timeout=15, proxies={"http": None, "https": None},
                          json={"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
        return {"status": r.status_code, "body": _short(r.text)[:200], "error": None}
    except Exception as exc:  # noqa: BLE001
        return {"status": None, "error": _short(f"{exc.__class__.__name__}: {exc}")}


def _probe_ip() -> dict:
    out: dict = {"stage": "dns"}
    try:
        ip = socket.getaddrinfo("example.com", 443, socket.AF_INET, socket.SOCK_STREAM)[0][4][0]
        out.update(ip=ip, stage="connect")
        with socket.create_connection((ip, 443), timeout=10) as raw:
            out["stage"] = "tls"
            ctx = ssl.create_default_context()
            with ctx.wrap_socket(raw, server_hostname="example.com") as tls:
                out["peer_cn"] = dict(x[0] for x in tls.getpeercert().get("subject", ())).get("commonName")
                tls.sendall(b"HEAD / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n")
                out["first_line"] = tls.recv(64).split(b"\r\n")[0].decode(errors="replace")
                out["stage"] = "http"
        out["status"] = int(out["first_line"].split()[1]) if out.get("first_line", "").startswith("HTTP/") else None
        out["error"] = None
    except Exception as exc:  # noqa: BLE001
        out.update(status=None, error=_short(f"{exc.__class__.__name__}: {exc}"))
    return out


def _probe_storage() -> dict:
    try:
        r = requests.get(f"https://storage.googleapis.com/storage/v1/b?project={PROJECT}&maxResults=1", timeout=15,
                         proxies={"http": None, "https": None}, headers={"authorization": f"Bearer {_creds().token}"})
        return {"status": r.status_code, "body": _short(r.text)[:200], "error": None}
    except Exception as exc:  # noqa: BLE001
        return {"status": None, "error": _short(f"{exc.__class__.__name__}: {exc}")}


def direct_probe(target: str) -> dict:
    """T53: try to reach a destination without going through the gateway on purpose (no proxy settings), 20 s deadline.

    Args:
        target: "unregistered_mcp" (the unregistered MCP fixture), "example_ip" (raw TLS to example.com's IP) or
            "storage_api" (storage.googleapis.com bucket list).

    Returns:
        dict with target, status, stage reached and error.
    """
    fns = {"unregistered_mcp": _probe_unreg, "example_ip": _probe_ip, "storage_api": _probe_storage}
    if target not in fns:
        return {"target": target, "status": None, "error": "use unregistered_mcp, example_ip or storage_api"}
    out = _deadline(fns[target])
    out["target"] = target
    return out


def _versions() -> dict:
    from importlib import metadata

    out = {}
    for pkg in ("google-auth", "google-cloud-aiplatform", "google-adk", "requests"):
        try:
            out[pkg] = metadata.version(pkg)
        except Exception:  # noqa: BLE001
            out[pkg] = None
    return out


# T47r / T47 / T49 (plan 3b): resolved package versions, printed once at import (stdout reaches Cloud Logging);
# no model call needed, so it is recorded even when the agent's own model call fails.
print(json.dumps({"lzv_versions": _versions()}), flush=True)


root_agent = Agent(
    name="lzv_probe_g",
    model=os.environ["LZV_MODEL"],
    instruction=(
        "The user names either an MCP call (server and tool), a model call (allowed, blocked or blocked_global), a replay check or a "
        "direct probe. Call exactly one tool exactly once with exactly those arguments (call_mcp_tool, call_model, "
        "replay_check or direct_probe), "
        "then reply with the tool result as JSON. Never answer without calling the tool."
    ),
    tools=[call_mcp_tool, call_model, replay_check, direct_probe],
)

app = AdkApp(agent=root_agent)
