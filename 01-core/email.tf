# ==============================================================================
# FILE: email.tf — OCI Email Delivery (optional)
# ------------------------------------------------------------------------------
# The counterpart of ses.tf in aws-openclaw. Registers an approved sender and
# issues SMTP credentials the desktop uses through msmtp, so the agent can send
# mail with the ordinary `mail` command.
#
# Set var.email_sender to enable. Left empty, every resource here is count = 0
# and the instance simply boots without mail configured — userdata.sh checks
# for an empty SMTP host and skips the whole block.
#
# POST-DEPLOY STEP, same as SES: OCI creates the approved sender in a PENDING
# state and emails a verification link to the address. Mail is rejected until
# somebody clicks it. Terraform reports success either way.
#
# SMTP credentials are tenancy-level and therefore home-region; the approved
# sender is regional. Note the split providers below.
# ==============================================================================

resource "oci_email_sender" "openclaw" {
  count          = var.email_sender == "" ? 0 : 1
  compartment_id = var.compartment_ocid
  email_address  = var.email_sender
}

resource "oci_identity_smtp_credential" "openclaw" {
  count       = var.email_sender == "" ? 0 : 1
  provider    = oci.home
  user_id     = oci_identity_user.openclaw_svc.id
  description = "OpenClaw outbound email via OCI Email Delivery"
}
