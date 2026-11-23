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

  # State in Garage on the Mac Pro host, outside the lab (ADR 0006, ADR 0010). Run via scripts/tf.sh.
  backend "s3" {
    bucket                   = "tfstate"
    key                      = "talos/terraform.tfstate"
    region                   = "garage"
    endpoints                = { s3 = "https://s3.lab.macpro:3900" }
    profile                  = "tfstate"
    shared_credentials_files = ["../../.cache/garage/credentials"] # relative to the stack: always run with -chdir
    use_path_style           = true
    # Garage ignores If-None-Match, so the S3 lockfile wouldn't lock: scripts/tf.sh takes a local flock instead
    use_lockfile                = false
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
  }
}
