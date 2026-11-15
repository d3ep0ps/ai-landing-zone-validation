# v2 D (T36, T37). ORGANIZATION-SCOPE items are flagged below; the human applies each alone.
#
# T36 (ORG SCOPE): custom constraint custom.lzvOrgTestBucketLabel on storage.googleapis.com/Bucket,
# condition "label lzv-org-test present", action ALLOW (a bucket without the label is refused).
#   t36_mode = "off"     nothing created
#   t36_mode = "dryrun"  constraint + org policy with dry_run_spec only (create allowed, audit entry
#                        dryRunResult=DENIED / liveResult=ALLOWED in cloudaudit.googleapis.com/policy)
#   t36_mode = "enforce" constraint + org policy with spec only (live)
# Exception: one project gets enforce = FALSE (same mode: dry_run_spec or spec). Default: the outside
# project. Reason: it is outside the perimeter and holds only T13's destination buckets, which are
# created before T36 is on; neither the Terraform state bucket (seed) nor the buckets of the tests
# that must be refused or accepted (data, mcp, runtime) are touched. data is the alternative
# (t36_exception_project = "data").
# method_types = CREATE only: existing buckets (Terraform-managed or not) are not blocked on update.
# While enforced, any bucket created without the label is refused, including Terraform-created ones
# (dc3 build bucket, the T36 exception aside): keep enable_dc3_build_bucket for another stage.
# Operator role: roles/orgpolicy.policyAdmin on the organization.
#
# Rollback (any of these, in this order):
#   terraform apply -var t36_mode=off      (removes policies first, then the constraint)
#   gcloud org-policies delete custom.lzvOrgTestBucketLabel --project=EXCEPTION_PROJECT_ID
#   gcloud org-policies delete custom.lzvOrgTestBucketLabel --organization=ORG_ID
#   gcloud org-policies delete-custom-constraint custom.lzvOrgTestBucketLabel --organization=ORG_ID
# (delete removes spec and dry run spec; tests/ scripts use the same commands.)

locals {
  t36_on         = var.t36_mode != "off"
  t36_constraint = "custom.lzvOrgTestBucketLabel"
  t36_exception_number = {
    outside = module.prj_outside.number
    data    = module.prj_data.number
  }[var.t36_exception_project]
}

resource "google_org_policy_custom_constraint" "t36" {
  count          = local.t36_on ? 1 : 0
  name           = local.t36_constraint
  parent         = "organizations/${var.org_id}"
  display_name   = "LZV T36: bucket must carry label lzv-org-test"
  description    = "Validation test T36. Remove after the test."
  action_type    = "ALLOW"
  condition      = "'lzv-org-test' in resource.labels" # UNVERIFIED CEL form; the API validates it at create
  method_types   = ["CREATE"]
  resource_types = ["storage.googleapis.com/Bucket"]
}

resource "google_org_policy_policy" "t36_org" {
  count  = local.t36_on ? 1 : 0
  name   = "organizations/${var.org_id}/policies/${local.t36_constraint}"
  parent = "organizations/${var.org_id}"

  dynamic "dry_run_spec" {
    for_each = var.t36_mode == "dryrun" ? [1] : []
    content {
      rules {
        enforce = "TRUE"
      }
    }
  }

  dynamic "spec" {
    for_each = var.t36_mode == "enforce" ? [1] : []
    content {
      rules {
        enforce = "TRUE"
      }
    }
  }

  depends_on = [google_org_policy_custom_constraint.t36]
}

# Exception project: enforce = FALSE in the same mode, so the dry-run log of that project stays quiet
# (whether that holds is UNVERIFIED, see notes/doc-verification-v2-D.md).
resource "google_org_policy_policy" "t36_exception" {
  count  = local.t36_on ? 1 : 0
  name   = "projects/${local.t36_exception_number}/policies/${local.t36_constraint}"
  parent = "projects/${local.t36_exception_number}"

  dynamic "dry_run_spec" {
    for_each = var.t36_mode == "dryrun" ? [1] : []
    content {
      rules {
        enforce = "FALSE"
      }
    }
  }

  dynamic "spec" {
    for_each = var.t36_mode == "enforce" ? [1] : []
    content {
      rules {
        enforce = "FALSE"
      }
    }
  }

  depends_on = [google_org_policy_policy.t36_org]
}

# T37: folder-attached IAM deny policy. Denied: every agent identity in the org trust domain.
# Exception: dc1_approved_agent_principals (the same list as the project deny policy of T18).
# Remove the project deny policy (enable_dc1_deny = false) in the same apply. Needs roles/iam.denyAdmin
# on the folder (or org). Propagation: 2 to 7 minutes or more.
resource "google_iam_deny_policy" "v2_folder_agents_predict" {
  count        = var.enable_v2_folder_deny ? 1 : 0
  provider     = google-beta
  parent       = urlencode("cloudresourcemanager.googleapis.com/${module.folder_root.id}")
  name         = "lzv-v2-deny-agent-predict"
  display_name = "T37: deny endpoints.predict to org agents except approved" # API max 63 chars

  rules {
    description = "Deny model inference to all agent identities in the organization trust domain; approved agents are exceptions."
    deny_rule {
      denied_principals    = ["principalSet://agents.global.org-${var.org_id}.system.id.goog/*"]
      exception_principals = var.dc1_approved_agent_principals
      denied_permissions   = ["aiplatform.googleapis.com/endpoints.predict"]
    }
  }
}

output "v2_t36_constraint" {
  description = "T36 custom constraint name (null when t36_mode = off)."
  value       = local.t36_on ? local.t36_constraint : null
}

output "v2_t36_exception_project" {
  description = "T36 exception project ID (null when t36_mode = off)."
  value       = local.t36_on ? { outside = module.prj_outside.project_id, data = module.prj_data.project_id }[var.t36_exception_project] : null
}

output "v2_folder_deny_policy_name" {
  description = "T37 folder deny policy name (null when disabled)."
  value       = try(google_iam_deny_policy.v2_folder_agents_predict[0].name, null)
}
