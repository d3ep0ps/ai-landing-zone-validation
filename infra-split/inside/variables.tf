variable "main_state_path" {
  description = "Path to the state file of infra/ (read only, via terraform_remote_state)."
  type        = string
  default     = "../../infra/terraform.tfstate"
}

variable "region" {
  description = "Default region."
  type        = string
  default     = "europe-west1"
}

variable "quota_project" {
  description = "In-perimeter project ID used as billing_project: the data project (project_ids.data in the infra/ state). No default on purpose."
  type        = string
}
