# ==============================================================================
# FILE: outputs.tf
# ------------------------------------------------------------------------------
# Read by validate.sh, connect.sh and get_password.sh.
# ==============================================================================

output "instance_id" {
  description = "OCID of the OpenClaw instance"
  value       = oci_core_instance.openclaw.id
}

output "public_ip" {
  description = "Public IP for RDP on port 3389"
  value       = oci_core_instance.openclaw.public_ip
}

output "private_ip" {
  description = "Private IP within the VCN"
  value       = oci_core_instance.openclaw.private_ip
}

output "openclaw_username" {
  description = "Linux and RDP username"
  value       = "openclaw"
}

# get_password.sh reads this with `terraform output -raw openclaw_password`.
output "openclaw_password" {
  description = "Password for the openclaw desktop user"
  value       = local.openclaw_password
  sensitive   = true
}

output "ssh_private_key_path" {
  description = "Generated SSH private key for shell access to the instance"
  value       = local_file.ssh_private_key.filename
}
