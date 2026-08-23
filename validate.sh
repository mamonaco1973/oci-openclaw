#!/bin/bash
# ==============================================================================
# validate.sh
#
# Post-deploy summary for the OpenClaw AI Agent Workstation.
# Reads Terraform outputs and prints everything needed to connect, plus the
# tool-calling check that nothing offline can perform.
#
# The model table and the sample curl are both generated from genai-config.sh,
# so they follow whatever is actually deployed.
#
# Requirements:
#   - terraform CLI installed and authenticated
#   - Terraform state must exist (run apply.sh first)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/03-openclaw"

source "${SCRIPT_DIR}/genai-config.sh"

# ==============================================================================
# Read Terraform outputs
# ==============================================================================

cd "${TF_DIR}"

INSTANCE_ID="$(terraform output -raw instance_id       2>/dev/null || echo '<not found>')"
PUBLIC_IP="$(terraform output -raw public_ip           2>/dev/null || echo '<not found>')"
PASSWORD="$(terraform output -raw openclaw_password    2>/dev/null || echo '<not found>')"

cd "${SCRIPT_DIR}"

# ==============================================================================
# Quick Start Output
# ==============================================================================

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
echo ""

# ==============================================================================
# Model table — driven by GENAI_MODELS, so it matches what was deployed
# ==============================================================================

echo "NOTE: Models configured (${#GENAI_MODELS[@]}):"
for entry in "${GENAI_MODELS[@]}"; do
  IFS='|' read -r alias model display <<< "${entry}"
  if [ "${alias}" = "${GENAI_PRIMARY}" ]; then
    printf "NOTE:   %-16s %-46s %s  <- primary\n" "${alias}" "${model}" "${display}"
  else
    printf "NOTE:   %-16s %-46s %s\n" "${alias}" "${model}" "${display}"
  fi
done
echo ""

echo "----------------------------------------------------------------------------"
echo "First boot takes a couple of minutes after the instance reports RUNNING."
echo "Cloud-init sets the password, writes the model config and starts the"
echo "services; RDP will refuse the login until it has finished. Watch it with:"
echo ""
echo "  ssh -i 03-openclaw/keys/openclaw_ssh.pem ubuntu@${PUBLIC_IP} \\"
echo "      sudo tail -f /root/userdata.log"
echo ""
echo "If the instance never got far enough to accept SSH, read the boot log from"
echo "the serial console instead. It needs no key and no working network, and"
echo "every NOTE: line userdata.sh prints goes there:"
echo ""
echo "  CH=\$(oci compute instance-console-history capture \\"
echo "        --region ${OCI_REGION} --instance-id ${INSTANCE_ID} \\"
echo "        --query data.id --raw-output)"
echo "  oci compute instance-console-history get-content \\"
echo "        --region ${OCI_REGION} --instance-console-history-id \$CH \\"
echo "        --file - --length 200000 | grep -E 'NOTE:|ERROR'"
echo ""

# ==============================================================================
# Tool-calling check
# ==============================================================================
#
# check_env.sh proved every model answers a chat call. It could NOT prove any
# of them emits a tool call, and OpenClaw is useless without one. There is no
# offline way to settle it, so this prints the request that does.
#
# Built with a quoted heredoc so the JSON survives verbatim; only the model
# alias is substituted.
# ==============================================================================

echo "----------------------------------------------------------------------------"
echo "VERIFY TOOL CALLING BEFORE TRUSTING THE DEPLOY"
echo "----------------------------------------------------------------------------"
echo "check_env.sh proved the models answer a chat call. It could not prove they"
echo "emit a TOOL CALL, and OpenClaw is useless without one. Run this on the"
echo "desktop, against the running proxy:"
echo ""

cat <<CURL
  curl -s http://localhost:4000/v1/chat/completions \\
    -H "Authorization: Bearer sk-openclaw" \\
    -H "Content-Type: application/json" \\
    -d '{
      "model": "${GENAI_PRIMARY}",
      "messages": [{"role":"user","content":"What is the weather in Chicago?"}],
      "tools": [{
        "type": "function",
        "function": {
          "name": "get_weather",
          "parameters": {
            "type": "object",
            "properties": {"city": {"type":"string"}}
          }
        }
      }]
    }' | jq .
CURL

echo ""
echo "A tool_calls array in the response means the model works for agent use."
echo "Only a content string means it does not -- change GENAI_PRIMARY in"
echo "genai-config.sh and re-apply 03-openclaw."
echo ""
echo "List what the proxy is actually serving:"
echo ""
echo "  curl -s http://localhost:4000/v1/models -H \"Authorization: Bearer sk-openclaw\" | jq -r '.data[].id'"
echo "============================================================================"
echo ""
