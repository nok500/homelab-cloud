variable "cluster_name" {
  type    = string
  default = "macpro"
}

variable "talos_version" {
  description = "Talos release; must match the image built by scripts/fetch-images.sh."
  type        = string
  default     = "v1.14.6"
}

variable "kubernetes_version" {
  description = "Kubernetes version for a new cluster (upgrades go through talosctl upgrade-k8s)."
  type        = string
  default     = "1.37.2"
}

variable "talos_schematic_id" {
  description = "Image Factory schematic (qemu-guest-agent extension); same as scripts/fetch-images.sh."
  type        = string
  default     = "ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515"
}
