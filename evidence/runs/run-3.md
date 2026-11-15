# Run 3 (T14R re-test only)

- Date: 2026-10-25. Scripts at commit 701baba (T14R pre-registered in 701baba before any step). Order: tests/RUN-ORDER.md "T14R re-test". Same day as run 2 (run 2 ended 05:58Z); human approved the re-test in this session.
- Start state: base (toggles off, perimeter dry-run spec = 3 projects, no status, no ingress, no agents).
- Step 0, 14:18Z: runtime project removed from the lzv_ai dry-run spec with `gcloud access-context-manager perimeters dry-run update --remove-resources` (human approved the design). Describe: spec 2 projects, runtime in spec 0, status 0. Wait 15 min before the deploy so the change has taken effect.
- ADC re-login by human 14:20Z.
- Step 1, 14:36Z: agent A deployed (human asked Opus to apply plan-a-run3.tfplan: 1 add, no IAM grants; guard ok; log scratch/apply-a-run3.txt). Waited 15 min after step 0 before the deploy.
- Step 2: T14R pre PASS (guard: runtime in spec 0, status 0; tool status 200). Evidence evidence/T14R/run-3/stages/pre.json.
- Step 3, 14:38Z: Stage 3a apply (plan-stage3a-run3.tfplan: runtime re-added to spec, status enforced on 3 projects, storage + aiplatform; toggles T05-T07 off, unlike runs 1/2) and operator ingress via gcloud (status + spec; log scratch/ingress-apply-run3.txt). Describe: runtime in status 1, in spec 1, ingress status 1, spec 1. tfvars vpc_sc_operator_ingress = true. Wait 15 min before post.
- Wait done 14:53Z. T14R post starts.
- Step 4, 14:54Z: T14R post INCONCLUSIVE (as pre-registered: no tool result). Query HTTP 200 (operator ingress works), body = VPC-SC 403. Post-result read-only lookup (evidence/T14R/run-3/post-audit-lookup.txt): caller = agent A's own principal, aiplatform SessionService.CreateSession, ingress NO_MATCHING_ACCESS_LEVEL. Finding: an agent deployed before its project joined the perimeter is treated as an outside caller; its own Vertex AI calls are refused, so it stops working (internet egress not observable).
- Stage 4, 14:55Z: agent A destroyed (plan 0/0/1, agent A only; log scratch/apply-stage4-agents-run3.txt). 14:56Z: perimeter reset with gcloud (status cleared; spec ingress cleared; spec = 3 projects incl. runtime, dry-run). tfvars: vpc_sc_enforced = false, vpc_sc_operator_ingress = false.
- 15:11Z checks (scratch/stage4-checks-run3.txt): `terraform plan` no changes in infra/ and infra/agents/; 0 test buckets, Cloud Run services, test SAs in all 4 projects; 0 reasoning engines. Snapshot refreshed. Environment back to base.

## Result

| Test | Verdict | Tier | Evidence | Note |
|---|---|---|---|---|
| T14R | INCONCLUSIVE | Enforced (recorded) | evidence/T14R/run-3/ | pre: tool status 200 (project in no perimeter). post: agent's own aiplatform CreateSession refused, ingress NO_MATCHING_ACCESS_LEVEL; no tool call. See errata E8 |
