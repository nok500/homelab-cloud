resource "libvirt_pool" "lab" {
  name = "homelab"
  type = "dir"

  target = {
    path = var.pool_path
  }
}
