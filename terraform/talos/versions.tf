terraform {
  required_version = ">= 1.15.0"

  required_providers {
    talos = {
      source  = "siderolabs/talos"
      version = "= 0.12.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "= 2.9.1"
    }
  }

  # Local state until Garage (S3) exists in Phase 3.
}
