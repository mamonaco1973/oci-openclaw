# ==============================================================================
# FILE: main.tf
# ------------------------------------------------------------------------------
# Provider configuration for the core OpenClaw infrastructure.
#
# TWO PROVIDERS, ON PURPOSE. OCI accepts CREATE/UPDATE/DELETE for tenancy-level
# IAM -- groups, users, policies, dynamic groups -- ONLY in the tenancy home
# region. Applying them against us-chicago-1 fails with 403-NotAllowed even
# with full admin rights, and the error text does not mention regions at all.
# Everything regional (VCN, subnets, gateways) uses the default provider;
# everything in identity.tf uses oci.home. apply.sh discovers the home region
# and exports it as TF_VAR_home_region.
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
  }
}

# Regional resources -- the region that actually serves the Gen AI models.
provider "oci" {
  region = var.region
}

# Tenancy-level IAM writes must land in the home region.
provider "oci" {
  alias  = "home"
  region = var.home_region
}
