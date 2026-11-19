config {
  call_module_type = "local"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

# The AWS ruleset is added in Phase 6, when terraform/aws/ gets real modules.
