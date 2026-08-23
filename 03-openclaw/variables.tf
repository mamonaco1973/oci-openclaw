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
# truth. A complex TF_VAR_ is parsed as JSON, so the shell array crosses into
# HCL here as a real list of objects.
#
# Any length from 1 upward works. userdata.sh generates the LiteLLM model_list
# and the OpenClaw provider registration by iterating this list, so adding a
# model is a one-line edit in genai-config.sh and nothing else.
#
# The defaults exist only so a bare `terraform plan` or a `terraform destroy`
# is not broken by a missing required variable. Change models in
# genai-config.sh, never here.
# ==============================================================================

variable "models" {
  description = "Generative AI models to expose through LiteLLM and OpenClaw"

  type = list(object({
    alias   = string # what LiteLLM and OpenClaw call it
    model   = string # OCI Generative AI display name
    display = string # label in the OpenClaw model picker
  }))

  default = [
    {
      alias   = "llama-maverick"
      model   = "meta.llama-4-maverick-17b-128e-instruct-fp8"
      display = "Llama 4 Maverick (OCI)"
    },
    {
      alias   = "llama-scout"
      model   = "meta.llama-4-scout-17b-16e-instruct"
      display = "Llama 4 Scout (OCI)"
    },
    {
      alias   = "gpt-oss-120b"
      model   = "openai.gpt-oss-120b"
      display = "GPT-OSS 120B (OCI)"
    },
    {
      alias   = "grok-4"
      model   = "xai.grok-4.20-non-reasoning"
      display = "Grok 4 (OCI)"
    },
  ]

  validation {
    condition     = length(var.models) > 0
    error_message = "At least one model must be defined in genai-config.sh."
  }

  validation {
    condition     = length(distinct([for m in var.models : m.alias])) == length(var.models)
    error_message = "Model aliases must be unique — LiteLLM routes on the alias."
  }
}

variable "primary_alias" {
  description = "Alias from var.models that agents default to — should be tool-calling"
  type        = string
  default     = "llama-maverick"

  # Cross-variable validation (Terraform >= 1.9). A primary that is not in the
  # list produces an OpenClaw that starts fine and cannot run an agent, which
  # is a far worse failure than a plan-time error.
  validation {
    condition     = contains([for m in var.models : m.alias], var.primary_alias)
    error_message = "primary_alias must be one of the aliases in var.models."
  }
}

# ==============================================================================
# SECTION: SSH
# ------------------------------------------------------------------------------
# A key is always generated (see ssh.tf). This adds a second one so you can get
# in with a key you already hold, rather than the generated .pem — useful when
# debugging from a machine that does not have the Terraform state.
# ==============================================================================

variable "additional_ssh_public_key" {
  description = "Extra SSH public key to authorise on the instance, alongside the generated one"
  type        = string
  default     = ""
}
