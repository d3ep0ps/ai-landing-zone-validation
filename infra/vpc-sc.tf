# VPC-SC. Two access policies, both with the organization as parent (API requirement):
# 1. An EMPTY org-level policy (no perimeters, no access levels). Scoped policies
#    "will not operate" without one (access-context-manager/docs/scoped-policies), and
#    the org had none on 2026-10-23. It enforces nothing on its own. Human decision.
# 2. A policy SCOPED to fldr-lz-validation that holds the test perimeter.
# Creating either needs accesscontextmanager.policies.create on the org.

module "vpc_sc_org_policy" {
  source        = "../vendor/fabric/modules/vpc-sc"
  access_policy = null
  access_policy_create = {
    parent = "organizations/${var.org_id}"
    title  = "lzv-org-access-policy-empty"
  }
}

locals {
  perimeter_resources = [
    "projects/${module.prj_runtime.number}",
    "projects/${module.prj_mcp.number}",
    "projects/${module.prj_data.number}",
  ]
  perimeter_config = {
    resources           = local.perimeter_resources
    restricted_services = var.vpc_sc_restricted_services
    # Stage 3b (tests/RUN-ORDER.md): operator ingress for T13 copy and T14 agent B.
    ingress_policies = concat(
      var.vpc_sc_operator_ingress ? ["$ingress_policies:operator"] : [],
      length(var.vpc_sc_agent_ingress_identities) > 0 ? ["$ingress_policies:agents"] : [], # v1.1 DC2 (T23)
    )
    # v2 E (T39b): optional egress rule for the pipeline identity's outside quota project.
    egress_policies = var.vpc_sc_pipeline_egress == null ? [] : ["$egress_policies:pipeline"]
  }
  vpc_sc_pipeline_egress_policy = var.vpc_sc_pipeline_egress == null ? {} : {
    pipeline = {
      title = "v2 T39b: pipeline identity may use the outside quota project"
      from = {
        identities = coalesce(var.vpc_sc_pipeline_egress.identities, ["user:${var.operator_email}"])
      }
      to = {
        operations = [{
          service_name         = var.vpc_sc_pipeline_egress.service_name
          method_selectors     = var.vpc_sc_pipeline_egress.method_selectors
          permission_selectors = var.vpc_sc_pipeline_egress.permission_selectors
        }]
        resources = ["projects/${var.vpc_sc_pipeline_egress.quota_project_number}"]
      }
    }
  }
}

module "vpc_sc" {
  source        = "../vendor/fabric/modules/vpc-sc"
  depends_on    = [module.vpc_sc_org_policy]
  access_policy = null
  access_policy_create = {
    parent = "organizations/${var.org_id}"
    title  = "lzv-folder-scoped-policy"
    scopes = [module.folder_root.id]
  }
  # Operator (laptop, any network) may call storage and aiplatform in the perimeter.
  # Egress is not opened: copying to a bucket outside the perimeter must still fail (T13 copy).
  ingress_policies = merge(local.vpc_sc_agent_ingress_policy, var.vpc_sc_operator_ingress ? {
    operator = {
      from = {
        access_levels = ["*"]
        identities    = concat(["user:${var.operator_email}"], var.vpc_sc_operator_ingress_extra_identities)
      }
      to = {
        operations = [
          { service_name = "storage.googleapis.com", method_selectors = ["*"] },
          { service_name = "aiplatform.googleapis.com", method_selectors = ["*"] },
        ]
        resources = ["*"]
      }
    }
  } : {})
  egress_policies = local.vpc_sc_pipeline_egress_policy
  perimeters = {
    lzv_ai = {
      description               = "LZ validation perimeter: runtime, mcp, data"
      use_explicit_dry_run_spec = true
      spec                      = local.perimeter_config
      status                    = var.vpc_sc_enforced ? local.perimeter_config : null
    }
  }
}
