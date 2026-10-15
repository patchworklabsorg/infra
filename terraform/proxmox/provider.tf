# Authentication comes only from environment variables:
#   PROXMOX_VE_API_TOKEN  "<user>@<realm>!<token-id>=<secret>"
#   PROXMOX_VE_INSECURE   "true" while pve01 uses a self-signed certificate
# Never write the token in a file.
provider "proxmox" {
  endpoint = var.proxmox_endpoint
}
