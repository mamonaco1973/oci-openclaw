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

# ==============================================================================
# Wait for the instance to actually accept connections
# ==============================================================================
#
# Terraform returns as soon as the instance is RUNNING, which is well before it
# is usable: cloud-init still has to open the OCI host firewall (Ubuntu's image
# permits only SSH by default) and set the openclaw password. Printing the
# details at that point hands over an IP that refuses RDP and a password that
# is not yet set, which reads as a broken deploy rather than an early one.
#
# So poll both ports and only print once they answer.
#
# curl does the probing. telnet:// opens a raw TCP connection and nothing else,
# and --connect-timeout bounds the attempt natively — which matters because the
# OCI host firewall DROPS rather than rejects, so an unbounded connect hangs for
# minutes rather than failing fast.
#
# Chosen over the alternatives because it adds nothing: curl ships on both Linux
# and macOS by default, whereas `timeout` is coreutils-only (gtimeout on macOS)
# and `nc` differs across BSD/GNU/ncat builds. bash's own /dev/tcp needs no
# binary at all, but cannot bound a connect without backgrounding and killing
# it, which is ten lines to replace one.
#
# On timeout this warns and prints anyway — the details are exactly what you
# need to go and debug, so withholding them would be the wrong failure mode.
#
# ==============================================================================

wait_for_port() {
  local host="$1" port="$2" label="$3"
  local attempts=120 # 120 x 5s = 10 minutes
  local i

  for ((i = 1; i <= attempts; i++)); do
    if curl -s --connect-timeout 3 "telnet://${host}:${port}" </dev/null >/dev/null 2>&1; then
      echo "NOTE: ${label} is accepting connections."
      return 0
    fi
    sleep 5
  done

  echo "WARN: ${label} did not answer within 10 minutes."
  return 1
}

if [ "${PUBLIC_IP}" != "<not found>" ]; then
  echo ""
  echo "NOTE: Waiting for ${PUBLIC_IP} to finish booting..."
  wait_for_port "${PUBLIC_IP}" 22   "SSH (22)"  || true
  wait_for_port "${PUBLIC_IP}" 3389 "RDP (3389)" || true
fi

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
printf "%-28s %s\n" "NOTE: Debug Host:" "ssh -i 03-openclaw/keys/openclaw_ssh.pem ubuntu@${PUBLIC_IP}"
echo ""
