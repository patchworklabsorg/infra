terraform {
  required_version = ">= 1.7.0"

  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.13"
    }
  }

  backend "gcs" {
    bucket = "pwl-tfstate"
    prefix = "github"
  }
}

# Auth: set GITHUB_TOKEN in the environment. Never put a token in a file.
# Example: export GITHUB_TOKEN="$(gh auth token)"
provider "github" {
  owner = "patchworklabsorg"
}
