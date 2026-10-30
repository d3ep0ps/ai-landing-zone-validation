"""v2 agent C (T33, T34): probe agent with a PSC interface. One tool fetches one of two fixed URLs,
with or without the explicit proxy given in PROXY_SERVER_URL."""

import os

import requests
from google.adk.agents import Agent
from vertexai.agent_engines import AdkApp

os.environ.setdefault("GOOGLE_GENAI_USE_VERTEXAI", "True")
# Model calls go to LZV_MODEL_LOCATION (see tests/fixtures/agent/agent.py).
os.environ["GOOGLE_CLOUD_LOCATION"] = os.environ.get("LZV_MODEL_LOCATION", "global")

# Fixed targets: the caller picks a key, never a URL (ToS-risk reduction,
# notes/tos-suspension-analysis.md). "allowed" is the SWP allow-list host (T33 positive control);
# "denied" is a host the gateway policy does not allow.
TARGETS = {
    "allowed": "https://example.com",
    "denied": "https://www.wikipedia.org",
}


def fetch_probe(target: str, via_proxy: bool) -> dict:
    """Fetch one fixed URL with an HTTP GET (10 s timeout) and report the outcome.

    Args:
        target: "allowed" (example.com) or "denied" (www.wikipedia.org).
        via_proxy: True to send the request through the explicit proxy in PROXY_SERVER_URL;
            False to send it directly (expected to fail: no route out of the VPC).

    Returns:
        A dict with target, url, via_proxy, status (int or None) and error (str or None).
    """
    url = TARGETS.get(target)
    if url is None:
        return {"target": target, "url": None, "via_proxy": via_proxy, "status": None,
                "error": "unknown target (use allowed or denied)"}
    proxy = os.environ.get("PROXY_SERVER_URL")
    proxies = {"http": proxy, "https": proxy} if (via_proxy and proxy) else None
    try:
        resp = requests.get(url, proxies=proxies, timeout=10)
        return {"target": target, "url": url, "via_proxy": bool(proxies),
                "status": resp.status_code, "error": None}
    except Exception as exc:  # noqa: BLE001 - every failure is the evidence
        return {"target": target, "url": url, "via_proxy": bool(proxies), "status": None,
                "error": f"{exc.__class__.__name__}: {exc}"}


root_agent = Agent(
    name="lzv_probe_c",
    model=os.environ["LZV_MODEL"],
    instruction=(
        "The user names a target (allowed or denied) and whether to use the proxy. "
        "Call fetch_probe exactly once with exactly those arguments, "
        "then reply with the tool result as JSON. Never answer without calling the tool."
    ),
    tools=[fetch_probe],
)

app = AdkApp(agent=root_agent)
