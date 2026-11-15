# Provider pins copied from vendor/fabric/default-versions.tf (Fabric v59.2.0, commit be0d4b1).
terraform {
  required_version = ">= 1.12.2"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 8.6.0, < 9.0.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 8.6.0, < 9.0.0"
    }
  }
}

provider "google" {
  region                = var.region
  user_project_override = true
  billing_project       = var.quota_project
}

provider "google-beta" {
  region                = var.region
  user_project_override = true
  billing_project       = var.quota_project
}
