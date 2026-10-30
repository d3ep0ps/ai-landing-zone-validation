# v2 doc verification, area B (Agent Gateway, Gemini Enterprise trial)

Checked 2026-10-27, docs only; no cloud state changed. Docs are dated up to 2026-09-30 and change often; re-check before building.

## 1. What Agent Gateway is; stage, region, licence, pricing
- Answer: A component of Gemini Enterprise Agent Platform (not Apigee). Managed networking/policy point for agent traffic. Two modes: Client-to-Agent (ingress) and Agent-to-Anywhere (egress). Resource: `gcloud network-services agent-gateways`, REST `agentGateways` (networkservices v1alpha1 in the REST reference).
- Quotes: "Agent Gateway is currently available for agents running on Gemini Enterprise Agent Platform." Release notes: "June 18, 2026: Agent Gateway in General Availability"; "June 24, 2026: ... You can enable Model Armor on an Agent Gateway resource ... generally available"; "August 31, 2026: IAM Unified Access Policies are generally available (GA)".
- Regions: no supported-region list found. Rules: runtime agents must be in the gateway's region; ingress also same project; egress gateway may be in another project, same region. Codelabs use us-central1; VPC connectivity page uses europe-west1 as an example only. Gemini Enterprise gateways must match the app's multi-region.
- Licence: no Gemini Enterprise licence or edition requirement is stated on the overview or setup pages for the Agent Runtime path. Gemini Enterprise as a client: "Agent Gateway supports only Agent-to-Anywhere (egress) mode" and "Cross-project governance is not supported for Gemini Enterprise."
- Pricing: no price on the setup page ("only links to the Agent Platform and Generative AI pricing pages"). Official pricing page could not be read (too large). Secondary source (ecorpit.com, unverified): Agent-to-Anywhere metering starts 2026-07-13, billed as Agent Compute at about USD 0.085/vCPU-hour.
- URLs: https://docs.cloud.google.com/gemini-enterprise-agent-platform/govern/gateways/agent-gateway-overview ; https://docs.cloud.google.com/gemini-enterprise-agent-platform/release-notes ; https://cloud.google.com/products/gemini-enterprise-agent-platform/pricing
- decides: area B can run without a Gemini Enterprise licence via Agent Runtime (GA). Budget is small but unconfirmed.
- Open: region list for EU; exact SKU price.

## 2. How to create
- Answer (gcloud): write YAML, import it, then add an IAP authz extension and authz policy. Terraform: `google_network_services_agent_gateway`, `google_network_services_authz_extension`, `google_network_security_authz_policy`.
- Verified codelab commands (the codelab uses the `alpha` track; the Workspace guide uses `beta`; check `--help`):
  - `gcloud alpha network-services agent-gateways import agent-gateway --source=agent-gateway.yaml --location=${REGION}`
  - YAML keys: `name`, `protocols: [MCP]`, `googleManaged.governedAccessPath: AGENT_TO_ANYWHERE`, `registries: ["//agentregistry.googleapis.com/projects/${PROJECT_ID}/locations/${REGION}"]`, optional `networkConfig` (egress networkAttachment, dnsPeeringConfig).
  - `gcloud beta service-extensions authz-extensions import agent-gateway-iap-authz --source=iap-authz-extension.yaml --location=${REGION} --project=${PROJECT_ID}` with YAML `name`, `service: iap.googleapis.com`, `failOpen: true`, `timeout: 1s`.
  - Authz policy via REST POST `networksecurity.googleapis.com/v1alpha1/.../authzPolicies?authz_policy_id=...` with `"policyProfile": "REQUEST_AUTHZ"`, `"action": "CUSTOM"`, gateway as target, extension as `customProvider.authzExtension`.
  - Describe: `gcloud network-services agent-gateways describe NAME --location=REGION`.
- Prerequisites: "Enable the following minimum required APIs": Compute Engine, Network Security, Network Services, IAM, Identity-Aware Proxy, Agent Registry. Optional: Model Armor, Cloud DNS, Certificate Manager, Vertex AI, Discovery Engine, Agent Identity. Permission `networkservices.agentGateways.create` plus network security and Model Armor listing permissions (predefined role names not captured).
- Behaviour: "Traffic is blocked by default until an IAM policy grants `iap.resources.egressViaIAP` to the agent identity." Authz extension/policy has DRY_RUN then ENFORCED.
- Runtime binding: `agent_gateway_config` in `google_vertex_ai_reasoning_engine` (google-beta); "The backend enforces `identity_type = "AGENT_IDENTITY"`"; gateway cannot bind to reasoning engines created before 2026-04-29; essential endpoints (`aiplatform.googleapis.com`, `logging.googleapis.com`) must be allowlisted first or "all agent invocations will fail with a `498` error"; changing a binding archives existing revisions.
- URLs: https://docs.cloud.google.com/gemini-enterprise-agent-platform/govern/gateways/set-up-agent-gateway ; https://docs.cloud.google.com/gemini-enterprise-agent-platform/scale/runtime/agent-gateway-runtime-deploy ; https://codelabs.developers.google.com/cloudnet-agent-gateway ; https://github.com/grandintegrator/agent-gateway-quickstart (third-party sample)
- decides: gateway creation is scriptable; needs a deployed ADK agent with Agent Identity (agent deploys carry the X7/X10 suspension risk).
- Open: single-command creation without YAML not found; IAP authz policy create has no gcloud command in the codelab (REST).

## 3. Tool authorisation via Agent Registry
- Quotes: "Access rules that link an agent's identity to approved tools and endpoints in Agent Registry." "By default, all connections are blocked unless an explicit IAM policy grants access." Codelab: "Requests are _denied_ for any unregistered sources or destinations." Grant is `roles/iap.egressor` on the registry resource, e.g. `gcloud beta iap web set-iam-policy POLICY.json --resource-type=agent-registry --region=${REGION}`; per-MCP-server grants in the cybersecurity codelab use a helper script and optional CEL condition on `iap.googleapis.com/mcp.tool.isReadOnly`.
- Refused call: HTTP `403 Forbidden`; gateway log verdict `DENIED` (`DENIED (UNREGISTERED)` or `DENIED (no grant)` per the third-party quickstart); cybersecurity codelab: "403 PermissionDenied from IAP REQUEST_AUTHZ". No verbatim body documented. DRY_RUN logs but allows (`ALLOWED` with `(UNREGISTERED)`).
- Registry propagation delay about 4 minutes (quickstart, third party).
- URLs: https://codelabs.developers.google.com/agw-cuj-arun-egress-gmcp ; https://codelabs.developers.google.com/cloudnet-agent-gateway
- decides: T30 refusal signature is the 403 plus gateway log `DENIED`; the exact error text is not documented, so the script should assert on HTTP 403 and the log verdict, not on a message.
- Open: which log (IAP/network security audit) carries the verdict and its field name.

## 4. Inference path and identity
- Quotes: Gemini calls go through the gateway: codelab shows `generateContent` to `publishers/google/models/gemini-2.5-flash` with `IAP_AUTHZ` `ALLOWED`; runtime page: "immediately routes its outbound traffic, including platform calls ... through the gateway" and "if your agent requires LLM access, configure the gateway to allow this access". Quickstart (third party): "The model call is made as the agent's Agent Identity principal, not a service account", needing `roles/aiplatform.user`; principal form `principal://agents.global.org-ORG_ID.system.id.goog/resources/aiplatform/projects/PROJECT_NUMBER/locations/LOCATION/reasoningEngines/AGENT_ID`. Codelab principal set: `principalSet://agents.global.org-${ORG_ID}.system.id.goog/attribute.platformContainer/aiplatform/projects/${PROJ_NO}`.
- Analysis (inference, not a doc statement): the gateway governs egress; the credential on the model call stays the agent identity, which is a member of the project principalSet. So an IAM deny on that principalSet with an empty exception list would deny the call whether or not it goes through the gateway. No doc says the gateway substitutes its own identity for inference. This is UNVERIFIED and is the key risk for T31 as drafted.
- Restricting agents to the gateway only: docs say the gateway fronts all outbound traffic of a bound agent and is default-deny; no doc describes a way to make the gateway the only IAM path to Vertex.
- URLs: as in item 3; https://docs.cloud.google.com/gemini-enterprise-agent-platform/scale/runtime/agent-gateway-runtime-deploy
- decides: T31 as drafted cannot exist (see proposals).
- Open: does the gateway ever call Vertex on the agent's behalf under a service agent? Not documented.

## 5. Model Armor at the gateway
- Setup: enable Model Armor API; templates "in the same region as the gateway"; egress: grant the Service Extensions service agent `service-GATEWAY_PROJECT_NUMBER@gcp-sa-dep.iam.gserviceaccount.com` `roles/modelarmor.calloutUser` and `roles/serviceusage.serviceUsageConsumer` in the gateway project and `roles/modelarmor.user` in the template project. Ingress uses the Reasoning Engine service agent (`gcp-sa-aiplatform-re`).
- Config in the codelab: authz extension `service: modelarmor.${REGION}.rep.googleapis.com`, `metadata.model_armor_settings: '[{"request_template_id": "projects/P/locations/R/templates/T", "response_template_id": "projects/P/locations/R/templates/T2"}]'`, imported with `gcloud beta service-extensions authz-extensions import`, policy `"policyProfile": "CONTENT_AUTHZ"`. Console path also has a Model Armor toggle on the gateway.
- Scope: "MCP `tools/call` request and response are sanitized ... `tools/list`, `resources/*`, and `notifications/*` are allowed without sanitization." Templates can block-and-redact or inspect-and-log.
- Blocked: ingress "If blocked, the client receives an error." Egress "If blocked, the connection is terminated." Formats not documented. Findings appear on the Model Armor console page and in Security Command Center. Codelab extension used `failOpen: true` (a failure would let content through; use false for a test).
- Not documented: "session records a security event" (the T32 candidate wording) is not supported by the docs read.
- URLs: https://docs.cloud.google.com/model-armor/model-armor-agent-gateway-integration ; https://codelabs.developers.google.com/cloudnet-agent-gateway
- decides: T32 expected result must be "connection terminated / tool call fails" plus a Model Armor finding in the console/log, not a documented error string.
- Open: log filter for the finding; how the agent surfaces the termination.

## 6. VPC Service Controls
- Quotes: "Agent Gateway now enforces VPC Service Controls perimeter rules for agent communications." "VPC Service Controls is only supported for Agent Gateway deployments created after September 8, 2026." "Egress mode must be set to `ALL_TRAFFIC`"; private DNS zone mapping `*.googleapis.com` to `restricted.googleapis.com`; Shared VPC host project must be in the same perimeter. Gateway needs a connectivity template; an existing gateway without one must be deleted and recreated.
- Not found: documented ingress/egress rule examples for the gateway or agent principals; the codelab's rules are in notes/doc-verification.md.
- URLs: https://docs.cloud.google.com/gemini-enterprise-agent-platform/govern/gateways/set-up-vpc-connectivity ; release notes.
- decides: gateway tests T30-T32 can run without a perimeter (simplest); a perimeter adds a PSC attachment, DNS and egress mode (overlaps area C).
- Open: ingress rule form for the gateway.

## 7. Gemini Enterprise free trial
- Quotes (support.google.com/g/answer/16551831, billing for customers without an invoiced Cloud Billing account): "New users are eligible for a limited-time trial." "After the trial period ends, your account automatically converts to a paid subscription, billed on the first day of the following month." Cancelling: access continues "until the trial's end date" and the automatic conversion is deactivated. Seats: up to 5 on a monthly term at no cost; exceeding 5 or switching Monthly to Annual starts full billing immediately. Authorization hold "to verify your payment method" drops in 1 to 14 business days after cancelling; some accounts need a "refundable prepayment" (refund via "Request a refund"). Sign-up (support.google.com/g/answer/16547933) asks for a payment method and "the Country for your credit card".
- Length: 30 days only in marketing and secondary sources (cloud.google.com/gemini-enterprise/faq via search snippet: free 30-day trial of Business edition, self-serve; Standard, Plus, Frontline via Google Cloud sales). The billing page gives no day count.
- Features: no source lists Agent Gateway, connectors or agent builder as included in the Business trial. Docs at docs.cloud.google.com/gemini/enterprise/docs/licenses cover Standard, Plus, Pay-as-you-go and Frontline and do not mention Agent Gateway. Business edition docs are a separate Help Center.
- Payment method required: yes to enter one (hold or prepayment); card mandatory not stated explicitly.
- decides: the trial is not needed for T30-T32 (Agent Runtime path). It would only open Gemini Enterprise connectors (R7) and the gateway's Gemini Enterprise egress mode. Auto-converts unless cancelled; cancel the same day to keep the cost near zero.
- URLs: https://support.google.com/g/answer/16551831 ; https://support.google.com/g/answer/16547933 ; https://cloud.google.com/gemini-enterprise/faq ; https://docs.cloud.google.com/gemini/enterprise/docs/licenses
- Open: trial length in official text; whether a trial can be started inside the test organization; whether Business trial exposes Agent Gateway.

## 8. Agent Registry
- Stage: "Agent Registry is generally available (GA)" (2026-06-18; Public Preview was 2026-05-19). Known limit: Access Transparency/Approval not available for registry configurations.
- Register an MCP server: `gcloud alpha agent-registry services create legacy-dms --project=${PROJECT_ID} --location=${REGION} --display-name="Legacy DMS" --mcp-server-spec-type=tool-spec --mcp-server-spec-content=src/legacy-dms/toolspec.json --interfaces=url=https://dms.${DOMAIN_NAME}/mcp,protocolBinding=JSONRPC` (from the codelab; group is `alpha`, flags not checked against `--help`). List: `gcloud alpha agent-registry mcp-servers list --project=P --location=R`; `gcloud agent-registry endpoints list --location=R`. Runtime agents and Google MCP servers register automatically; custom MCP servers and Google API endpoints manually.
- URLs: https://codelabs.developers.google.com/cloudnet-agent-gateway ; release notes.
- Open: GA but gcloud group is still `alpha` in samples; run `gcloud agent-registry --help` read-only to confirm the track.

## Proposals

### T30 Tool authorisation (can exist; tier Enforced, as an API/gateway 403)
- Attempt: bound ADK agent (Agent Identity, egress gateway ENFORCED) invokes a registered MCP tool and an unregistered MCP endpoint (second Cloud Run MCP service, not registered).
- Paired control: registered tool call returns the tool result (same session, same agent).
- Expected: unregistered call HTTP 403, gateway log `IAP_AUTHZ` `DENIED` (UNREGISTERED); registered call succeeds. Mark exact body UNVERIFIED; assert 403 plus log verdict. Wait about 4 minutes after registry changes. Status: signature VERIFIED (codelab, 403/DENIED); command set VERIFIED from codelab but alpha/beta tracks need `--help` check; UNVERIFIED: log field name.

### T31 Gateway as only inference path (as drafted cannot exist)
- Why: the model call carries the agent identity, which is inside the principalSet the deny names; the gateway is an egress authoriser, not an identity swap (no doc says otherwise). A deny with an empty exception list would deny the "through the gateway" call too. UNVERIFIED but the doc basis points that way.
- Possible reformulation T31b (Enforced, two controls on one path): with the agent bound to the gateway, remove the registry grant for the Vertex endpoint: model call returns 403 from the gateway (`IAP_AUTHZ` `DENIED`) although IAM would allow it; with the grant, 200. Then add the IAM deny: call refused "due to an IAM deny policy" even with the gateway grant. Shows two independent layers, and that the gateway alone does not replace the deny. Status: UNVERIFIED (the gateway 403 on the Vertex endpoint is only shown as ALLOWED in the codelab; the DENIED case is inferred from default-deny).

### T32 Indirect prompt injection in tool response (can exist if gateway Model Armor works on egress; tier Enforced, API/gateway behaviour)
- Attempt: egress gateway with CONTENT_AUTHZ Model Armor extension (`failOpen: false`), response template in `INSPECT_AND_BLOCK` with prompt-injection filter; registered fixture MCP returns an injection sample in a `tools/call` result. Control: clean tool response passes.
- Expected: connection terminated / tool call fails for the agent and a Model Armor finding appears in the console/log; no documented error string. The draft's "session records a security event" is not supported by docs. Status: UNVERIFIED for observable error and log location; config VERIFIED from codelab.
- Caution: Model Armor ingress inline protection supports only ADK agents; egress covers MCP.

### Common prerequisites and risks
Agent deploys (suspension risk, 30-minute pacing); gateway and template in one region; cost small (gateway metering reported by a secondary source only). EU region support unverified, so use us-central1 as the docs do, unless the human requires EU.
