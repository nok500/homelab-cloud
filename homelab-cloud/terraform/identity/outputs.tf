output "issuer" {
  description = "OIDC issuer of the lab realm (Argo CD's oidc.config issuer)."
  value       = "${var.keycloak_url}/realms/${keycloak_realm.lab.realm}"
}

output "argocd_client_id" {
  value = keycloak_openid_client.argocd.client_id
}
