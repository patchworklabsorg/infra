terraform {
  required_version = ">= 1.7"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.70"
    }
  }

  backend "gcs" {
    bucket = "pwl-tfstate"
    prefix = "proxmox"
  }
}
