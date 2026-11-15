# v1.1 run order, part C: T23, T25, T16

Run IDs: `run-4` (first sitting), `run-5` (second). Every `apply` is run by the human. Each script needs a new `RUN_ID` per stage set. Check `gcloud auth` freshness before each block (admin logins expire in about 1 hour).

## T25: Binary Authorization admission (any day, free of other tests)

| Step | Who | Action |
|---|---|---|
| 1 | apply | `enable_t25_binauthz=true` and `enable_dc3_build_bucket=true` (the CMEK build bucket stages and logs the image build). KMS key ring and key stay afterwards (not deletable). |
| 2 | check | `gcloud container binauthz policy export --project=MCP` shows `REQUIRE_ATTESTATION`. Wait a few minutes for the policy. |
| 3 | test | `RUN_ID=run-4 tests/T25.sh` (creates a temporary Artifact Registry repository, builds `tests/fixtures/t25`, deploys unattested, signs, deploys again; cleans up the service, image and repository). |
| 4 | apply | `enable_t25_binauthz=false` (destroys the policy; the provider restores the default policy). Run T17 only after this step: while the toggle is on, the T17 positive control (hello image with `--binary-authorization=default`) is refused. |

If the build fails on Artifact Registry push permission for the Cloud Build service account, the script records INCONCLUSIVE (no digest); grant the role by hand and use `run-4-r2`.

## T23: agent deployed before vs after enforcement (needs the DC2 ingress variable)

Start from base state: agents not deployed, runtime project in neither the perimeter spec nor status (as T14R step 0).

| Step | Who | Action |
|---|---|---|
| 1 | apply | `infra/agents` with `deploy_agent_a = true` only. |
| 2 | test | `RUN_ID=run-4 tests/T23.sh pre` (A fetches example.com: tool status 200). Prints A's `principal://` string. |
| 3 | apply | Stage 3a/3b as in T14R: project in the enforced perimeter, `vpc_sc_enforced = true`, `vpc_sc_agent_ingress_identities = [A]`, operator ingress rule as in the T14 run. |
| 4 | apply | `infra/agents` with `deploy_agent_b = true` (B is deployed after enforcement). Read B's `identity` from `terraform output agent_b`. |
| 5 | apply | `vpc_sc_agent_ingress_identities = [A, B]`, strings exactly as reported. |
| 6 | wait | 15 minutes for perimeter propagation. |
| 7 | test | `RUN_ID=run-4 tests/T23.sh post` (guards that both identities are in the enforced ingress policy; A fetches, then B fetches; writes the result). Expected: A 200, B tool error. A refused by VPC-SC: INCONCLUSIVE with the violation reason from the audit log. |
| 8 | apply | Stage 4: destroy agents, remove ingress rules, `vpc_sc_enforced = false`, `vpc_sc_agent_ingress_identities = []`, drift check. |

## T16: Secure Web Proxy (paid, same-day destroy)

| Step | Who | Action |
|---|---|---|
| 1 | apply | `swp_enabled=true` (VPC, proxy-only subnet, firewall, gateway; cost about USD 1.25 per gateway-hour plus USD 0.018/GB). If the gateway is rejected without a certificate, set `swp_certificate_url` (self-signed regional Certificate Manager certificate) and re-apply. Record the start time. |
| 2 | check | `gcloud network-services gateways describe lzv-swp --location=europe-west1 --project=RUNTIME` succeeds. |
| 3 | test | `RUN_ID=run-4 tests/T16.sh` (three Cloud Run jobs: allowed host via proxy, non-allowed host, bypass). Direct VPC egress can add a minute or more of start delay. If `docker.io` images are refused, set `T16_IMAGE` to an Artifact Registry copy. If `swp_allowed_host` is not `example.com`, set `SWP_ALLOWED_HOST`. |
| 4 | human | Delete the three jobs if the script's cleanup could not confirm the delete (names are in `output.txt`, `lzv-t16a-...`, `lzv-t16b-...`, `lzv-t16c-...`): `gcloud run jobs delete NAME --region=europe-west1 --project=RUNTIME`, then `gcloud run jobs list` to confirm none left. No `--quiet`. |
| 5 | apply | SAME DAY: `swp_enabled=false`. Gateway is deleted first; the auto-generated router `swg-autogen-router-*` is removed by the module. Confirm with `gcloud network-services gateways list --location=europe-west1 --project=RUNTIME` (empty) and `gcloud compute routers list --project=RUNTIME`. Record the end time and the gateway-hours in `PROGRESS.md`. |

Run 5: repeat each block from its first step with `RUN_ID=run-5`.

- T25 cleanup (added 2026-10-25 after run-4): after the run, delete the temporary Artifact Registry repository yourself (the script prints the exact `HUMAN CLEANUP:` command; the delete prompts and `--quiet` is not allowed).
