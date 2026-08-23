#!/bin/bash
# ================================================================================
# FILE: destroy.sh
# ================================================================================
#
# Purpose:
#   Controlled teardown of the OpenClaw workstation.
#
# Teardown Order:
#   1. Destroy the OpenClaw host (03-openclaw).
#   2. Delete every openclaw-image custom image.
#   3. Destroy core infrastructure (01-core).
#
# ------------------------------------------------------------------------------
# WHY THIS SCRIPT RESOLVES THINGS FROM THE API AND NOT FROM TERRAFORM OUTPUTS
# ------------------------------------------------------------------------------
# Terraform destroys OUTPUTS BEFORE RESOURCES. A destroy that fails partway
# therefore strips the very outputs a retry would need to finish the job, and
# every subsequent run fails in the same place for a different reason than the
# first one did. That exact trap cost a full debugging session on
# oci-resume-app.
#
# So: image discovery here goes through the OCI API, keyed on the display name,
# and never through `terraform output`. Every CLI call also passes --region
# explicitly, because this project deploys to a region that is usually NOT the
# one in ~/.oci/config, and a region-blind call silently looks in the wrong
# place and reports finding nothing.
# ================================================================================

set -euo pipefail


# ================================================================================
# SECTION: Configuration
# ================================================================================

source ./genai-config.sh

export TF_VAR_region="${OCI_REGION}"
# Renders GENAI_MODELS to JSON and exports TF_VAR_models +
# TF_VAR_primary_alias. Terraform parses a complex TF_VAR_ as JSON, so the
# shell array crosses into HCL as a real list of objects.
genai_export_tf_vars

# Must match whatever apply.sh used, or 01-core will plan to create the email
# resources it is being asked to destroy.
export TF_VAR_email_sender="${TF_VAR_email_sender:-}"

TENANCY_OCID=$(awk -F'=' '/^tenancy[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' ~/.oci/config)
export TF_VAR_tenancy_ocid="${TENANCY_OCID}"

if [ -z "${OCI_COMPARTMENT_ID:-}" ]; then
  OCI_COMPARTMENT_ID="${TENANCY_OCID}"
fi
export TF_VAR_compartment_ocid="${OCI_COMPARTMENT_ID}"

# Tenancy-level IAM deletes are home-region-only, exactly like the creates.
HOME_REGION=$(oci iam region-subscription list \
  --tenancy-id "${TENANCY_OCID}" \
  --query 'data[?"is-home-region"]."region-name" | [0]' \
  --raw-output 2>/dev/null || echo "")

if [ -z "${HOME_REGION}" ] || [ "${HOME_REGION}" = "null" ]; then
  echo "ERROR: Could not determine the tenancy home region — IAM teardown would fail."
  exit 1
fi
export TF_VAR_home_region="${HOME_REGION}"

echo "NOTE: Region      - ${OCI_REGION}"
echo "NOTE: Home region - ${HOME_REGION}"


# ================================================================================
# PHASE 1: Destroy the OpenClaw Host
# ================================================================================

echo "NOTE: Destroying the OpenClaw host..."

cd 03-openclaw || { echo "ERROR: Directory 03-openclaw not found"; exit 1; }

terraform init
terraform destroy -auto-approve

cd ..


# ================================================================================
# PHASE 2: Delete the Custom Images
# ================================================================================
#
# Packer creates these outside Terraform, so Terraform will not remove them.
# Left behind they accrue storage charges and the next build stacks another
# image on top.
#
# Failures here are reported loudly rather than swallowed: a silent "|| true"
# on a delete is how a teardown reports success while leaving billable
# resources running.
#
# ================================================================================

echo "NOTE: Deleting openclaw-image custom images..."

IMAGE_IDS=$(oci compute image list \
  --compartment-id "${OCI_COMPARTMENT_ID}" \
  --region "${OCI_REGION}" \
  --lifecycle-state "AVAILABLE" \
  --all \
  --raw-output 2>/dev/null \
  | jq -r '.data[]? | select(."display-name" == "openclaw-image") | .id' || echo "")

if [ -n "${IMAGE_IDS}" ]; then
  FAILED=0
  for image_id in ${IMAGE_IDS}; do
    if oci compute image delete \
        --image-id "${image_id}" \
        --region "${OCI_REGION}" \
        --force \
        --wait-for-state DELETED \
        --max-wait-seconds 900 < /dev/null > /dev/null 2>&1; then
      echo "NOTE: Deleted image ${image_id}"
    else
      echo "ERROR: Failed to delete image ${image_id}"
      FAILED=1
    fi
  done
  if [ "${FAILED}" -ne 0 ]; then
    echo "ERROR: One or more images could not be deleted. They still cost money."
    echo "ERROR: List what is left with:"
    echo "ERROR:   oci compute image list --compartment-id ${OCI_COMPARTMENT_ID} \\"
    echo "ERROR:     --region ${OCI_REGION} --all"
    exit 1
  fi
else
  echo "NOTE: No openclaw-image found, skipping."
fi


# ================================================================================
# PHASE 3: Destroy Core Infrastructure
# ================================================================================

echo "NOTE: Destroying core infrastructure..."

cd 01-core || { echo "ERROR: Directory 01-core not found"; exit 1; }

terraform init
terraform destroy -auto-approve

cd ..


# ================================================================================
# SECTION: Completion
# ================================================================================

echo ""
echo "================================================================================"
echo "  Teardown complete — nothing left running."
echo "================================================================================"
echo "  The openclaw-svc user, its API key and both policies are gone with 01-core."
echo "  No OCI Vault was used, so there is no 30-day pending-deletion hold to wait"
echo "  out before the next apply."
echo "================================================================================"
