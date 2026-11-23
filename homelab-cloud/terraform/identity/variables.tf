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
