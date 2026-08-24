#!/bin/bash
set -euo pipefail

# ==============================================================================
# OpenClaw Config Initialization
# ==============================================================================
#
# Runs the openclaw gateway briefly as the openclaw user to stamp the config
# file with internal metadata. Without this step, openclaw detects a
# "missing-meta-before-write" condition on first launch and overwrites any
# pre-written config with defaults, discarding the litellm provider settings.
#
# Flow:
#   1. Start litellm with a placeholder config so the models endpoint answers.
#   2. Run the openclaw gateway in the background as the openclaw user.
#   3. Set gateway mode and approvals.
#   4. Stop both — config is persisted at /home/openclaw/.openclaw.
#
# It does NOT register models. The model list is a deploy-time decision that
# varies per deployment, so 03-openclaw/scripts/userdata.sh writes it at first
# boot from var.models. Baking a list in here would freeze it into the image.
#
# The placeholder config carries no credentials and is never used for a real
# call. LiteLLM validates OCI credentials lazily, at invocation, so the proxy
# starts happily here on a build host that has none. userdata.sh replaces this
# file wholesale at first boot with the models from genai-config.sh.
#
# ==============================================================================

echo "NOTE: [openclaw-init] writing placeholder litellm config"
mkdir -p /opt/openclaw
cat > /opt/openclaw/litellm-config.yaml <<'LITELLM'
model_list:
  - model_name: PLACEHOLDER-STALE-PROXY-RESTART-LITELLM
    litellm_params:
      model: oci/meta.llama-4-maverick-17b-128e-instruct-fp8

litellm_settings:
  drop_params: true

general_settings:
  master_key: "sk-openclaw"
  drop_params: true
LITELLM
chown openclaw:openclaw /opt/openclaw/litellm-config.yaml

echo "NOTE: [openclaw-init] starting litellm placeholder"
sudo -u openclaw /opt/litellm-venv/bin/litellm \
  --config /opt/openclaw/litellm-config.yaml --port 4000 &
LITELLM_PID=$!
sleep 8

OPENCLAW_BIN=$(which openclaw)
echo "NOTE: [openclaw-init] openclaw binary: ${OPENCLAW_BIN}"

echo "NOTE: [openclaw-init] starting openclaw gateway to stamp config metadata"
sudo -u openclaw env HOME=/home/openclaw PATH="${PATH}" bash -c "
  ${OPENCLAW_BIN} gateway run \
    --allow-unconfigured --bind loopback --port 18789 &
  echo \$! > /tmp/openclaw-init.pid
"
sleep 12

echo "NOTE: [openclaw-init] setting gateway mode and approvals"
sudo -u openclaw env HOME=/home/openclaw PATH="${PATH}" bash -c "
  ${OPENCLAW_BIN} config set gateway.mode local || true
  ${OPENCLAW_BIN} config set gateway.auth.mode none || true
  ${OPENCLAW_BIN} approvals allowlist add --agent '*' '/**' || true
  ${OPENCLAW_BIN} approvals allowlist add --agent 'main' '/**' || true
"

echo "NOTE: [openclaw-init] stopping all openclaw and litellm processes"
# Kill everything running as the openclaw user — this catches the gateway, any
# restarted children, node workers, and the uvicorn/litellm children that
# pkill -f misses.
pkill -u openclaw 2>/dev/null || true
sleep 3
pkill -9 -u openclaw 2>/dev/null || true
rm -f /tmp/openclaw-init.pid

echo "NOTE: [openclaw-init] writing workspace files"
WORKSPACE=/home/openclaw/.openclaw/workspace
mkdir -p "${WORKSPACE}"

cat > "${WORKSPACE}/HEARTBEAT.md" <<'HEARTBEAT'
# System Context

You are running on an Oracle Cloud Infrastructure compute instance with the
following capabilities:

- **exec tool**: Full shell access — use it to run commands directly. Never ask the user to run commands manually.
- **OCI CLI**: Authenticates with the instance principal — no keys, no config file. Always pass `--auth instance_principal`.
- **Your own compartment/region**: never ask the user for these. Read them from the metadata service: `curl -s -H "Authorization: Bearer Oracle" http://169.254.169.254/opc/v2/instance/ | jq -r .compartmentId`
- **`Missing option(s) --compartment-id`** means the argument was omitted — not a permissions failure and not a hang. Look the value up and retry.
- **Web**: Apache2 serves /var/www/html (world-writable) at http://localhost/ — write a file there and open it in the browser.
- **Email**: Send via the `mail` command (msmtp + OCI Email Delivery): `echo "body" | mail -s "Subject" recipient@example.com`
- **Cost**: Use `oci --auth instance_principal usage-api usage-summary request-summarized-usages`.

Read SYSTEM.md in this workspace for the full list of installed tools and capabilities.
HEARTBEAT

cat > "${WORKSPACE}/CLAUDE.md" <<'CLAUDEMD'
You have full exec access via the exec tool. The OCI CLI is installed and the
instance carries an instance principal, so no credentials are configured on
disk and ~/.oci/config does not exist.

Every OCI CLI command must therefore pass the auth mode explicitly:

  oci --auth instance_principal iam region list

Without that flag the CLI looks for ~/.oci/config and fails with a
ConfigFileNotFound error. That failure is not a permissions problem — it means
the flag was omitted.

To send email, use the mail command via exec — msmtp is configured with OCI
Email Delivery SMTP credentials:

  echo "Message body" | mail -s "Subject" recipient@example.com

The from address is in /etc/msmtprc. Read it with:
  grep '^from' /etc/msmtprc

Never tell the user to do something manually that you can do yourself via exec.
CLAUDEMD

echo "NOTE: [openclaw-init] writing SYSTEM.md to workspace"
cat > "${WORKSPACE}/SYSTEM.md" <<'SYSTEMMD'
# System Capabilities

This instance has the following tools and capabilities available via exec.

## Cloud — Oracle Cloud Infrastructure
The OCI CLI is installed at /usr/local/bin/oci and authenticates with the
instance principal.

**Always pass `--auth instance_principal`.** There is no ~/.oci/config on this
machine; without the flag every command fails looking for one.

```bash
oci --auth instance_principal os ns get
```

### Find your own compartment and region — do NOT ask the user for these

Most OCI CLI commands require `--compartment-id`, and omitting it fails with
`Missing option(s) --compartment-id`. That is not a permissions problem and not
a hang: it means the argument was left off.

The instance can look its own identifiers up from the metadata service, which
needs no credentials at all:

```bash
COMPARTMENT=$(curl -s -H "Authorization: Bearer Oracle" \
  http://169.254.169.254/opc/v2/instance/ | jq -r .compartmentId)
REGION=$(curl -s -H "Authorization: Bearer Oracle" \
  http://169.254.169.254/opc/v2/instance/ | jq -r .canonicalRegionName)
```

Always resolve them that way before running a command that needs them.

### List everything in the compartment

Resource Search returns every resource type in one call, and is almost always
what "what is in my compartment" means:

```bash
oci --auth instance_principal search resource structured-search \
  --query-text "query all resources" --output table
```

The instance principal grants read access to the compartment plus the Usage
API. It does NOT grant Generative AI access — that runs through a separate
service user that only LiteLLM holds credentials for. Reach models through the
local proxy, never through the SDK directly.

## Models
The local LiteLLM proxy on port 4000 speaks the OpenAI API and forwards to OCI
Generative AI:

```bash
curl -s http://localhost:4000/v1/models -H "Authorization: Bearer sk-openclaw"
```

The available models are set at deploy time and vary per deployment, so
query them rather than assuming. The primary is whichever OpenClaw has
selected by default.

## Web publishing
Apache2 is installed and running. The document root is `/var/www/html`, and it
is world-writable, so you can publish a page with the exec tool and no sudo:

```bash
echo "<h1>hello</h1>" > /var/www/html/index.html
```

It is then served at http://localhost/ — open that with the browser tool to
show the user the result. Port 80 is not reachable from outside the instance,
so this is for showing things on the desktop, not for publishing to the web.

## Email
msmtp is configured system-wide with OCI Email Delivery SMTP credentials.
Use the `mail` command — no additional setup needed.

**Important:** The instance principal does NOT carry Email Delivery API
permissions. Do not try to send through the OCI SDK or CLI; always use the
`mail` command, which uses the pre-configured SMTP credentials.

```bash
# Plain text
echo "Body here" | mail -s "Subject" recipient@example.com

# With attachment
echo "See attached." | mail -s "Subject" -A /path/to/file.docx recipient@example.com
```

## Document Processing
- **python-docx** — read/write Word documents
- **python-pptx** — read/write PowerPoint files
- **openpyxl** — read/write Excel files
- **pymupdf** — read/extract PDF content
- **reportlab** — generate PDFs
- **pandoc** — convert between document formats
- **OnlyOffice** — desktop app for editing DOCX/XLSX/PPTX files

## Data & Analysis
- **pandas**, **numpy** — data analysis
- **matplotlib** — charts and visualizations
- **sqlite3** — local database

## Web & HTTP
- **curl**, **wget** — HTTP requests
- **beautifulsoup4**, **lxml** — HTML parsing
- **httpx**, **requests** — Python HTTP

## Media
- **imagemagick** — image manipulation (convert, resize, crop)
- **ffmpeg** — video/audio processing
- **poppler-utils** — PDF utilities (pdftotext, pdfinfo)
- **ghostscript** — PDF manipulation

## Other Clouds
- **AWS CLI**, **gcloud**, **az** — installed but NOT authenticated. They need
  credentials configured before they will do anything.
- **Terraform**, **Packer** — infrastructure tools

## File System
- Workspace: `~/.openclaw/workspace` (also reachable as `~/Openclaw/workspace`)
- Home: `/home/openclaw`

## Utilities
- **jq** — JSON processing
- **csvkit** — CSV tools
- **xmlstarlet** — XML processing
- **Rich** (Python) — formatted terminal output

SYSTEMMD

chown -R openclaw:openclaw "${WORKSPACE}"

echo "NOTE: [openclaw-init] appending SYSTEM.md reference to BOOTSTRAP.md"
BOOTSTRAP="${WORKSPACE}/BOOTSTRAP.md"
if [ -f "${BOOTSTRAP}" ]; then
  cat >> "${BOOTSTRAP}" <<'BOOTNOTE'

---

## This System

Before you delete this file, read `SYSTEM.md` in this workspace — it lists the
tools, commands, and capabilities available on this machine (email, document
processing, the OCI CLI and its required --auth flag, etc.). Keep that file
around after onboarding.
BOOTNOTE
fi

echo "NOTE: [openclaw-init] config directory contents:"
ls -la /home/openclaw/.openclaw/ 2>/dev/null || echo "(empty)"

echo "NOTE: [openclaw-init] done"
