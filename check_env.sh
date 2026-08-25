#!/bin/bash
# ==============================================================================
# check_env.sh - Environment Validation
# ------------------------------------------------------------------------------
# Pre-flight for apply.sh. Fails before anything is built rather than after.
#
# Checks, in order:
#   1. Required CLI tools are in PATH.
#   2. The OCI CLI can authenticate.
#   3. The tenancy home region can be resolved (tenancy-level IAM needs it).
#   4. Every model in genai-config.sh is listed as an on-demand CHAT model in
#      the target region.
#   5. Every model actually answers a chat call.
#
# Steps 4 and 5 are separate on purpose. A model can be ACTIVE, advertise CHAT,
# carry no retirement date and resolve to a valid OCID while still 404-ing on
# every call — availability is per-region and the control plane does not say so.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Required Commands
# ------------------------------------------------------------------------------
echo "NOTE: Validating required commands in PATH."

commands=("oci" "terraform" "jq" "packer")

for cmd in "${commands[@]}"; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: Required command not found: ${cmd}"
    exit 1
  fi
  echo "NOTE: Found required command: ${cmd}"
done

echo "NOTE: All required commands are available."

# ------------------------------------------------------------------------------
# OCI Authentication
# ------------------------------------------------------------------------------
if [ ! -f ~/.oci/config ]; then
  echo "ERROR: ~/.oci/config not found. Run 'oci setup config' first."
  exit 1
fi

TENANCY_OCID=$(awk -F'=' '/^tenancy[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' ~/.oci/config)
if [ -z "${TENANCY_OCID}" ]; then
  echo "ERROR: Could not read the tenancy OCID from ~/.oci/config."
  exit 1
fi

echo "NOTE: Checking OCI CLI connection."
if ! oci os ns get > /dev/null 2>&1; then
  echo "ERROR: Failed to connect to OCI. Check your ~/.oci/config."
  exit 1
fi
echo "NOTE: OCI CLI authentication successful."

if [ -z "${OCI_COMPARTMENT_ID:-}" ]; then
  echo "WARNING: OCI_COMPARTMENT_ID not set — falling back to the tenancy root."
fi

# ------------------------------------------------------------------------------
# Home Region
# ------------------------------------------------------------------------------
# Tenancy-level IAM — the dynamic group, the service user, their policies —
# can only be created in the home region. Resolving it here means apply.sh
# fails with an explanation instead of a bare 403-NotAllowed that never
# mentions regions.
# ------------------------------------------------------------------------------
echo "NOTE: Resolving tenancy home region..."

HOME_REGION=$(oci iam region-subscription list \
  --tenancy-id "${TENANCY_OCID}" \
  --query 'data[?"is-home-region"]."region-name" | [0]' \
  --raw-output 2>/dev/null || echo "")

if [ -z "${HOME_REGION}" ] || [ "${HOME_REGION}" = "null" ]; then
  echo "ERROR: Could not determine the tenancy home region. Check with:"
  echo "ERROR:   oci iam region-subscription list --tenancy-id ${TENANCY_OCID}"
  exit 1
fi
echo "NOTE: Home region - ${HOME_REGION}"

# ------------------------------------------------------------------------------
# Generative AI Models
# ------------------------------------------------------------------------------
source ./genai-config.sh

REGION="${OCI_REGION:-us-chicago-1}"
echo "NOTE: Checking region - ${REGION}"

# Read straight from GENAI_MODELS — any number of entries from 1 upward.
mapfile -t MODELS < <(genai_model_names)

if [ "${#MODELS[@]}" -eq 0 ]; then
  echo "ERROR: GENAI_MODELS in genai-config.sh is empty — nothing to deploy."
  exit 1
fi

# A primary that is not in the list yields an OpenClaw that starts fine and
# cannot run an agent. Terraform validates this too, but failing here means
# failing before anything is built.
if ! genai_model_for_alias "${GENAI_PRIMARY}" > /dev/null; then
  echo "ERROR: GENAI_PRIMARY is '${GENAI_PRIMARY}', which is not an alias in"
  echo "ERROR: GENAI_MODELS. Valid aliases:"
  genai_model_aliases | sed 's/^/ERROR:   /'
  exit 1
fi

echo "NOTE: Checking ${#MODELS[@]} model(s), primary ${GENAI_PRIMARY}"

for model in "${MODELS[@]}"; do
  MODEL_OCID=$(oci generative-ai model-collection list-models \
    --compartment-id "${TENANCY_OCID}" \
    --region "${REGION}" \
    --output json 2>/dev/null \
    | jq -r --arg m "${model}" '
        [ .data.items[]?
          | select(."display-name" == $m)
          | select(.capabilities[]? == "CHAT")
          | select(."time-on-demand-retired" == null)
          | .id
        ] | first // empty' 2>/dev/null || echo "")

  if [ -z "${MODEL_OCID}" ]; then
    echo "ERROR: Model '${model}' is not available for on-demand CHAT in"
    echo "ERROR: ${REGION}, or has been retired. List what is live with:"
    echo "ERROR:   oci generative-ai model-collection list-models \\"
    echo "ERROR:     --compartment-id ${TENANCY_OCID} --region ${REGION} \\"
    echo "ERROR:     --output json | jq -r '.data.items[]"
    echo "ERROR:     | select(.capabilities[]? == \"CHAT\")"
    echo "ERROR:     | select(.\"time-on-demand-retired\" == null)"
    echo "ERROR:     | .\"display-name\"'"
    echo "ERROR: Then update the model in genai-config.sh."
    exit 1
  fi

  echo "NOTE: Listed - ${model}"
done

# ------------------------------------------------------------------------------
# Prove the models actually answer
# ------------------------------------------------------------------------------
# Being listed proves nothing. In us-ashburn-1 every Meta Llama 4 and both
# OpenAI gpt-oss sizes are listed and NOT callable; in us-chicago-1 the same
# models answer in ~0.1s. Same catalog entry, same OCID, different region.
#
# Best-effort: probe_genai.py needs a python carrying the oci SDK. If none is
# found the deploy continues with a warning rather than being blocked by a
# tooling gap on the workstation.
# ------------------------------------------------------------------------------
GENAI_PY=""
for candidate in \
    "$(command -v python3 || true)" \
    "$(head -1 "$(command -v oci || echo /nonexistent)" 2>/dev/null | sed 's/^#!//; s/ .*//')" \
    "${HOME}/lib/oracle-cli/bin/python"; do
  if [ -x "${candidate}" ] && "${candidate}" -c "import oci" 2>/dev/null; then
    GENAI_PY="${candidate}"
    break
  fi
done

if [ -z "${GENAI_PY}" ]; then
  echo "WARN: No python with the oci SDK found — skipping the on-demand chat probe."
  echo "WARN: Verify manually before trusting the deploy:  python3 probe_genai.py"
else
  for model in "${MODELS[@]}"; do
    if "${GENAI_PY}" probe_genai.py --region "${REGION}" --check "${model}"; then
      echo "NOTE: Answers on demand - ${model}"
    else
      echo "ERROR: '${model}' is listed but does NOT serve on-demand chat in ${REGION}."
      echo "ERROR: See what does work here:"
      echo "ERROR:   ${GENAI_PY} probe_genai.py --region ${REGION}"
      echo "ERROR: Then update the model in genai-config.sh."
      exit 1
    fi
  done
fi

# Chat is not tool calling, and OpenClaw needs tool calling. Nothing that can
# be checked from here settles that — see the note at the end of validate.sh.
echo "NOTE: Environment validation passed."
