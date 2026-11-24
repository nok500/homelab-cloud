terraform {
  required_version = ">= 1.15.0"

  required_providers {
    keycloak = {
      source  = "keycloak/keycloak"
      version = "= 5.10.0" # 5.11.0 (2026-11-20) is under two weeks old
    }
    harbor = {
      source  = "goharbor/harbor"
      version = "= 3.12.5" # 2026-09-14; the CI project and its push robot (ADR 0015)
    }
  }

  # State in Garage on the Mac Pro host, like the other stacks (ADR 0010). Run via scripts/identity.sh,
  # which goes through scripts/tf.sh (lock + encrypted history) and passes the seeded credentials.
  backend "s3" {
    bucket                   = "tfstate"
    key                      = "identity/terraform.tfstate"
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

# Logs in as the master-realm bootstrap admin (seeded in OpenBao, ADR 0012) through admin-cli.
provider "keycloak" {
  url                 = var.keycloak_url
  realm               = "master"
  client_id           = "admin-cli"
  username            = "admin"
  password            = var.admin_password
  root_ca_certificate = file(var.root_ca_file)
}

# Harbor's API as its local admin (seed harbor-admin-password, ADR 0013): the CI project and robot (ADR 0015).
# insecure = false: verify TLS. The provider has no CA option, so it uses the system trust store, where the lab
# root is installed on voodoo (docs/bootstrap.md).
provider "harbor" {
  url      = var.harbor_url
  username = "admin"
  password = var.harbor_admin_password
  insecure = false
}
