# ==============================================================================
# FILE: variables.tf — core infrastructure inputs
# ==============================================================================

variable "compartment_ocid" {
  description = "OCID of the compartment all regional resources deploy into"
  type        = string
}

variable "tenancy_ocid" {
  description = "OCID of the root tenancy — IAM users, groups and policies live here"
  type        = string
}

variable "region" {
  description = "Region hosting the VCN and compute — must serve the Gen AI models in genai-config.sh"
  type        = string
  default     = "us-chicago-1"
}

variable "home_region" {
  description = "Tenancy home region — the only region that accepts tenancy-level IAM writes"
  type        = string
}

variable "vcn_name" {
  description = "Display name for the VCN"
  type        = string
  default     = "clawd-vcn"
}

# Leave empty to skip Email Delivery entirely. When set, OCI creates an
# approved sender for this address and SMTP credentials the instance uses to
# send mail — the OCI counterpart of the SES identity in aws-openclaw.
variable "email_sender" {
  description = "Address to register as an OCI Email Delivery approved sender (empty disables email)"
  type        = string
  default     = ""
}

# ==============================================================================
# SECTION: Service User Email
# ------------------------------------------------------------------------------
# Tenancies backed by Identity Domains (IDCS) reject CreateUser without a
# primary email:
#   400-IdcsConversionError ... "The primary email must be specified."
#     messageId: error.identity.user.primaryEmailNotSpecified
#
# openclaw-svc is a machine identity that never signs in and never receives
# mail, so this defaults to the reserved .invalid TLD (RFC 2606) — format-valid,
# guaranteed undeliverable, and impossible to confuse with a real mailbox.
#
# Override only if IDCS is configured to demand a resolvable domain, or if the
# address collides with an existing user in the tenancy.
# ==============================================================================

variable "svc_user_email" {
  description = "Primary email for the openclaw-svc machine user — required by Identity Domains"
  type        = string
  default     = "openclaw-svc@example.invalid"
}
