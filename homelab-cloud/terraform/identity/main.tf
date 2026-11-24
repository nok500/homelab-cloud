# The lab's identity config (ADR 0012), the IAM-as-Terraform half: Keycloak itself is GitOps
# (k8s/platform/keycloak), what lives inside it is this stack.

resource "keycloak_realm" "lab" {
  realm        = "lab"
  enabled      = true
  display_name = "homelab-cloud"
  ssl_required = "external"

  password_policy = "length(12) and notUsername"

  # Brute-force protection: lock an account for 1 min after 5 failures, doubling up to 15 min
  security_defenses {
    brute_force_detection {
      max_login_failures               = 5
      wait_increment_seconds           = 60
      max_failure_wait_seconds         = 900
      failure_reset_time_seconds       = 900
      permanent_lockout                = false
      minimum_quick_login_wait_seconds = 60
      quick_login_check_milli_seconds  = 1000
    }
  }
}

# ---- people and groups ----

resource "keycloak_group" "argocd_admins" {
  realm_id = keycloak_realm.lab.id
  name     = "argocd-admins" # Argo CD maps it to role:admin (k8s/bootstrap/argocd/values.yaml)
}

resource "keycloak_user" "labadmin" {
  realm_id       = keycloak_realm.lab.id
  username       = "labadmin"
  email          = "labadmin@lab.macpro"
  email_verified = true
  first_name     = "Lab"
  last_name      = "Admin"

  initial_password {
    value     = var.labadmin_password
    temporary = false
  }
}

resource "keycloak_group" "harbor_admins" {
  realm_id = keycloak_realm.lab.id
  name     = "harbor-admins" # Harbor's oidc_admin_group: system admins (ADR 0013)
}

resource "keycloak_group" "grafana_admins" {
  realm_id = keycloak_realm.lab.id
  name     = "grafana-admins" # Grafana's role_attribute_path maps it to Admin, everyone else Viewer (ADR 0014)
}

resource "keycloak_group" "argo_workflows_admins" {
  realm_id = keycloak_realm.lab.id
  name     = "argo-workflows-admins" # the Argo Workflows server maps it to its admin service account (ADR 0015)
}

resource "keycloak_user_groups" "labadmin" {
  realm_id = keycloak_realm.lab.id
  user_id  = keycloak_user.labadmin.id
  group_ids = [keycloak_group.argocd_admins.id, keycloak_group.harbor_admins.id, keycloak_group.grafana_admins.id,
  keycloak_group.argo_workflows_admins.id]
}

# ---- a `groups` claim for every client that asks for it ----

resource "keycloak_openid_client_scope" "groups" {
  realm_id               = keycloak_realm.lab.id
  name                   = "groups"
  description            = "Group membership as a `groups` claim"
  include_in_token_scope = true
}

resource "keycloak_openid_group_membership_protocol_mapper" "groups" {
  realm_id            = keycloak_realm.lab.id
  client_scope_id     = keycloak_openid_client_scope.groups.id
  name                = "groups"
  claim_name          = "groups"
  full_path           = false # "argocd-admins", not "/argocd-admins"
  add_to_id_token     = true
  add_to_access_token = true
  add_to_userinfo     = true
}

# ---- Argo CD ----

resource "keycloak_openid_client" "argocd" {
  realm_id  = keycloak_realm.lab.id
  client_id = "argocd"
  name      = "Argo CD"
  enabled   = true

  access_type                  = "CONFIDENTIAL"
  client_secret                = var.argocd_client_secret
  standard_flow_enabled        = true  # authorization code flow only
  direct_access_grants_enabled = false # no passwords sent to Argo CD
  implicit_flow_enabled        = false

  root_url                        = var.argocd_url
  base_url                        = "/applications"
  valid_redirect_uris             = ["${var.argocd_url}/auth/callback"]
  valid_post_logout_redirect_uris = ["${var.argocd_url}/applications"]
  web_origins                     = [var.argocd_url]
}

resource "keycloak_openid_client_default_scopes" "argocd" {
  realm_id  = keycloak_realm.lab.id
  client_id = keycloak_openid_client.argocd.id
  # Keycloak's built-in defaults for a new client, plus groups
  default_scopes = ["acr", "basic", "email", "profile", "roles", "web-origins", keycloak_openid_client_scope.groups.name]
}

# ---- Harbor (ADR 0013) ----

resource "keycloak_openid_client" "harbor" {
  realm_id  = keycloak_realm.lab.id
  client_id = "harbor"
  name      = "Harbor"
  enabled   = true

  access_type                  = "CONFIDENTIAL"
  client_secret                = var.harbor_client_secret
  standard_flow_enabled        = true
  direct_access_grants_enabled = false
  implicit_flow_enabled        = false

  root_url                        = var.harbor_url
  base_url                        = "/"
  valid_redirect_uris             = ["${var.harbor_url}/c/oidc/callback"]
  valid_post_logout_redirect_uris = ["${var.harbor_url}/"]
  web_origins                     = [var.harbor_url]
}

resource "keycloak_openid_client_default_scopes" "harbor" {
  realm_id       = keycloak_realm.lab.id
  client_id      = keycloak_openid_client.harbor.id
  default_scopes = ["acr", "basic", "email", "profile", "roles", "web-origins", keycloak_openid_client_scope.groups.name]
}

# ---- Grafana (ADR 0014) ----
resource "keycloak_openid_client" "grafana" {
  realm_id  = keycloak_realm.lab.id
  client_id = "grafana"
  name      = "Grafana"
  enabled   = true

  access_type                  = "CONFIDENTIAL"
  client_secret                = var.grafana_client_secret
  standard_flow_enabled        = true
  direct_access_grants_enabled = false
  implicit_flow_enabled        = false

  root_url                        = var.grafana_url
  base_url                        = "/"
  valid_redirect_uris             = ["${var.grafana_url}/login/generic_oauth"]
  valid_post_logout_redirect_uris = ["${var.grafana_url}/login"]
  web_origins                     = [var.grafana_url]
}

resource "keycloak_openid_client_default_scopes" "grafana" {
  realm_id       = keycloak_realm.lab.id
  client_id      = keycloak_openid_client.grafana.id
  default_scopes = ["acr", "basic", "email", "profile", "roles", "web-origins", keycloak_openid_client_scope.groups.name]
}

# ---- Argo Workflows (ADR 0015) ----
resource "keycloak_openid_client" "argo_workflows" {
  realm_id  = keycloak_realm.lab.id
  client_id = "argo-workflows"
  name      = "Argo Workflows"
  enabled   = true

  access_type                  = "CONFIDENTIAL"
  client_secret                = var.argo_workflows_client_secret
  standard_flow_enabled        = true
  direct_access_grants_enabled = false
  implicit_flow_enabled        = false

  root_url                        = var.argo_workflows_url
  base_url                        = "/"
  valid_redirect_uris             = ["${var.argo_workflows_url}/oauth2/callback"]
  valid_post_logout_redirect_uris = ["${var.argo_workflows_url}/"]
  web_origins                     = [var.argo_workflows_url]
}

resource "keycloak_openid_client_default_scopes" "argo_workflows" {
  realm_id       = keycloak_realm.lab.id
  client_id      = keycloak_openid_client.argo_workflows.id
  default_scopes = ["acr", "basic", "email", "profile", "roles", "web-origins", keycloak_openid_client_scope.groups.name]
}

# ---- Harbor: where CI pushes (ADR 0015) ----
# Project `ci`, private, every push scanned by Trivy. One project-level robot that can push and pull there and
# nowhere else; its secret is seeded (OpenBao secret/ci/harbor-robot), so a rebuilt Harbor gets the same one.
resource "harbor_project" "ci" {
  name                   = "ci"
  public                 = false
  vulnerability_scanning = true
}

resource "harbor_robot_account" "ci_builder" {
  name              = "builder" # full name robot$ci+builder
  description       = "CI builds (Argo Workflows + BuildKit) push here; ADR 0015"
  level             = "project"
  secret_wo         = var.harbor_ci_robot_secret
  secret_wo_version = 1 # bump to push a changed seed value
  permissions {
    kind      = "project"
    namespace = harbor_project.ci.name
    access {
      action   = "push"
      resource = "repository"
    }
    access {
      action   = "pull"
      resource = "repository"
    }
  }
}
