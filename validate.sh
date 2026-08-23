#!/bin/bash
# ================================================================================
# validate.sh
#
# Post-deploy summary for the OpenClaw AI Agent Workstation.
# Reads Terraform outputs and prints everything needed to connect.
#
# Requirements:
#   - terraform CLI installed and authenticated
#   - Terraform state must exist (run apply.sh first)
# ================================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/03-openclaw"

source "${SCRIPT_DIR}/genai-config.sh"

# ================================================================================
# Read Terraform outputs
# ================================================================================

cd "${TF_DIR}"

INSTANCE_ID="$(terraform output -raw instance_id 2>/dev/null || echo '<not found>')"
PUBLIC_IP="$(terraform output -raw public_ip     2>/dev/null || echo '<not found>')"
PASSWORD="$(terraform output -raw openclaw_password 2>/dev/null || echo '<not found>')"

# ================================================================================
# Quick Start Output
# ================================================================================

echo ""
echo "============================================================================"
echo "OpenClaw AI Agent Workstation - Quick Start"
echo "============================================================================"
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
printf "%-28s %s\n" "NOTE: Primary model:" "${GENAI_PRIMARY_MODEL}"
echo ""
echo "----------------------------------------------------------------------------"
echo "First boot takes a couple of minutes after the instance reports RUNNING."
echo "Cloud-init sets the password and starts the services; RDP will refuse the"
echo "login until it has finished. Watch it with:"
echo ""
echo "  ssh ubuntu@${PUBLIC_IP} sudo tail -f /root/userdata.log"
echo ""
echo "----------------------------------------------------------------------------"
echo "VERIFY TOOL CALLING BEFORE TRUSTING THE DEPLOY"
echo "----------------------------------------------------------------------------"
echo "check_env.sh proved the models answer a chat call. It could not prove they"
echo "emit a TOOL CALL, and OpenClaw is useless without one. Nothing offline can"
echo "settle that -- run this on the desktop, against the running proxy:"
echo ""
echo '  curl -s http://localhost:4000/v1/chat/completions \'
echo '    -H "Authorization: Bearer sk-openclaw" \'
echo '    -H "Content-Type: application/json" \'
echo "    -d '{\"model\":\"llama-maverick\","
echo "         \"messages\":[{\"role\":\"user\",\"content\":\"What is the weather in Chicago?\"}],"
echo "         \"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"get_weather\","
echo "           \"parameters\":{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}}}}}]}'"
echo ""
echo "A tool_calls array in the response means the model works for agent use."
echo "Only a content string means it does not -- pick another model in"
echo "genai-config.sh and redeploy 03-openclaw."
echo "============================================================================"
echo ""
