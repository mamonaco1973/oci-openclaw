# ==============================================================================
# FILE: variables.tf — OpenClaw host inputs
# ==============================================================================

# ==============================================================================
# SECTION: Identity and Region
# ==============================================================================

variable "compartment_ocid" {
  description = "OCID of the compartment the instance deploys into"
  type        = string
}

variable "tenancy_ocid" {
  description = "OCID of the root tenancy — dynamic groups can only live here"
  type        = string
}

variable "region" {
  description = "Region hosting the instance — must match 01-core"
  type        = string
  default     = "us-chicago-1"
}

variable "home_region" {
  description = "Tenancy home region — the only region accepting tenancy-level IAM writes"
  type        = string
}

# ==============================================================================
# SECTION: Instance
# ==============================================================================

variable "openclaw_image_ocid" {
  description = "OCID of the openclaw-image custom image built by 02-packer"
  type        = string

  # Defaults to empty so `terraform destroy` never fails on a missing
  # required variable. apply.sh always supplies the real OCID; a destroy
  # does not need one, and demanding it there is how a teardown ends up
  # wedged. apply.sh aborts before Terraform if the image cannot be found.
  default = ""
}

variable "shape" {
  description = "Instance shape. E4.Flex is the shape proven across the OCI projects in this repo."
  type        = string
  default     = "VM.Standard.E4.Flex"
}

# An OCI OCPU is a full physical core — two vCPUs. 4 OCPUs is therefore 8 vCPUs,
# comfortably above the 4 vCPUs the t3.xlarge on the AWS side provides.
variable "ocpus" {
  description = "OCPU count for the flex shape"
  type        = number
  default     = 4
}

variable "memory_in_gbs" {
  description = "Memory for the flex shape"
  type        = number
  default     = 16
}

variable "boot_volume_size_in_gbs" {
  description = "Boot volume size — the image is built at 64 GB and expands on first boot"
  type        = number
  default     = 128
}

# ==============================================================================
# SECTION: Generative AI Models
# ------------------------------------------------------------------------------
# Supplied by apply.sh from genai-config.sh, which is the single source of
# truth. Defaults here only exist so a bare `terraform apply` is not broken;
# change models in genai-config.sh, not here.
# ==============================================================================

variable "primary_model" {
  description = "Tool-calling model OpenClaw drives agents with"
  type        = string
  default     = "meta.llama-4-maverick-17b-128e-instruct-fp8"
}

variable "fast_model" {
  description = "Lower-latency alternate model"
  type        = string
  default     = "meta.llama-4-scout-17b-16e-instruct"
}

variable "oss_model" {
  description = "Open-weight fallback model (chat, not tool calling)"
  type        = string
  default     = "openai.gpt-oss-120b"
}

variable "grok_model" {
  description = "Alternate vendor model"
  type        = string
  default     = "xai.grok-4.20-non-reasoning"
}
