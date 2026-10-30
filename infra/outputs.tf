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
