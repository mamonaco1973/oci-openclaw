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
# THE PROBE USES NO EXTERNAL TOOLS AT ALL. /dev/tcp is a bash builtin
# redirection, and the connect is backgrounded so it can be killed — because
# the OCI host firewall DROPS rather than rejects, and an unbounded connect to
# a dropped port hangs for minutes instead of failing fast.
#
# The alternatives were all worse:
#   timeout  coreutils only; absent on macOS, where it is gtimeout
#   nc       BSD, GNU and ncat builds disagree on flags
#   curl     MEASURED: telnet:// detects a closed port in 3s but sits on an
#            OPEN one for 90s, since it holds the session open. Exactly the
#            wrong way round for a readiness check.
#
# On timeout this warns and prints anyway — the details are exactly what you
# need to go and debug, so withholding them would be the wrong failure mode.
#
# ==============================================================================

# One connect attempt, bounded to ~3s. Returns 0 if the port accepted.
port_open() {
  local host="$1" port="$2"
  local pid waited=0

  # Subshell so a failed redirection cannot kill this script under set -e.
  (exec 3<>"/dev/tcp/${host}/${port}") >/dev/null 2>&1 &
  pid=$!

  while kill -0 "${pid}" 2>/dev/null; do
    if [ "${waited}" -ge 3 ]; then
      kill -9 "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done

  # The subshell has exited; its status is the connect result.
  wait "${pid}"
}

wait_for_port() {
  local host="$1" port="$2" label="$3"
  local attempts=120 # 120 x 5s = 10 minutes
  local i

  for ((i = 1; i <= attempts; i++)); do
    if port_open "${host}" "${port}"; then
      echo "NOTE: ${label} is accepting connections."
      return 0
    fi
    sleep 5
  done

  echo "WARN: ${label} did not answer within 10 minutes."
  return 1
}

# ==============================================================================
# Wait for the deploy to actually FINISH, not just to answer on a port
# ==============================================================================
#
# xrdp comes up minutes before cloud-init finishes. Printing the connection
# details when 3389 answers invites you to log in and open the OpenClaw UI
# while userdata is still writing the LiteLLM config and registering models.
#
# That matters more than it sounds, because the OpenClaw web UI fetches its
# model list ONCE when the page loads and never re-fetches. Open it early and
# the picker holds an empty or partial list for the life of that page — the
# only cure is a manual reload, which looks exactly like a backend bug and is
# not one. Getting this wrong cost most of a day.
#
# So: wait for the ports, then wait for cloud-init to report done, then confirm
# the proxy is actually serving the models. Only then print.
#
# ==============================================================================

SSH_KEY="${SCRIPT_DIR}/03-openclaw/keys/openclaw_ssh.pem"
SSH_OPTS=(-i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=10)

if [ "${PUBLIC_IP}" != "<not found>" ]; then
  echo ""
  echo "NOTE: Waiting for ${PUBLIC_IP} to finish booting..."
  wait_for_port "${PUBLIC_IP}" 22   "SSH (22)"   || true
  wait_for_port "${PUBLIC_IP}" 3389 "RDP (3389)" || true

  if [ -f "${SSH_KEY}" ]; then
    # cloud-init status --wait blocks until user_data has finished, which is
    # the definitive "this instance is done" signal.
    echo "NOTE: Waiting for cloud-init to finish..."
    ssh "${SSH_OPTS[@]}" "ubuntu@${PUBLIC_IP}" \
      'sudo cloud-init status --wait >/dev/null 2>&1' 2>/dev/null \
      && echo "NOTE: Cloud-init complete." \
      || echo "WARN: Could not confirm cloud-init completion."

    # Belt and braces: the proxy must be serving the primary before the UI is
    # worth opening.
    echo "NOTE: Waiting for LiteLLM to serve ${GENAI_PRIMARY}..."
    if ssh "${SSH_OPTS[@]}" "ubuntu@${PUBLIC_IP}" \
         "for i in \$(seq 1 60); do
            curl -fsS -m 3 localhost:4000/v1/models \
              -H 'Authorization: Bearer sk-openclaw' 2>/dev/null \
              | grep -q '${GENAI_PRIMARY}' && exit 0
            sleep 5
          done; exit 1" 2>/dev/null; then
      echo "NOTE: Models are being served."
    else
      echo "WARN: ${GENAI_PRIMARY} not served yet — if the OpenClaw model"
      echo "WARN: picker looks wrong, reload the page (Ctrl+Shift+R)."
    fi
  fi
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
