output "folder_ids" {
  value = { root = module.folder_root.id, ai_prod = module.folder_ai_prod.id }
}

output "project_ids" {
  value = {
    runtime = module.prj_runtime.project_id
    mcp     = module.prj_mcp.project_id
    data    = module.prj_data.project_id
    outside = module.prj_outside.project_id
  }
}

output "project_numbers" {
  value = {
    runtime = module.prj_runtime.number
    mcp     = module.prj_mcp.number
    data    = module.prj_data.number
    outside = module.prj_outside.number
  }
}

output "org_policy_ids" {
  value = {
    root    = module.folder_root.organization_policies_ids
    ai_prod = module.folder_ai_prod.organization_policies_ids
  }
}

output "log_bucket_id" {
  value = module.log_bucket.id
}

# Inputs handed to external testers (T09, T13, T18). infra/agents adds the agent engine IDs.
output "tester_inputs" {
  description = "Perimeter, projects, CMEK key and billing projects for external test runs."
  value = {
    region             = var.region
    test_folder        = module.folder_root.id
    access_policy      = module.vpc_sc.id
    perimeter          = module.vpc_sc.perimeters["lzv_ai"].name
    perimeter_enforced = var.vpc_sc_enforced
    perimeter_projects = {
      runtime = module.prj_runtime.project_id
      mcp     = module.prj_mcp.project_id
      data    = module.prj_data.project_id
    }
    outside_project  = module.prj_outside.project_id
    outside_cmek_key = var.enable_outside_cmek ? module.outside_kms[0].keys["lzv-outside-key"].id : null
    billing_project = {
      outside_perimeter = var.quota_project
      inside_perimeter  = module.prj_runtime.project_id
    }
  }
}
