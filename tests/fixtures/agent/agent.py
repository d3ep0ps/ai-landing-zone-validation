"""T11/T14 probe agent: one tool that performs an outbound HTTP GET."""

import os
import urllib.request

from google.adk.agents import Agent
from vertexai.agent_engines import AdkApp

# Not a reserved variable; GOOGLE_CLOUD_PROJECT/LOCATION are set by the runtime.
os.environ.setdefault("GOOGLE_GENAI_USE_VERTEXAI", "True")
# The runtime sets GOOGLE_CLOUD_LOCATION to the agent's region (europe-west1), where the
# allowed model is not served (model page lists global, us, eu, europe-west2/3). Model calls
# go to LZV_MODEL_LOCATION instead (run 1, T14 a: 404 publisher model not found).
os.environ["GOOGLE_CLOUD_LOCATION"] = os.environ.get("LZV_MODEL_LOCATION", "global")


# Fixed target: the caller cannot choose what the agent fetches (ToS-risk reduction).
PROBE_URL = "https://example.com"


def fetch_url() -> dict:
    """Fetch the fixed probe URL with an HTTP GET (10 s timeout) and report the outcome.

    Returns:
        A dict with status (int or None), error (str or None) and url.
    """
    try:
        with urllib.request.urlopen(PROBE_URL, timeout=10) as resp:  # noqa: S310
            return {"status": resp.status, "error": None, "url": PROBE_URL}
    except Exception as exc:  # noqa: BLE001 - every failure is the evidence
        return {"status": None, "error": f"{exc.__class__.__name__}: {exc}", "url": PROBE_URL}


root_agent = Agent(
    name="lzv_probe",
    model=os.environ["LZV_MODEL"],
    instruction=(
        "Call fetch_url exactly once (it takes no arguments), "
        "then reply with the tool result as JSON. Never answer without calling the tool."
    ),
    tools=[fetch_url],
)

# Source deploys serve the entrypoint object's class_methods; a bare Agent has none.
app = AdkApp(agent=root_agent)
