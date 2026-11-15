# agent_v3 (T45, T48)

Deterministic harness-boundary probe. Query text is a command: `ACTION=<model|a|b|c|replay> MODE=<guarded|bypass> [VARIANT=<proxy|direct>] [TARGET=allowed|denied] [DEST=src|out]`.
`model` and `a` run the same Vertex call (`model` is the positive control label; `a` is the forbidden call, the difference is whether `LZV_AGENT_NAME` is in `LZV_APPROVED_AGENTS`). `TARGET` (b, default denied) and `DEST` (c, default out) only choose between env-supplied values, for positive controls. No LLM picks any target.

Env: `LZV_ALLOWED_URL`, `LZV_DENIED_URL`, `LZV_SRC_BUCKET`, `LZV_SRC_OBJECT`, `LZV_OUT_BUCKET`, `LZV_MODEL`, `LZV_MODEL_LOCATION`, `LZV_PROJECT_ID`, `LZV_REPLAY_URL`, `LZV_AGENT_NAME`, `LZV_APPROVED_AGENTS` (comma list), `HTTPS_PROXY` optional.

## How guarded mode runs the real callback
`HarnessProbe` (a `BaseAgent`) owns two inner `LlmAgent`s and runs the chosen one with `inner.run_async(ctx)`, the normal ADK flow.
- model_agent: real Gemini model with `before_model_callback`; the callback fires before the request leaves the process and refuses unless the agent name is approved.
- tool_agent: its "model" is `ScriptedLlm`, which emits one fixed function call (arguments built from env), so the ADK tool pipeline and `before_tool_callback` (URL host allowlist, destination bucket allowlist) run for real without an LLM choosing anything.

`mode=bypass` sets both callback attributes to `None` on the live agents, then calls `google.genai` `generate_content`, `urllib` GET, or `storage copy_blob` directly. `b` + `VARIANT=direct` also pops `HTTPS_PROXY`/`https_proxy` from `os.environ` for the call and restores them. Callbacks are re-armed afterwards. `HARNESS_GUARD` is fixed to on.

## Output
One JSON line: `action, mode, variant, harness_guard, refused_by (adk_callback | http_status | exception class | null), status, error (max 300 chars), timestamp, agent_name`.
`replay` (T48) also returns `own_call_status, token_sha12, token_expiry, replay_http_status, replay` (the replay service's JSON). Tokens are held in memory only; error text is scrubbed of token-like strings.

Build: `bash build.sh` writes `infra/agents/build/source-v3.tar.gz` and `infra-v3h/build/source.tar.gz` (identical bytes) and prints the sha256.
Not run against ADK locally (no install); verified with `py_compile` only.
