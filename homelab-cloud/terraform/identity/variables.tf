variable "keycloak_url" {
  type    = string
  default = "https://sso.lab.macpro"
}

variable "root_ca_file" {
  description = "The lab root CA: sso.lab.macpro's certificate chains to it (ADR 0007)."
  type        = string
  default     = "../../k8s/platform/step-ca/config/root_ca.crt"
}

variable "argocd_url" {
  type    = string
  default = "https://argocd.lab.macpro"
}

# The three secrets below come from the SOPS OpenBao seed; scripts/identity.sh exports them as TF_VAR_*.
variable "admin_password" {
  description = "Master-realm bootstrap admin (seed keycloak-admin-password)."
  type        = string
  sensitive   = true
}

variable "labadmin_password" {
  description = "Password of the lab user `labadmin` (seed keycloak-labadmin-password)."
  type        = string
  sensitive   = true
}

variable "harbor_url" {
  type    = string
  default = "https://registry.lab.macpro"
}

variable "harbor_client_secret" {
  description = "OIDC client secret shared with Harbor (seed keycloak-harbor-client-secret, ADR 0013)."
  type        = string
  sensitive   = true
}

variable "argocd_client_secret" {
  description = "OIDC client secret shared with Argo CD (seed keycloak-argocd-client-secret)."
  type        = string
  sensitive   = true
}

variable "grafana_url" {
  type    = string
  default = "https://grafana.lab.macpro"
}

variable "grafana_client_secret" {
  description = "OIDC client secret shared with Grafana (seed keycloak-grafana-client-secret, ADR 0014)."
  type        = string
  sensitive   = true
}

variable "argo_workflows_url" {
  type    = string
  default = "https://workflows.lab.macpro"
}

variable "argo_workflows_client_secret" {
  description = "OIDC client secret shared with the Argo Workflows server (seed keycloak-argo-workflows-client-secret, ADR 0015)."
  type        = string
  sensitive   = true
}

variable "harbor_admin_password" {
  description = "Harbor's local admin (seed harbor-admin-password, ADR 0013): the provider manages the CI project with it."
  type        = string
  sensitive   = true
}

variable "harbor_ci_robot_secret" {
  description = "Secret of the CI push robot (seed harbor-ci-robot-secret, ADR 0015); the build pods log in with it."
  type        = string
  sensitive   = true
}
