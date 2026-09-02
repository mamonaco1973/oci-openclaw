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
  # ssh_authorized_keys goes in metadata alongside user_data. compact()
  # drops the additional key when it is empty, so the instance never ends
  # up with a stray blank line in authorized_keys.
  metadata = {
    ssh_authorized_keys = join("\n", compact([
      trimspace(tls_private_key.ssh.public_key_openssh),
      trimspace(var.additional_ssh_public_key),
    ]))

    user_data = base64encode(templatefile("${path.module}/scripts/userdata.sh", {
      openclaw_password = local.openclaw_password

      region              = var.region
      tenancy_ocid        = var.tenancy_ocid
      compartment_ocid    = var.compartment_ocid
      litellm_user_ocid   = local.litellm_user_ocid
      litellm_fingerprint = local.litellm_fingerprint
      litellm_private_key = local.litellm_private_key

      # The raw list drives the LiteLLM model_list via a %{ for } loop in the
      # template. models_b64 is the same data pre-encoded for the OpenClaw
      # CLI. It is base64 so it can be dropped into the shell script as a
      # single opaque token: raw JSON interpolated into bash breaks the moment
      # a display name contains an apostrophe, and base64 output is
      # alphanumeric plus +/= so no quoting case exists at all.
      models = var.models

      # maxTokens is merged in only where the model declares one. OpenClaw
      # stamps every model it registers with maxTokens 8192, and sends that on
      # each request; OCI 400s anything above a model's own ceiling (4096 for
      # both Meta models), which surfaces in the UI as "request timed out".
      # Setting it here is what actually fixes it -- the ceiling has to be
      # lowered on the CLIENT. A max_tokens in the LiteLLM model_list is only
      # a default and loses to the value OpenClaw sends.
      models_b64 = base64encode(jsonencode([
        for m in var.models : merge(
          { id = m.alias, name = m.display },
          m.max_tokens == null ? {} : { maxTokens = m.max_tokens }
        )
      ]))
      primary_alias = var.primary_alias
    }))
  }

  # The dynamic group must exist before the instance boots: the principal token
  # is fetched once at startup and caches its group membership, so an instance
  # that comes up first stays unauthorised until it is restarted.
  depends_on = [oci_identity_policy.openclaw_instance]
}
