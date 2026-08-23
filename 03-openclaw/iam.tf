# ==============================================================================
# FILE: iam.tf — instance principal for the OpenClaw host
# ------------------------------------------------------------------------------
# This is what the AGENT uses: the OCI CLI on the desktop authenticates as the
# instance itself, with no key material anywhere on disk. It is deliberately
# separate from, and weaker than, the openclaw-svc user in 01-core that LiteLLM
# signs Gen AI calls with.
#
# The split matters. If the agent could reach Generative AI directly it could
# bypass the proxy, the master key and the model allowlist. It cannot: nothing
# here grants generative-ai-family.
#
# TWO OCI GOTCHAS BAKED INTO THIS FILE
#
#   1. Everything here is provider = oci.home. Dynamic groups and policies are
#      tenancy-level; writing them against a non-home region returns
#      403-NotAllowed with no hint that the region is the problem.
#
#   2. The matching rule keys off instance.compartment.id, NOT
#      resource.type = 'instance'. The latter reads correctly and silently
#      matches nothing, producing an instance principal that authenticates fine
#      and is authorised for nothing — 404s on every call, forever.
#
# And a third, at runtime rather than apply time: an instance caches its
# dynamic-group membership in the principal token it fetches at boot. Changing
# the dynamic group after an instance is running has no effect on it until the
# instance is restarted.
# ==============================================================================

# ==============================================================================
# SECTION: Dynamic Group
# ==============================================================================

resource "oci_identity_dynamic_group" "openclaw" {
  provider       = oci.home
  compartment_id = var.tenancy_ocid
  name           = "openclaw-dg"
  description    = "OpenClaw workstation instances — grants the desktop an instance principal"

  # Scoped to the compartment rather than a single instance OCID so a rebuilt
  # host is covered without editing IAM.
  matching_rule = "ALL {instance.compartment.id = '${var.compartment_ocid}'}"
}

# ==============================================================================
# SECTION: Policy
# ------------------------------------------------------------------------------
# Read-only on the compartment so the agent can explore the tenancy and answer
# questions about it, plus the Usage API for cost reporting — the counterpart of
# the Cost Explorer grant on the AWS side.
#
# Usage reporting is a TENANCY-level read: scoping it to the compartment
# returns an empty result set rather than an error, which reads as "this
# tenancy has no spend" instead of "you asked in the wrong place".
# ==============================================================================

resource "oci_identity_policy" "openclaw_instance" {
  provider       = oci.home
  compartment_id = var.tenancy_ocid
  name           = "openclaw-instance-policy"
  description    = "Read access and usage reporting for the OpenClaw workstation"

  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.openclaw.name} to read all-resources in compartment id ${var.compartment_ocid}",
    "Allow dynamic-group ${oci_identity_dynamic_group.openclaw.name} to read usage-report in tenancy",
  ]
}
