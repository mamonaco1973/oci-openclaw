# ==============================================================================
# FILE: openclaw.pkr.hcl
# ------------------------------------------------------------------------------
# Builds a self-contained OCI custom image from Canonical Ubuntu 24.04 with:
#   - LXQt desktop + XRDP
#   - Google Chrome
#   - Cloud CLIs: OCI, AWS v2, Azure, Google Cloud SDK
#   - Dev tools: Git, Terraform, Packer, VS Code
#   - Node.js 22, pnpm, OpenClaw
#   - LiteLLM proxy in a Python venv
#   - systemd units for LiteLLM, the OpenClaw gateway and Xvfb
#
# compartment_ocid, availability_domain, base_image_ocid and subnet_ocid are
# resolved by apply.sh from the OCI CLI and 01-core outputs.
#
# The builder lands in pub-subnet-1 because Packer connects over SSH from the
# internet. Unlike the AWS build, there is no agent to install — the Oracle
# Cloud Agent is already present in the Canonical base image.
# ==============================================================================

packer {
  required_plugins {
    oracle = {
      source  = "github.com/hashicorp/oracle"
      version = "~> 1"
    }
  }
}

# ==============================================================================
# SECTION: Build-Time Variables
# ==============================================================================

variable "compartment_ocid" {
  description = "Compartment OCID for the temporary build instance and the resulting image"
  default     = ""
}

variable "availability_domain" {
  description = "Availability domain for the temporary build instance"
  default     = ""
}

variable "base_image_ocid" {
  description = "OCID of the Canonical Ubuntu 24.04 base image"
  default     = ""
}

variable "subnet_ocid" {
  description = "Public subnet OCID — the builder needs inbound SSH"
  default     = ""
}

variable "region" {
  description = "Region to build in. MUST be passed explicitly -- see the note on the source block."
  default     = ""
}

variable "shape" {
  description = "Build instance shape. E4.Flex is the shape proven across the OCI projects in this repo."
  default     = "VM.Standard.E4.Flex"
}

# ==============================================================================
# SECTION: Oracle-OCI Builder
# ------------------------------------------------------------------------------
# image_name is fixed rather than timestamped. OCI custom images are addressed
# by OCID, and apply.sh resolves the newest image carrying this display name,
# so repeated builds simply stack up and the latest wins — the equivalent of
# the "openclaw_ami*" most_recent filter on the AWS side.
# ==============================================================================

source "oracle-oci" "openclaw" {
  # WITHOUT THIS, PACKER BUILDS IN THE WRONG REGION.
  #
  # The oracle-oci plugin uses the OCI Go SDK, which takes its region from
  # ~/.oci/config. It does NOT read OCI_CLI_REGION -- that is an OCI *CLI*
  # variable and the plugin never looks at it. apply.sh resolves the
  # availability domain, subnet and base image in var.region, so if the
  # config file points somewhere else the launch goes to that other region
  # carrying identifiers that mean nothing there, and fails with a bare
  # 400 CannotParseRequest that names no field.
  #
  # Check the Request Endpoint in any failure: it names the region actually
  # used.
  region = var.region

  compartment_ocid    = var.compartment_ocid
  availability_domain = var.availability_domain
  base_image_ocid     = var.base_image_ocid
  image_name          = "openclaw-image"
  shape               = var.shape

  shape_config {
    ocpus         = 4
    memory_in_gbs = 16
  }

  create_vnic_details {
    subnet_id        = var.subnet_ocid
    assign_public_ip = true
  }

  disk_size    = 64
  ssh_username = "ubuntu"
}

# ==============================================================================
# SECTION: Build Provisioners
# ==============================================================================

build {
  sources = ["source.oracle-oci.openclaw"]

  # Upload systemd unit files and the launcher icon.
  provisioner "file" {
    source      = "./files/litellm.service"
    destination = "/tmp/litellm.service"
  }

  provisioner "file" {
    source      = "./files/openclaw-gateway.service"
    destination = "/tmp/openclaw-gateway.service"
  }

  provisioner "file" {
    source      = "./files/openclaw.png"
    destination = "/tmp/openclaw.png"
  }

  provisioner "file" {
    source      = "./files/xvfb.service"
    destination = "/tmp/xvfb.service"
  }

  # Remove snap and install base packages.
  provisioner "shell" {
    script          = "./scripts/01-packages.sh"
    execute_command = "sudo -E bash '{{.Path}}'"
  }

  # Install LXQt desktop environment.
  provisioner "shell" {
    script          = "./scripts/02-desktop.sh"
    execute_command = "sudo -E bash '{{.Path}}'"
  }

  # Install XRDP and configure the LXQt session.
  provisioner "shell" {
    script          = "./scripts/03-xrdp.sh"
    execute_command = "sudo -E bash '{{.Path}}'"
  }

  # Install Google Chrome.
  provisioner "shell" {
    script          = "./scripts/04-chrome.sh"
    execute_command = "sudo -E bash '{{.Path}}'"
  }

  # Install cloud CLIs and dev tooling: git, OCI, AWS, HashiCorp, az, gcloud,
  # VS Code.
  provisioner "shell" {
    script          = "./scripts/05-tools.sh"
    execute_command = "sudo -E bash '{{.Path}}'"
  }

  # Create the openclaw Linux user with passwordless sudo.
  provisioner "shell" {
    script          = "./scripts/06-user.sh"
    execute_command = "sudo -E bash '{{.Path}}'"
  }

  # Install Node.js 22, pnpm, and openclaw globally.
  provisioner "shell" {
    script          = "./scripts/07-node.sh"
    execute_command = "sudo -E bash '{{.Path}}'"
  }

  # Create the Python venv and install the LiteLLM proxy.
  provisioner "shell" {
    script          = "./scripts/08-litellm.sh"
    execute_command = "sudo -E bash '{{.Path}}'"
  }

  # Install Python packages and system utilities for agent use.
  provisioner "shell" {
    script          = "./scripts/11-python-tools.sh"
    execute_command = "sudo -E bash '{{.Path}}'"
  }

  # Install OnlyOffice Desktop Editors.
  provisioner "shell" {
    script          = "./scripts/12-onlyoffice.sh"
    execute_command = "sudo -E bash '{{.Path}}'"
  }

  # Run the openclaw gateway briefly to stamp config metadata; register models.
  provisioner "shell" {
    script          = "./scripts/09-openclaw-init.sh"
    execute_command = "sudo -E bash '{{.Path}}'"
  }

  # Install and enable the systemd units.
  provisioner "shell" {
    script          = "./scripts/10-services.sh"
    execute_command = "sudo -E bash '{{.Path}}'"
  }
}
