# ==============================================================================
# FILE: main.tf
# ------------------------------------------------------------------------------
# Providers, remote state and data sources for the OpenClaw host.
#
# Same two-provider split as 01-core: regional resources on the default
# provider, tenancy-level IAM (the dynamic group and its policy) on oci.home.
#
# 01-core is read through terraform_remote_state rather than by shelling out to
# `terraform output`, so the LiteLLM private key never crosses a shell boundary
# and never lands in a process listing.
# ==============================================================================

terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "oci" {
  region = var.region
}

provider "oci" {
  alias  = "home"
  region = var.home_region
}

provider "random" {}

# ==============================================================================
# SECTION: Remote State — 01-core
# ==============================================================================

data "terraform_remote_state" "core" {
  backend = "local"
  config = {
    path = "../01-core/terraform.tfstate"
  }
}

locals {
  pub_subnet_ocid = data.terraform_remote_state.core.outputs.pub_subnet_1_ocid
  vcn_id          = data.terraform_remote_state.core.outputs.vcn_id

  litellm_user_ocid   = data.terraform_remote_state.core.outputs.litellm_user_ocid
  litellm_fingerprint = data.terraform_remote_state.core.outputs.litellm_fingerprint
  litellm_private_key = data.terraform_remote_state.core.outputs.litellm_private_key

  smtp_host     = data.terraform_remote_state.core.outputs.smtp_host
  smtp_username = data.terraform_remote_state.core.outputs.smtp_username
  smtp_password = data.terraform_remote_state.core.outputs.smtp_password
  smtp_from     = data.terraform_remote_state.core.outputs.smtp_from
}

# ==============================================================================
# SECTION: Availability Domain
# ==============================================================================

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.compartment_ocid
}
