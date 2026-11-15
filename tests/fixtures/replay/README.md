# replay (T48)

Tiny Cloud Run service. `POST /replay` with JSON `{"token": "<bearer>", "project": "...", "model": "...", "location": "..."}`
(project/model/location default to env `LZV_PROJECT_ID`, `LZV_MODEL`, `LZV_MODEL_LOCATION`). It calls the same Vertex AI
`generateContent` REST endpoint with the same fixed harmless prompt as `tests/fixtures/agent_v3` and returns
`{status, error_status, error_message (300 chars), token_sha12}`. A request without a token gets 400.
The token is never logged or returned. Deploy it with Cloud Run auth required (the agent sends an ID token for the
service URL). Run it in a different project from the agent so the replay comes from another workload. Not deployed by this repo yet.
