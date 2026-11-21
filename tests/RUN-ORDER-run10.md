# Run-10 order: the Model Armor and Agent Gateway tests on Fabric-native modules (DRAFT, pre-registration)

Written 2026-11-21, before any run-10 apply or test. Backlog Track E, items 17 and 18 (`fabric-ai-policy-dev-plan.md`).

## Purpose

Runs 6 to 9 built the Model Armor floors, the Model Armor templates and the Agent Registry entries from raw provider resources, because Fabric had no inputs for them. Those inputs are now merged upstream. Run 10 repeats the tests that depend on those objects, with the objects created by the Fabric modules. The goal is evidence that the merged modules produce working controls in a real organization.

| Object | Runs 6-9 | Run 10 | Fabric PR | Tests |
|---|---|---|---|---|
| Folder floor | `google_model_armor_floorsetting.v2_folder` | `module.folder_root` `model_armor_floor_setting` | #4361 | T27 |
| Project floor + Vertex AI integration | `google_model_armor_floorsetting.v2_project` | `module.prj_runtime` `model_armor_floor_setting` | #4379 | T29 |
| Org floor (optional stage) | `google_model_armor_floorsetting.v2_org` | `module.org_ma_floor` (`modules/organization`) | #4310 | T38 |
| T28 template `lzv-ma-pi` | `google_model_armor_template.v2_pi` | `module.prj_runtime` `model_armor_templates` | #4423 | T28 (T27/T38 controls) |
| Gateway template `lzv-ma-gw` | `google_model_armor_template.v2_gw` | `module.prj_runtime` `model_armor_templates` | #4423 | T32 |
| 22 registry entries (MCP server, model and essential endpoints, T31R entry) | `google_agent_registry_service.*` | `module.v2_agent_registry` (`modules/geap-agent-registry`) | #4434 | T30, T31, T31R, T32 |

Not exercised: `modules/project-factory` (#4397). This stack does not use the project factory. Run 10 makes no claim about it.

## Changes before the run (infra only; test scripts and expected texts unchanged)

- `vendor/fabric`: `be0d4b1` -> `7efa56dbf` (upstream master, 2026-11-21). Providers google and google-beta: 8.8.0 -> 8.12.0 (the new modules require >= 8.12.0).
- `infra/main.tf`, `infra/v2-model-armor.tf`, `infra/v2-gateway.tf`, `infra/v3h-targets.tf`: inputs as in the table. `moved` blocks for the four objects in state (folder floor, project floor, `lzv-ma-pi`, the runtime `modelarmor.googleapis.com` service). The gateway objects were not in state, so they have no moved blocks.
- The Model Armor API on the runtime project is now in the project module's `services`. Side effect (Fabric behaviour): the module also creates the Model Armor service identity and grants it `roles/modelarmor.serviceAgent` in the runtime project.

## Plan evidence (read-only, 2026-11-21; files in scratch/, not published)

| Check | Result |
|---|---|
| Baseline: old pin `be0d4b1`, old code, current profile (lz-5 + v3h-baseline) | 0 add, 0 change, 8 destroy (the existing SWP/PSC-I leftovers) |
| New pin, new code, same profile, untargeted | 2 add, 2 change, 8 destroy. Same 8 destroys. Swap diff: 4 moves, 2 floor updates, 2 adds |
| Swap diff detail | Both floors: `+ floor_setting_metadata { multi_language_detection { enable_multi_language_detection = false } }`. The module always sends it (the API rejects later updates without it). Adds: Model Armor service identity and `roles/modelarmor.serviceAgent` |
| Gateway on (`enable_v2_gateway`, `enable_v2_model_armor`, `enable_v2_gateway_vpc`, `v2_gateway_model_armor`, `v2_gateway_t31r_register_blocked`), old vs new | old 53 add; new 55 add + 2 change (the swap diff above). The 22 registry entries, the gateway and the `lzv-ma-gw` template match attribute by attribute. Only differences: empty `filter_rule_settings` on the template, and the extension's template ID now resolves at apply time from the module output (same string) |
| Org floor toggle on | +1 `module.org_ma_floor[0].google_model_armor_floorsetting.default[0]` (+ `v2_ma_data` service), nothing else from the organization module |
| Apply plan for stage 10-0a (targeted at the two modules and the four moved addresses) | 2 add, 2 change, 0 destroy, 4 moves (`infra/plan-run10-10a-swap.tfplan`) |

Not changed by this run: other modules in the stack also moved from `be0d4b1` to `7efa56dbf` (folder, project, net-vpc, firewall, dns, kms, binauthz, vpc-sc, logging-bucket, net-swp, geap-agent-runtime). With the current profile and with the gateway on, they plan no diff.

## Expected results (pre-registered; byte-identical to the script headers)

The scripts are unchanged since their last runs (T27/T28/T29/T38 at `6c0b8af`, T30/T31/T32 at `75dc030`, T31R at `a30b521`). Run 10 uses the same expected texts:

- T27: Weak template create fails (non-zero exit, error from `modelarmor.googleapis.com`; text recorded as observed); the weak template does not exist afterwards
- T28: `filterMatchState` `MATCH_FOUND`, with the prompt-injection filter matched
- T29: Response blocked: `blockReason: "MODEL_ARMOR"`, message starts "Blocked by Floor Setting"; HTTP status recorded
- T38 (optional stage): Weak template refused, as T27
- T30: Unregistered: HTTP 403 and a gateway log entry with verdict `DENIED`; registered: answered
- T31: Gateway refuses (403, `DENIED`) although IAM allows the agent; then the same call by a non-approved agent is refused by the IAM deny policy ("due to an IAM deny policy")
- T32: Tool call fails for the agent (connection terminated); a Model Armor finding is logged
- T31R: `pre`: G's call to the unregistered model endpoint is refused (403) although IAM allows G; `post`: after only the registry changes, the same call is answered (200); B is refused by the IAM deny policy ("due to an IAM deny policy"). Runs only if the fixture decision below gives a model call that can return 200 on the europe-west1 host.

Prediction for T29: runs 6 and 7 were FAIL (block message prefix). The script is unchanged, so FAIL is possible again. It will be reported as observed.

## T31R fixture (item 18): read-only check, 2026-11-21

Run 9's T31R `post` got 404 because agent G sends the same model (`LZV_MODEL`, `gemini-3.5-flash`) to both hosts, and that model is not served on `europe-west1-aiplatform.googleapis.com`. Read-only `countTokens` from the operator in the runtime project (`scratch/t31r-model-check.txt`):

- global host, `gemini-3.5-flash`: 200.
- europe-west1 host: 404 "Publisher model ... was not found or your project does not have access to it" for every Gemini name tried: gemini-3.5-flash, -3.5-pro, -3.5-flash-lite, -3-flash, -3-pro, -2.5-flash, -2.5-flash-001, -2.5-flash-lite, -2.5-pro, -2.0-flash, -2.0-flash-001, -2.0-flash-lite-001.
- Same 404 on europe-west3, europe-west4, europe-west9, the `eu` multi-region host and us-central1, for gemini-3.5-flash and gemini-2.5-flash.
- Embedding models (text-embedding-005/004, gemini-embedding-001, text-multilingual-embedding-002) have no `countTokens` route. Only a billed `:predict` could check them, and `vertexai.allowedModels` on fldr-ai-prod allows only `gemini-3.5-flash`.

So no Gemini model is served on any regional host for this project. A fixture with "a model served on europe-west1" is not available as specified. Options (human decision; nothing changed yet):

- (a) An embedding model on the europe-west1 host for the `blocked` call (`:predict`). Needs one tiny billed check call and the model added to `allowed_models` (org policy change on fldr-ai-prod, restored after the run). The agent G code changes (new env `LZV_MODEL_BLOCKED`, `blocked` uses `:predict`), so it needs a new pre-registered T31R version.
- (b) Change the `blocked` call to a read-only, non-model request on the same host (for example, list reasoning engines). No policy change. The claim narrows from "model endpoint" to "unregistered host", and that is how it would be reported.
- (c) Do not run T31R. It stays INCONCLUSIVE with the cause recorded above (finding: regional Gemini serving is not available to this project).

### T31R v2 (human decision 2026-11-21 ~15:50Z: "use global models"; written before any 10-2 apply)

Read-only checks from the operator, 2026-11-21 (`scratch/t31r-global-check.txt`): the europe-west1 host does not serve `gemini-3.5-flash` under `locations/global` either (404). The EU multi-region REP host `aiplatform.eu.rep.googleapis.com` does: `countTokens` 200 and one `generateContent` 200 (`finishReason` STOP, text "OK.", modelVersion gemini-3.5-flash) for `locations/global`. That host is in no registry entry (the registered Vertex hosts are `aiplatform.googleapis.com`, `aiplatform.mtls.googleapis.com`, `aiplatform.europe-west1.rep.googleapis.com`, `europe-west1-aiplatform.mtls.googleapis.com` and the sessions URL).

Changes (T31R v2):

- `tests/fixtures/gateway/agent_g/agent.py`: new endpoint key `blocked_global` = (`https://aiplatform.eu.rep.googleapis.com`, `global`). `allowed` and `blocked` unchanged, so T31 runs as in runs 8 and 9.
- `tests/T31R.sh`: blocked call is `blocked_global`; `BLOCKED_URL` (registry check) and the supporting log filter use that host. Header and expected text byte-identical to `a30b521`.
- `infra/v2-gateway.tf`: `lzv-ep-t31r-blocked` URL is `https://aiplatform.eu.rep.googleapis.com` (only applied in 10-2r).

The claim stays "a model endpoint that is not in the registry". Limitation: the model host differs from T31's blocked host, so T31R v2 is not a re-run of T31 part 1 on the same endpoint; it tests the same claim with a host that can answer 200. Run 9's T31R stays INCONCLUSIVE.

## Stages

Rules as in runs 8/9: config `lz-validation`, account and org checked before each apply; the human approves each apply; fresh logins before paid rows; same-day teardown of paid resources.

| Stage | Apply (each approved separately) | Tests |
|---|---|---|
| 10-0 | Precheck (read-only): config, account, logins; base state (0 engines, 0 gateways); `bash -n` on the scripts | — |
| 10-0a | `terraform apply plan-run10-10a-swap.tfplan` (2 add, 2 change, 0 destroy, 4 moves). Then untargeted plan: only the 8 known SWP/PSC-I destroys may remain. Wait 15 min. **Done 2026-11-21T13:53:58Z** (human approved in chat): 2 added, 2 changed, 0 destroyed; post-apply plan shows only the 8 leftovers; floors read back unchanged apart from the metadata block | — |
| 10-1 | none (free) | `RUN_ID=run-10 bash tests/T27.sh`, `T28.sh`, `T29.sh` |
| 10-1o (optional, org scope) | `enable_v2_ma_org_floor=true`, `enable_v2_ma_folder_floor=false` as in run 6 (precedence), org enforce true; wait 15; then rollback: enforce false, apply, toggle off (floors cannot be deleted) | `T38.sh` |
| 10-2 (paid, same day) | As run 9 (9-0a to 9-0d): gateway on (untargeted, `-parallelism=1`, expect about 55 add), fixtures build/deploy, agent G, deny policy | T30, T32; after B: T31 |
| 10-2r | Only with fixture option (a) or (b) and a 403 in T31R `pre`: targeted `-target='module.v2_agent_registry.google_agent_registry_service.default["lzv-ep-t31r-blocked"]'` with `v2_gateway_t31r_register_blocked=true`; wait 5 | T31R `pre`/`post` |
| 10-3 | Reset as 9-2a/9-2b (gateway, agents, Model Armor gateway objects off) | — |

T34 (firewall log attribution) is not in run 10. It needs the SWP stack, PSC-I and agent C, and SWP bills by the hour, so it is not a cheap retry.

## Stale references (not run in run 10)

`tests/T49.sh` and `tests/T57.sh` refer to the old addresses (`google_agent_registry_service.v3h_ep_replay`, `google_model_armor_floorsetting.v2_project[0]`). They must be updated before any future run of those tests. Their past results are unaffected.

## Cost

Stages 10-0a, 10-1 and 10-1o: no billed resources (Model Armor sanitize calls and two Vertex calls, cents at most). Stage 10-2 creates the gateway, two Cloud Run services, two Agent Runtime agents and the PSC endpoint for about 3.5 hours. Runs 8 and 9 recorded no separate cost; the billing account budget alert is USD 50/month. The cost will be read from Billing after the run and written to limitations.md.
