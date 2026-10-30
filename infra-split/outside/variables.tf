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
  description = "Project ID outside the perimeter used as billing_project: the seed project (same value as quota_project in infra/). No default on purpose."
  type        = string
}
