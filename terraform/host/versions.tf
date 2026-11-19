terraform {
  required_version = ">= 1.15.0"

  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "= 0.9.9"
    }
    random = {
      source  = "hashicorp/random"
      version = "= 3.9.1"
    }
    local = {
      source  = "hashicorp/local"
      version = "= 2.9.1"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "= 4.4.2"
    }
  }

  # Local state until Garage (S3) exists in Phase 3, then migrated to the S3 backend.
}

provider "libvirt" {
  uri = var.libvirt_uri
}
