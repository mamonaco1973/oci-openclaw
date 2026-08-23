#!/bin/bash
# ==============================================================================
# validate.sh
#
# Post-deploy summary. Reads Terraform outputs and prints the connection
# details, nothing more.
#
# Requirements:
#   - terraform CLI installed and authenticated
#   - Terraform state must exist (run apply.sh first)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/03-openclaw"

source "${SCRIPT_DIR}/genai-config.sh"

cd "${TF_DIR}"

INSTANCE_ID="$(terraform output -raw instance_id    2>/dev/null || echo '<not found>')"
PUBLIC_IP="$(terraform output -raw public_ip        2>/dev/null || echo '<not found>')"
PASSWORD="$(terraform output -raw openclaw_password 2>/dev/null || echo '<not found>')"

cd "${SCRIPT_DIR}"

echo ""
printf "%-28s %s\n" "NOTE: Instance OCID:" "${INSTANCE_ID}"
printf "%-28s %s\n" "NOTE: Public IP:"     "${PUBLIC_IP}"
printf "%-28s %s\n" "NOTE: Region:"        "${OCI_REGION}"
echo ""
printf "%-28s %s\n" "NOTE: RDP Host:"      "${PUBLIC_IP}:3389"
printf "%-28s %s\n" "NOTE: Username:"      "openclaw"
printf "%-28s %s\n" "NOTE: Password:"      "${PASSWORD}"
echo ""
printf "%-28s %s\n" "NOTE: OpenClaw UI:"   "http://localhost:18789 (in Chrome, on the desktop)"
echo ""
echo "DEBUG:   ssh -i 03-openclaw/keys/openclaw_ssh.pem ubuntu@${PUBLIC_IP}"
echo ""
