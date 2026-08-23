#!/bin/bash
# ==============================================================================
# connect.sh
# ------------------------------------------------------------------------------
# Prints the RDP connection details and, on Windows, launches mstsc directly.
#
# Access is straight RDP to a public IP on 3389 — the same thing aws-openclaw
# does in practice. There is no session-broker hop: OCI's managed Bastion is
# the SSM Session Manager equivalent, but it only forwards to instances in a
# PRIVATE subnet, and this host deliberately sits in a public one so the
# desktop is reachable without a tunnel.
#
# To move to a bastion topology, put the instance in vm-subnet-1 (which already
# exists, with NAT egress) and add an oci_bastion_bastion plus a port-forward
# session. The address plan in 01-core was cut with that in mind.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "${SCRIPT_DIR}/03-openclaw"

PUBLIC_IP=$(terraform output -raw public_ip 2>/dev/null || echo "")
USERNAME=$(terraform output -raw openclaw_username 2>/dev/null || echo "openclaw")
PASSWORD=$(terraform output -raw openclaw_password 2>/dev/null || echo "")

if [ -z "${PUBLIC_IP}" ]; then
  echo "ERROR: No public IP in state — run ./apply.sh first." >&2
  exit 1
fi

echo "NOTE: RDP host - ${PUBLIC_IP}:3389"
echo "NOTE: Username - ${USERNAME}"
echo "NOTE: Password - ${PASSWORD}"
echo ""
echo "NOTE: Once connected, open Chrome on the desktop and browse to:"
echo "NOTE:   http://localhost:18789"
echo ""
echo "NOTE: Shell access for debugging:"
echo "NOTE:   ssh -i 03-openclaw/keys/openclaw_ssh.pem ubuntu@${PUBLIC_IP}"

# The gateway binds loopback only, so the UI is reachable from inside the RDP
# session and nowhere else.

if command -v mstsc.exe >/dev/null 2>&1; then
  echo ""
  echo "NOTE: Launching mstsc..."
  mstsc.exe /v:"${PUBLIC_IP}:3389" &
fi
