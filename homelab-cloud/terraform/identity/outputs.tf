output "issuer" {
  description = "OIDC issuer of the lab realm (Argo CD's oidc.config issuer)."
  value       = "${var.keycloak_url}/realms/${keycloak_realm.lab.realm}"
}

output "argocd_client_id" {
  value = keycloak_openid_client.argocd.client_id
}

output "ci_robot_name" {
  description = "Full name of the CI push robot (the build pods' registry login)."
  value       = harbor_robot_account.ci_builder.full_name
}
