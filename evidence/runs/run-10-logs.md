# Run 10: log reads used for observations (supplement)

Read-only `gcloud logging read` after the tests (Opus), runtime project. Columns: timestamp, log, host and path prefix (identifiers redacted), HTTP status, gateway authz result. Raw JSON stays in git-ignored scratch/; this file is the redacted extract. Supporting evidence only; verdicts come from the test scripts.

## T30 run-10 window 16:51-16:55Z, gateway_requests (all entries)

```
2026-11-21T16:51:37.169021Z	networkservices.googleapis.com/gateway_requests	europe-west1-aiplatform.mtls.googleapis.com/v1beta1/projects/PROJECT_NUMBER_26	200	ALLOWED
2026-11-21T16:51:37.505330Z	networkservices.googleapis.com/gateway_requests	europe-west1-aiplatform.mtls.googleapis.com/v1beta1/projects/PROJECT_NUMBER_26	200	ALLOWED
2026-11-21T16:51:37.822892Z	networkservices.googleapis.com/gateway_requests	europe-west1-aiplatform.mtls.googleapis.com/v1beta1/projects/PROJECT_NUMBER_26	200	ALLOWED
2026-11-21T16:51:37.835982Z	networkservices.googleapis.com/gateway_requests	-	200	-
2026-11-21T16:51:37.840528Z	networkservices.googleapis.com/gateway_requests	europe-west1-aiplatform.mtls.googleapis.com/v1beta1/projects/PROJECT_NUMBER_26	200	ALLOWED
2026-11-21T16:51:38.806220Z	networkservices.googleapis.com/gateway_requests	europe-west1-aiplatform.mtls.googleapis.com/v1beta1/projects/PROJECT_NUMBER_26	200	ALLOWED
2026-11-21T16:51:39.371338Z	networkservices.googleapis.com/gateway_requests	-	200	-
2026-11-21T16:51:41.686506Z	networkservices.googleapis.com/gateway_requests	-	200	-
2026-11-21T16:51:41.698496Z	networkservices.googleapis.com/gateway_requests	iamcredentials.mtls.googleapis.com/v1/projects/-/serviceAccounts/b47b3	404	ALLOWED
2026-11-21T16:51:41.700113Z	networkservices.googleapis.com/gateway_requests	telemetry.mtls.googleapis.com/v1/logs	200	ALLOWED
2026-11-21T16:51:43.293884Z	networkservices.googleapis.com/gateway_requests	europe-west1-aiplatform.mtls.googleapis.com/v1beta1/projects/PROJECT_NUMBER_26	200	ALLOWED
2026-11-21T16:51:43.534104Z	networkservices.googleapis.com/gateway_requests	aiplatform.mtls.googleapis.com/v1beta1/projects/PROJECT_NUMBER_7/locations	200	ALLOWED
2026-11-21T16:51:46.070247Z	networkservices.googleapis.com/gateway_requests	europe-west1-aiplatform.mtls.googleapis.com/v1beta1/projects/PROJECT_NUMBER_26	200	ALLOWED
2026-11-21T16:51:46.661644Z	networkservices.googleapis.com/gateway_requests	telemetry.mtls.googleapis.com/v1/metrics	200	ALLOWED
2026-11-21T16:51:48.868812Z	networkservices.googleapis.com/gateway_requests	europe-west1-aiplatform.mtls.googleapis.com/v1beta1/projects/PROJECT_NUMBER_26	200	ALLOWED
2026-11-21T16:51:49.140262Z	networkservices.googleapis.com/gateway_requests	europe-west1-aiplatform.mtls.googleapis.com/v1beta1/projects/PROJECT_NUMBER_26	200	ALLOWED
2026-11-21T16:51:49.445916Z	networkservices.googleapis.com/gateway_requests	europe-west1-aiplatform.mtls.googleapis.com/v1beta1/projects/PROJECT_NUMBER_26	200	ALLOWED
2026-11-21T16:51:49.446564Z	networkservices.googleapis.com/gateway_requests	europe-west1-aiplatform.mtls.googleapis.com/v1beta1/projects/PROJECT_NUMBER_26	200	ALLOWED
2026-11-21T16:51:49.682633Z	networkservices.googleapis.com/gateway_requests	europe-west1-aiplatform.mtls.googleapis.com/v1beta1/projects/PROJECT_NUMBER_26	200	ALLOWED
2026-11-21T16:51:49.965233Z	networkservices.googleapis.com/gateway_requests	aiplatform.mtls.googleapis.com/v1beta1/projects/PROJECT_NUMBER_7/locations	200	ALLOWED
2026-11-21T16:51:52.256988Z	networkservices.googleapis.com/gateway_requests	europe-west1-aiplatform.mtls.googleapis.com/v1beta1/projects/PROJECT_NUMBER_26	200	ALLOWED
2026-11-21T16:51:52.352832Z	networkservices.googleapis.com/gateway_requests	telemetry.mtls.googleapis.com/v1/logs	200	ALLOWED
2026-11-21T16:51:52.542315Z	networkservices.googleapis.com/gateway_requests	-	200	-
2026-11-21T16:51:52.792150Z	networkservices.googleapis.com/gateway_requests	europe-west1-aiplatform.mtls.googleapis.com/v1beta1/projects/PROJECT_NUMBER_26	200	ALLOWED
2026-11-21T16:51:53.539652Z	networkservices.googleapis.com/gateway_requests	telemetry.mtls.googleapis.com/v1/traces	403	ALLOWED
2026-11-21T16:51:54.957214Z	networkservices.googleapis.com/gateway_requests	telemetry.mtls.googleapis.com/v1/logs	200	ALLOWED
2026-11-21T16:51:54.957699Z	networkservices.googleapis.com/gateway_requests	telemetry.mtls.googleapis.com/v1/traces	403	ALLOWED
2026-11-21T16:51:55.277465Z	networkservices.googleapis.com/gateway_requests	telemetry.mtls.googleapis.com/v1/metrics	200	ALLOWED
2026-11-21T16:54:43.596273Z	networkservices.googleapis.com/gateway_requests	-	200	-
2026-11-21T16:54:43.600985Z	networkservices.googleapis.com/gateway_requests	europe-west1-aiplatform.mtls.googleapis.com/v1beta1/projects/PROJECT_NUMBER_26	200	ALLOWED
2026-11-21T16:54:43.897266Z	networkservices.googleapis.com/gateway_requests	europe-west1-aiplatform.mtls.googleapis.com/v1beta1/projects/PROJECT_NUMBER_26	200	ALLOWED
2026-11-21T16:54:44.174709Z	networkservices.googleapis.com/gateway_requests	europe-west1-aiplatform.mtls.googleapis.com/v1beta1/projects/PROJECT_NUMBER_26	200	ALLOWED
2026-11-21T16:54:44.186220Z	networkservices.googleapis.com/gateway_requests	-	200	-
2026-11-21T16:54:44.190050Z	networkservices.googleapis.com/gateway_requests	europe-west1-aiplatform.mtls.googleapis.com/v1beta1/projects/PROJECT_NUMBER_26	200	ALLOWED
2026-11-21T16:54:44.586639Z	networkservices.googleapis.com/gateway_requests	europe-west1-aiplatform.mtls.googleapis.com/v1beta1/projects/PROJECT_NUMBER_26	200	ALLOWED
2026-11-21T16:54:44.995695Z	networkservices.googleapis.com/gateway_requests	-	200	-
2026-11-21T16:54:47.122891Z	networkservices.googleapis.com/gateway_requests	lzv-mcp-reg-PROJECT_NUMBER_7.europe-west1.run.app/mcp	200	ALLOWED
2026-11-21T16:54:47.793006Z	networkservices.googleapis.com/gateway_requests	aiplatform.mtls.googleapis.com/v1beta1/projects/PROJECT_NUMBER_7/locations	200	ALLOWED
2026-11-21T16:54:48.083270Z	networkservices.googleapis.com/gateway_requests	telemetry.mtls.googleapis.com/v1/traces	403	ALLOWED
2026-11-21T16:54:49.793959Z	networkservices.googleapis.com/gateway_requests	europe-west1-aiplatform.mtls.googleapis.com/v1beta1/projects/PROJECT_NUMBER_26	200	ALLOWED
2026-11-21T16:54:49.988312Z	networkservices.googleapis.com/gateway_requests	telemetry.mtls.googleapis.com/v1/traces	403	ALLOWED
2026-11-21T16:54:55.130123Z	networkservices.googleapis.com/gateway_requests	-	200	-
2026-11-21T16:54:55.676002Z	networkservices.googleapis.com/gateway_requests	-	200	-
2026-11-21T16:54:55.680033Z	networkservices.googleapis.com/gateway_requests	europe-west1-aiplatform.mtls.googleapis.com/v1beta1/projects/PROJECT_NUMBER_26	200	ALLOWED
2026-11-21T16:54:55.943276Z	networkservices.googleapis.com/gateway_requests	europe-west1-aiplatform.mtls.googleapis.com/v1beta1/projects/PROJECT_NUMBER_26	200	ALLOWED
2026-11-21T16:54:56.126020Z	networkservices.googleapis.com/gateway_requests	-	200	-
```

## Cloud Run request logs and gateway entries naming run.app, from 16:45Z

```
2026-11-21T16:51:42.186347Z	run.googleapis.com/requests	lzv-mcp-reg-PROJECT_NUMBER_7.europe-west1.run.app/mcp	200	-
2026-11-21T16:51:42.294769Z	run.googleapis.com/varlog%2Fsystem	-	-	-
2026-11-21T16:51:43.081266Z	run.googleapis.com/varlog%2Fsystem	-	-	-
2026-11-21T16:54:47.122891Z	networkservices.googleapis.com/gateway_requests	lzv-mcp-reg-PROJECT_NUMBER_7.europe-west1.run.app/mcp	200	ALLOWED
2026-11-21T16:54:47.412769Z	run.googleapis.com/requests	lzv-mcp-reg-PROJECT_NUMBER_7.europe-west1.run.app/mcp	200	-
2026-11-21T16:55:08.006076Z	networkservices.googleapis.com/gateway_requests	lzv-mcp-reg-PROJECT_NUMBER_7.europe-west1.run.app/mcp	403	DENIED
2026-11-21T16:55:08.258826Z	run.googleapis.com/requests	lzv-mcp-reg-PROJECT_NUMBER_7.europe-west1.run.app/mcp	200	-
```

## T31/T31R window 17:15-17:26Z, gateway_requests for Vertex AI hosts or DENIED

```
2026-11-21T17:15:22.941329Z	networkservices.googleapis.com/gateway_requests	aiplatform.googleapis.com/v1/projects/PROJECT_8/locatio	200	ALLOWED
2026-11-21T17:18:31.910197Z	networkservices.googleapis.com/gateway_requests	aiplatform.googleapis.com/v1/projects/PROJECT_8/locatio	200	ALLOWED
2026-11-21T17:18:41.163034Z	networkservices.googleapis.com/gateway_requests	aiplatform.eu.rep.googleapis.com/v1/projects/PROJECT_8/	403	DENIED
2026-11-21T17:25:03.882055Z	networkservices.googleapis.com/gateway_requests	aiplatform.eu.rep.googleapis.com/v1/projects/PROJECT_8/	200	ALLOWED
```

## Entries naming the non-mTLS europe-west1 Vertex AI host from 17:10Z (agent stdout lines omitted)

```
2026-11-21T17:15:34.415054356Z	cloudaudit.googleapis.com/data_access	-	-	GatekeeperAuthorizer.AuthorizeUser
2026-11-21T17:29:03.954888587Z	cloudaudit.googleapis.com/data_access	-	-	GatekeeperAuthorizer.AuthorizeUser
```
