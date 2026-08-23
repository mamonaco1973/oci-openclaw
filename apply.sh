#!/bin/bash
# ==============================================================================
# FILE: apply.sh
# ==============================================================================
#
# Purpose:
#   Deploy the OpenClaw AI agent workstation on OCI.
#
# Deployment Flow:
#   1. Core infrastructure (Terraform)  — VCN, service user, API key, email.
#   2. Custom image (Packer)            — Ubuntu 24.04 + desktop + OpenClaw.
#   3. OpenClaw host (Terraform)        — instance, NSG, instance principal.
#   4. Post-deploy validation.
#
# Design Principles:
#   - Fail-fast via set -euo pipefail.
#   - Environment validated before anything is built.
#   - Model selection centralised in genai-config.sh — never inline here.
#
# Exit Codes:
#   0 = Success
#   1 = Validation failure or provisioning error
#
# ==============================================================================

set -euo pipefail


# ==============================================================================
# SECTION: Configuration
# ==============================================================================

# Models and the region that serves them. Sourced before check_env.sh so both
# scripts agree on what is being deployed.
source ./genai-config.sh

export TF_VAR_region="${OCI_REGION}"
# Renders GENAI_MODELS to JSON and exports TF_VAR_models +
# TF_VAR_primary_alias. Terraform parses a complex TF_VAR_ as JSON, so the
# shell array crosses into HCL as a real list of objects.
genai_export_tf_vars

# Optional: register an OCI Email Delivery approved sender so the agent can
# send mail. Leave unset and email is skipped entirely.
# export TF_VAR_email_sender="you@example.com"


# ==============================================================================
# SECTION: Environment Validation
# ==============================================================================

echo "NOTE: Running environment validation..."
./check_env.sh


# ==============================================================================
# SECTION: Identity Resolution
# ==============================================================================

TENANCY_OCID=$(awk -F'=' '/^tenancy[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' ~/.oci/config)
export TF_VAR_tenancy_ocid="${TENANCY_OCID}"

# Compartment defaults to the tenancy root when unset.
if [ -z "${OCI_COMPARTMENT_ID:-}" ]; then
  OCI_COMPARTMENT_ID="${TENANCY_OCID}"
fi
export TF_VAR_compartment_ocid="${OCI_COMPARTMENT_ID}"

# The home region is not cosmetic. OCI accepts tenancy-level IAM writes — the
# service user, its API key, the dynamic group and both policies — ONLY in the
# home region, and rejects them elsewhere with a 403 that says nothing about
# regions. Both Terraform modules take this as var.home_region and route those
# resources through a provider alias.
HOME_REGION=$(oci iam region-subscription list \
  --tenancy-id "${TENANCY_OCID}" \
  --query 'data[?"is-home-region"]."region-name" | [0]' \
  --raw-output 2>/dev/null || echo "")

if [ -z "${HOME_REGION}" ] || [ "${HOME_REGION}" = "null" ]; then
  echo "ERROR: Could not determine the tenancy home region."
  exit 1
fi
export TF_VAR_home_region="${HOME_REGION}"

echo "NOTE: Tenancy      - ${TENANCY_OCID}"
echo "NOTE: Compartment  - ${OCI_COMPARTMENT_ID}"
echo "NOTE: Region       - ${OCI_REGION}"
echo "NOTE: Home region  - ${HOME_REGION}"
echo "NOTE: Models       - $(genai_model_aliases | paste -sd, -)"
echo "NOTE: Primary      - ${GENAI_PRIMARY}"


# ==============================================================================
# PHASE 1: Core Infrastructure
# ==============================================================================

echo "NOTE: Building core infrastructure..."

cd 01-core || { echo "ERROR: Directory 01-core not found"; exit 1; }

terraform init
terraform apply -auto-approve

cd ..


# ==============================================================================
# PHASE 2: Build the OpenClaw Image (Packer)
# ==============================================================================
#
# Resolve the build inputs from the OCI CLI and 01-core before invoking Packer.
# The builder needs a public subnet: Packer connects to the temporary instance
# over SSH from the internet.
#
# ==============================================================================

echo "NOTE: Resolving Packer build parameters..."

SUBNET_OCID=$(cd 01-core && terraform output -raw pub_subnet_1_ocid)

AD=$(oci iam availability-domain list \
  --compartment-id "${OCI_COMPARTMENT_ID}" \
  --region "${OCI_REGION}" \
  --query 'data[0].name' \
  --raw-output)

BASE_IMAGE_OCID=$(oci compute image list \
  --compartment-id "${OCI_COMPARTMENT_ID}" \
  --region "${OCI_REGION}" \
  --operating-system "Canonical Ubuntu" \
  --operating-system-version "24.04" \
  --shape "VM.Standard.E4.Flex" \
  --lifecycle-state "AVAILABLE" \
  --sort-by TIMECREATED \
  --sort-order DESC \
  --query 'data[0].id' \
  --raw-output)

if [ -z "${BASE_IMAGE_OCID}" ] || [ "${BASE_IMAGE_OCID}" = "null" ]; then
  echo "ERROR: Could not resolve a Canonical Ubuntu 24.04 base image in ${OCI_REGION}."
  exit 1
fi

echo "NOTE: Availability domain : ${AD}"
echo "NOTE: Base image OCID     : ${BASE_IMAGE_OCID}"
echo "NOTE: Subnet OCID         : ${SUBNET_OCID}"

cd 02-packer || { echo "ERROR: Directory 02-packer not found"; exit 1; }

echo "NOTE: Building the OpenClaw image with Packer..."

packer init ./openclaw.pkr.hcl
packer build \
  -var "region=${OCI_REGION}" \
  -var "compartment_ocid=${OCI_COMPARTMENT_ID}" \
  -var "availability_domain=${AD}" \
  -var "base_image_ocid=${BASE_IMAGE_OCID}" \
  -var "subnet_ocid=${SUBNET_OCID}" \
  ./openclaw.pkr.hcl || {
    echo "ERROR: Packer build failed. Aborting."
    cd ..
    exit 1
  }

cd ..

# Resolve the image Packer just produced. Builds stack up under one display
# name, so take the newest — the equivalent of the AWS most_recent filter.
OPENCLAW_IMAGE_OCID=$(oci compute image list \
  --compartment-id "${OCI_COMPARTMENT_ID}" \
  --region "${OCI_REGION}" \
  --lifecycle-state "AVAILABLE" \
  --all \
  --raw-output 2>/dev/null \
  | jq -r '[.data[] | select(."display-name" == "openclaw-image")]
           | sort_by(."time-created") | last | .id')

if [ -z "${OPENCLAW_IMAGE_OCID}" ] || [ "${OPENCLAW_IMAGE_OCID}" = "null" ]; then
  echo "ERROR: Could not find openclaw-image after the Packer build."
  exit 1
fi

export TF_VAR_openclaw_image_ocid="${OPENCLAW_IMAGE_OCID}"
echo "NOTE: OpenClaw image OCID : ${OPENCLAW_IMAGE_OCID}"


# ==============================================================================
# PHASE 3: OpenClaw Host
# ==============================================================================

echo "NOTE: Building the OpenClaw host..."

cd 03-openclaw || { echo "ERROR: Directory 03-openclaw not found"; exit 1; }

terraform init
terraform apply -auto-approve

cd ..


# ==============================================================================
# SECTION: Post-Deployment Validation
# ==============================================================================

./validate.sh
