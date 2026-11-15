# Run-6 gateway 401: what the logs show (2026-11-12, after T47r attempt 1)

Source: Cloud Logging `networkservices.googleapis.com/gateway_requests` in the runtime project. All records are still within the 30-day retention. Raw exports are in `scratch/401cmp/` (not published). This note is read-only analysis; no test was changed.

## Session calls through the gateway (the call that failed in run 6)

Session calls are `POST .../reasoningEngines/E/sessions` on `europe-west1-aiplatform.mtls.googleapis.com`. The client version is read from the user-agent `vertex-genai-modules/X`. The agent G token column comes from the run logs.

| Date (UTC) | Run | Status | Client (aiplatform) | `destinationUrn` in log | Agent G token |
|---|---|---|---|---|---|
| 2026-10-28 10h | run 6 | 401 ×5, 403 ×4 (403 = endpoint not registered yet, fixed) | 2.6.0 (google-genai 2.33.0) | absent | default binding (no opt-out) |
| 2026-10-29/30 | runs 7-9 | 200 | 2.6.0 | absent | opt-out (run-7 change, F16) |
| 2026-11-11 | v3h runs 1-2 | 200 | 2.6.0 (google-auth pinned 2.62.1) | present | default (no opt-out env; T47 s2) and opt-out (s3) |
| 2026-11-12 06h | T47r | 200 | 2.8.0 (google-auth 2.62.2, unpinned) | present | default |

## What is the same on both sides of the change

In run 6 and T47r, the gateway record of the session POST is identical apart from the `destinationUrn` field and the certificate fingerprint:
- IAP policy ALLOWED and Model Armor policy ALLOWED;
- `requestWasTlsIntercepted=true`;
- client certificate present, `clientCertChainVerified=false` (`client_cert_validation_not_performed`).

So the gateway intercepted TLS in both cases. Only Google's answer upstream differs (401 then, 200 now).

## Second signal

`iamcredentials.mtls.googleapis.com` GET through the gateway:
- run 6: 401;
- T47r: 404 (resource not found: authentication passed).

Two different Google services stopped rejecting the agent's credentials. That points at the token or gateway layer rather than at one service.

## Hypotheses (none verified)

- **H1, Google-side change between 2026-10-30 and 2026-11-11.** The gateway log format changed in that window (new `destinationUrn`), so the gateway had at least one release then. A change in how the gateway forwards agent requests, or in how Google APIs accept a bound token arriving through the gateway, would explain the 200. Docs (caa-agent-security) say the gateway terminates mTLS "so DPoP must be used". We have no record of whether DPoP is now used.
- **H2, agent G's token is no longer bound in November.** T48 proved binding only for v3a, which does not use the gateway. For G behind the gateway we have no direct evidence that the token is bound: T49 (which records G's binding state) has not run yet. Possible causes: the newer google-auth does not request a bound token in a gateway-bound runtime, or the runtime no longer provides the agent certificate there.
- **H3, a client-library difference in the run-6 package set.** Run 6 was unpinned. aiplatform 2.6.0 and google-genai 2.33.0 are now known from the user-agent; google-auth and google-adk are still unknown. The November runs used aiplatform 2.6.0 too, so aiplatform alone is not the cause.

## How to tell them apart (cheapest first)

1. **T49 `bound` stage in run 3.** It is already planned and costs nothing extra. Its binding state for G (certificate present, `should_request_bound_token`, token SHA prefix), and the replay of G's token to a regular host (401 if bound), answer H2 directly.
2. **If G's token is bound and still gets 200 through the gateway:** H2 is out. Then a one-attempt "T47r2" with the run-6 package set pinned would separate H1 from H3. That set is aiplatform 2.6.0, google-genai 2.33.0, and google-auth / google-adk as the latest PyPI releases on or before 2026-10-28 (dates to be checked on PyPI).
   - If T47r2 gets 401, the cause is client-side and reproducible.
   - If it gets 200, the cause is Google-side (H1) and can no longer be reproduced.
   - T47r2 needs pre-registration and human approval (paid: about 40 min of gateway time).

## Outcome (2026-11-13)

- **T49 run 3 (04:50Z):** agent G's token behind the gateway is bound (`agent_cert=true`, `should_request_bound=true`, replay to a regular host 401; google-auth 2.62.1). H2 is out.
- **T47r2 attempt 1 (06:40Z), PASS (discriminating test):** agent G with the run-6 package set (resolved in the runtime: google-adk 2.13.0, google-auth 2.62.0, google-cloud-aiplatform 2.6.0), IAP V1, default binding: query 200, session POST 200 ×3 in the gateway log. The run-6 401 does not reproduce with the run-6 packages. H3 is out.
- **Reading:** the cause of the run-6 401 was on Google's side (H1) and changed between 2026-10-30 and 2026-11-11; it can no longer be reproduced. Not shown: what changed (no release note found; the gateway log format changed in the same window). Limitation: agent G's code is the current fixture, not run 6's.
