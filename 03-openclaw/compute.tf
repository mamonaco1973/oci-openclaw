# ==============================================================================
# FILE: compute.tf — NSG and the OpenClaw instance
# ------------------------------------------------------------------------------
# The host lands in the public subnet with a public IP and inbound 3389, which
# mirrors what aws-openclaw actually does.
#
# OCI evaluates the subnet security list AND the instance NSG, and traffic must
# be allowed by both. 01-core's pub-security-list already permits 3389; this
# NSG re-states it at the instance level so the rule travels with the host if
# it is ever moved to a stricter subnet.
# ==============================================================================

# ==============================================================================
# SECTION: Network Security Group
# ==============================================================================

resource "oci_core_network_security_group" "openclaw" {
  compartment_id = var.compartment_ocid
  vcn_id         = local.vcn_id
  display_name   = "openclaw-nsg"
}

resource "oci_core_network_security_group_security_rule" "rdp_ingress" {
  network_security_group_id = oci_core_network_security_group.openclaw.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  description               = "RDP to the OpenClaw desktop"

  tcp_options {
    destination_port_range {
      min = 3389
      max = 3389
    }
  }
}

# Egress must stay open: LiteLLM calls the regional Gen AI endpoint, and the
# desktop pulls packages and clones repositories.
resource "oci_core_network_security_group_security_rule" "all_egress" {
  network_security_group_id = oci_core_network_security_group.openclaw.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  description               = "Generative AI endpoint, package mirrors, git"
}

# ==============================================================================
# SECTION: Instance
# ------------------------------------------------------------------------------
# The gateway listens on loopback only; there is no inbound path to port 18789.
# Chrome on the desktop reaches it at http://localhost:18789 over the RDP
# session, which is the whole access model.
# ==============================================================================

resource "oci_core_instance" "openclaw" {
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  compartment_id      = var.compartment_ocid
  shape               = var.shape
  display_name        = "openclaw-host"

  shape_config {
    ocpus         = var.ocpus
    memory_in_gbs = var.memory_in_gbs
  }

  source_details {
    source_type             = "image"
    source_id               = var.openclaw_image_ocid
    boot_volume_size_in_gbs = var.boot_volume_size_in_gbs
  }

  create_vnic_details {
    subnet_id        = local.pub_subnet_ocid
    assign_public_ip = true
    nsg_ids          = [oci_core_network_security_group.openclaw.id]
  }

  # user_data must be base64 on OCI — unlike AWS, which accepts it raw.
  metadata = {
    user_data = base64encode(templatefile("${path.module}/scripts/userdata.sh", {
      openclaw_password = local.openclaw_password

      region              = var.region
      tenancy_ocid        = var.tenancy_ocid
      compartment_ocid    = var.compartment_ocid
      litellm_user_ocid   = local.litellm_user_ocid
      litellm_fingerprint = local.litellm_fingerprint
      litellm_private_key = local.litellm_private_key

      primary_model = var.primary_model
      fast_model    = var.fast_model
      oss_model     = var.oss_model
      grok_model    = var.grok_model

      smtp_host     = local.smtp_host
      smtp_username = local.smtp_username
      smtp_password = local.smtp_password
      smtp_from     = local.smtp_from
    }))
  }

  # The dynamic group must exist before the instance boots: the principal token
  # is fetched once at startup and caches its group membership, so an instance
  # that comes up first stays unauthorised until it is restarted.
  depends_on = [oci_identity_policy.openclaw_instance]
}
