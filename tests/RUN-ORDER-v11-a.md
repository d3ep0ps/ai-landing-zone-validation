# v1.1 run order, part a (T18, T19)

Use RUN_ID run-4 (first v1.1 run) or run-5 (second). Scripts never apply Terraform; the human applies between stages. Pre-conditions and tfvars below are guards in the scripts (wrong state = abort, exit 2, nothing recorded as a result).

## T19 (TS1, IAM diff around one agent deploy)

Run before T18 pre, because it needs a state with no agents.

1. infra/agents: `deploy_agent_a=false`, `deploy_agent_b=false`. Root infra: `enable_dc1_deny=false`.
2. `RUN_ID=run-4 tests/T19.sh before` (snapshot of 3 projects, 2 folders, project deny policies).
3. Human: set `deploy_agent_a=true` (B stays false), apply infra/agents. Wait about 5 minutes for IAM propagation.
4. `RUN_ID=run-4 tests/T19.sh after` (snapshot, diff, verdict). Tier Configured.

## T18 (DC1 deny policy)

Needs agents A and B deployed, so it follows T19.

1. infra/agents: `deploy_agent_a=true`, `deploy_agent_b=true`; apply. Root infra: `enable_dc1_deny=false`.
2. `RUN_ID=run-4 tests/T18.sh pre`. Both agents must answer. Copy the printed `dc1_approved_agent_principals` line (agent A principal) from the output.
3. Human: set `enable_dc1_deny=true` and `dc1_approved_agent_principals=["<agent A principal://...>"]` (agent B not listed); apply root infra.
4. Wait at least 10 minutes after the deny policy createTime (the script aborts with a guard message if younger).
5. `RUN_ID=run-4 tests/T18.sh post`. Final verdict merges pre and post; a non-PASS pre gives INCONCLUSIVE. Tier Enforced.
6. Afterwards the human may set `enable_dc1_deny=false` and destroy agents the same day.
