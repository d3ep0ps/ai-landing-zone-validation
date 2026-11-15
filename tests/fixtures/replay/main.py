"""T48 replay service: receives a bearer token and replays it against the same Vertex AI generateContent
REST endpoint and fixed payload the agent used. Never logs or returns the token.
T48b (plan 3b, 2026-11-12): single-use relay so a sibling agent can present another agent's token over its own mTLS
session. Memory only, one entry per nonce, 120 s TTL, deleted on first read, at most 4 entries, never logged."""

import hashlib
import os
import re
import threading
import time

import requests
from flask import Flask, jsonify, request

app = Flask(__name__)
PROMPT = "Reply with the single word: ok"  # same fixed payload as tests/fixtures/agent_v3
LOC_RE = re.compile(r"^[a-z0-9-]{1,30}$")
PROJ_RE = re.compile(r"^[a-z][a-z0-9-]{4,60}$")
MODEL_RE = re.compile(r"^[A-Za-z0-9._-]{1,80}$")


def _short(text) -> str:
    return re.sub(r"(ya29\.[\w.\-]+|eyJ[\w.\-]{20,})", "[redacted]", str(text or "")).replace("\n", " ")[:300]


@app.post("/replay")
def replay():
    body = request.get_json(silent=True) or {}
    token = body.get("token")
    if not token or not isinstance(token, str):
        return jsonify({"status": None, "error_status": "NO_TOKEN", "error_message": "token absent",
                        "token_sha12": None}), 400
    project = body.get("project") or os.environ.get("LZV_PROJECT_ID", "")
    model = body.get("model") or os.environ.get("LZV_MODEL", "")
    loc = body.get("location") or os.environ.get("LZV_MODEL_LOCATION", "global")
    if not (PROJ_RE.match(project) and MODEL_RE.match(model) and LOC_RE.match(loc)):
        return jsonify({"status": None, "error_status": "BAD_TARGET", "error_message": "invalid project/model/location",
                        "token_sha12": hashlib.sha256(token.encode()).hexdigest()[:12]}), 400
    sha12 = hashlib.sha256(token.encode()).hexdigest()[:12]
    host = "aiplatform.googleapis.com" if loc == "global" else f"{loc}-aiplatform.googleapis.com"
    url = f"https://{host}/v1/projects/{project}/locations/{loc}/publishers/google/models/{model}:generateContent"
    try:
        resp = requests.post(url, timeout=30, headers={"authorization": f"Bearer {token}"},
                             json={"contents": [{"role": "user", "parts": [{"text": PROMPT}]}]})
    except requests.RequestException as exc:
        return jsonify({"status": None, "error_status": exc.__class__.__name__, "error_message": _short(exc),
                        "token_sha12": sha12})
    err = {}
    if resp.status_code != 200:
        try:
            err = resp.json().get("error", {})
        except ValueError:
            err = {"message": resp.text}
    return jsonify({"status": resp.status_code, "error_status": err.get("status"),
                    "error_message": _short(err.get("message")), "token_sha12": sha12})


NONCE_RE = re.compile(r"^[a-z0-9]{8,40}$")
_RELAY: dict = {}
_LOCK = threading.Lock()
TTL = 120


def _sweep() -> None:
    now = time.time()
    for k in [k for k, (_, t) in _RELAY.items() if now - t > TTL]:
        _RELAY.pop(k, None)


@app.post("/relay/put")
def relay_put():
    body = request.get_json(silent=True) or {}
    nonce, token = body.get("nonce", ""), body.get("token")
    if not NONCE_RE.match(str(nonce)) or not isinstance(token, str) or not token:
        return jsonify({"stored": False, "error": "bad nonce or token"}), 400
    with _LOCK:
        _sweep()
        if len(_RELAY) >= 4 or nonce in _RELAY:
            return jsonify({"stored": False, "error": "relay full or nonce used"}), 409
        _RELAY[nonce] = (token, time.time())
    return jsonify({"stored": True, "token_sha12": hashlib.sha256(token.encode()).hexdigest()[:12]})


@app.get("/relay/take")
def relay_take():
    nonce = request.args.get("nonce", "")
    if not NONCE_RE.match(nonce):
        return jsonify({"error": "bad nonce"}), 400
    with _LOCK:
        _sweep()
        entry = _RELAY.pop(nonce, None)
    if entry is None:
        return jsonify({"error": "no entry (expired, taken or never stored)"}), 404
    return jsonify({"token": entry[0]})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8080")))
