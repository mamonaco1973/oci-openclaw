# ==============================================================================
# FILE: outputs.tf — consumed by 02-packer (via apply.sh) and 03-openclaw
# ------------------------------------------------------------------------------
# The credential outputs are marked sensitive so they never print during an
# apply. 03-openclaw reads them through terraform_remote_state, not by shelling
# out, so they stay inside Terraform.
# ==============================================================================

# ==============================================================================
# SECTION: Networking
# ==============================================================================

output "vcn_id" {
  description = "OCID of the OpenClaw VCN"
  value       = oci_core_vcn.clawd_vcn.id
}

output "pub_subnet_1_ocid" {
  description = "Public subnet hosting the OpenClaw instance and the Packer builder"
  value       = oci_core_subnet.pub_subnet_1.id
}

output "vm_subnet_1_ocid" {
  description = "Private workload subnet (NAT egress)"
  value       = oci_core_subnet.vm_subnet_1.id
}

# ==============================================================================
# SECTION: LiteLLM Service Credentials
# ------------------------------------------------------------------------------
# The six values LiteLLM's OCI provider resolves from the environment. Passed
# to 03-openclaw, which writes them into /etc/litellm.env on the instance.
# ==============================================================================

output "litellm_user_ocid" {
  description = "OCID of the openclaw-svc user LiteLLM authenticates as"
  value       = oci_identity_user.openclaw_svc.id
}

output "litellm_fingerprint" {
  description = "Fingerprint OCI assigned to the uploaded API signing key"
  value       = oci_identity_api_key.openclaw_svc.fingerprint
}

output "litellm_private_key" {
  description = "PEM private key matching the uploaded API signing key"
  value       = tls_private_key.openclaw_svc.private_key_pem
  sensitive   = true
}

# ==============================================================================
# SECTION: Email Delivery
# ------------------------------------------------------------------------------
# Empty strings when var.email_sender is unset — userdata.sh treats an empty
# smtp_host as "email not configured" and skips msmtp entirely.
# ==============================================================================

output "smtp_host" {
  description = "OCI Email Delivery SMTP endpoint for the deployment region"
  value       = var.email_sender == "" ? "" : "smtp.email.${var.region}.oci.oraclecloud.com"
}

output "smtp_username" {
  description = "SMTP username issued with the credential"
  value       = var.email_sender == "" ? "" : oci_identity_smtp_credential.openclaw[0].username
  sensitive   = true
}

output "smtp_password" {
  description = "SMTP password — returned by OCI only at creation time"
  value       = var.email_sender == "" ? "" : oci_identity_smtp_credential.openclaw[0].password
  sensitive   = true
}

output "smtp_from" {
  description = "Approved sender address mail is sent from"
  value       = var.email_sender
}
