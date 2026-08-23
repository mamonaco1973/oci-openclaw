# AI Agent Workstation on OCI with OpenClaw

Deploys a full desktop AI-agent workstation on Oracle Cloud Infrastructure:
an Ubuntu 24.04 compute instance running **OpenClaw** (an AI coding agent)
behind a **LiteLLM proxy** pointed at **OCI Generative AI**. You RDP into an
LXQt desktop and drive the agent from Chrome.

This is the Oracle port of [`aws-openclaw`](../../aws-openclaw), alongside
[`azure-openclaw`](../../azure-openclaw).

---

## Key Capabilities Demonstrated

- **OCI Generative AI through an OpenAI-compatible endpoint.** LiteLLM's
  native `oci/` provider fronts Meta Llama, OpenAI gpt-oss and xAI Grok with a
  single OpenAI API, so OpenClaw needs no OCI-specific code.
- **Packer-built custom image.** A complete desktop — LXQt, XRDP, Chrome,
  VS Code, OnlyOffice, four cloud CLIs, Node 22, Python tooling — baked once,
  so first boot only has to write config and start services.
- **Two-identity security model.** The agent's OCI CLI runs on an instance
  principal with no key material; only the LiteLLM proxy holds credentials, and
  only for Generative AI.
- **Cross-region IAM handling.** Tenancy-level identity is applied through a
  home-region provider alias, which OCI requires and does not tell you about.
- **Clean apply/destroy.** No OCI Vault, therefore no 30-day pending-deletion
  hold blocking the next deploy.

---

## Architecture

```
                        ┌──────────────────────────────┐
   RDP :3389 ─────────► │  openclaw-host               │
                        │  Ubuntu 24.04 + LXQt + XRDP  │
                        │                              │
                        │   Chrome ──► localhost:18789 │
                        │                  │           │
                        │           openclaw-gateway   │
                        │                  │           │
                        │           localhost:4000     │
                        │           LiteLLM proxy      │
                        └──────────────────┼───────────┘
                                           │ signed with the
                                           │ openclaw-svc API key
                                           ▼
                            ┌──────────────────────────────┐
                            │  OCI Generative AI           │
                            │  us-chicago-1, on demand     │
                            │  Llama 4 / gpt-oss / Grok    │
                            └──────────────────────────────┘
```

The OpenClaw gateway binds **loopback only**. There is no inbound path to port
18789 — the UI is reachable from inside the RDP session and nowhere else.

```
01-core/          VCN + subnets + NAT + service user/API key + Email Delivery
02-packer/        Packer build: Ubuntu 24.04 → openclaw-image
03-openclaw/      Compute instance + NSG + dynamic group + policies
genai-config.sh   Single source of truth for models + region
probe_genai.py    Proves a model actually answers on demand
```

---

## Key Resources

| Resource | Value |
|---|---|
| Region | `us-chicago-1` |
| VCN / CIDR | `clawd-vcn` / `10.0.0.0/23` |
| Instance | `openclaw-host`, `VM.Standard.E4.Flex`, 4 OCPU / 16 GB |
| Boot volume | 128 GB |
| LiteLLM | port `4000`, master key `sk-openclaw` |
| OpenClaw gateway | port `18789`, loopback only |
| Primary model | `meta.llama-4-maverick-17b-128e-instruct-fp8` |
| Linux user | `openclaw` (sudo, NOPASSWD) |

An OCI OCPU is a full physical core — two vCPUs — so 4 OCPUs is 8 vCPUs,
comfortably above the `t3.xlarge` the AWS build uses.

---

## Prerequisites

- An OCI tenancy with permission to create IAM users, groups, policies and
  dynamic groups **in the home region**
- Generative AI available in your target region (see below)
- `oci`, `terraform`, `jq` and `packer` in PATH
- `~/.oci/config` configured (`oci setup config`)
- Optional: a Python with the `oci` SDK, so `check_env.sh` can prove the models
  actually answer rather than merely being listed

### Region is not a free choice

Measured with `probe_genai.py` by calling every listed CHAT model:

| Region | Callable | Notes |
|---|---|---|
| `us-ashburn-1` | 8 | **No Meta, no OpenAI.** Cannot run this project. |
| `us-chicago-1` | 10 | Meta and OpenAI both answer. Slowest 2.6s. |

Same tenancy, same script. A model being listed in a region says nothing about
whether that region will serve it — this is the finding that set the default.

---

## Download this Repository

```bash
git clone https://github.com/mamonaco1973/oci-openclaw.git
cd oci-openclaw
```

---

## Build the Code

```bash
# Optional — register an approved sender so the agent can send email
export TF_VAR_email_sender="you@example.com"

# Optional — deploy into a specific compartment (defaults to the tenancy root)
export OCI_COMPARTMENT_ID="ocid1.compartment.oc1..."

./apply.sh
```

`apply.sh` runs `check_env.sh` first, then:

1. **01-core** — VCN, subnets, gateways, the `openclaw-svc` user and its API
   key, and optionally Email Delivery
2. **02-packer** — builds `openclaw-image` from Canonical Ubuntu 24.04
3. **03-openclaw** — the instance, its NSG, the dynamic group and policies
4. **validate.sh** — prints connection details

The Packer build is the long pole, at roughly 20–25 minutes.

---

## Connecting

```bash
./connect.sh        # RDP details; launches mstsc on Windows
./get_password.sh   # username and password
```

- **Host:** `<public_ip>:3389`
- **Username:** `openclaw`

Then open Chrome on the desktop and browse to `http://localhost:18789`.

Full post-deploy walkthrough, including the tool-calling check you should run
before trusting the deploy, is in [configure.md](configure.md).

---

## Model Selection

Everything lives in [`genai-config.sh`](genai-config.sh). Models are declared
as an array — **any number from 1 upward**, and nothing else in the project
needs changing:

```bash
# "<alias>|<oci-model-name>|<display name>"
GENAI_MODELS=(
  "llama-maverick|meta.llama-4-maverick-17b-128e-instruct-fp8|Llama 4 Maverick (OCI)"
  "llama-scout|meta.llama-4-scout-17b-16e-instruct|Llama 4 Scout (OCI)"
  "gpt-oss-120b|openai.gpt-oss-120b|GPT-OSS 120B (OCI)"
  "grok-4|xai.grok-4.20-non-reasoning|Grok 4 (OCI)"
)

GENAI_PRIMARY="llama-maverick"   # agents default to this; must be tool-calling
```

`check_env.sh` probes every entry before anything is built, `userdata.sh`
generates both the LiteLLM routing table and the OpenClaw model picker from
it at first boot, and `validate.sh` reports what was actually deployed. The
list above is just the default — the four models it ships with:

| Name in OpenClaw | OCI model | Role |
|---|---|---|
| `llama-maverick` | `meta.llama-4-maverick-17b-128e-instruct-fp8` | primary, tool-calling |
| `llama-scout` | `meta.llama-4-scout-17b-16e-instruct` | lower latency |
| `gpt-oss-120b` | `openai.gpt-oss-120b` | open-weight chat fallback |
| `grok-4` | `xai.grok-4.20-non-reasoning` | alternate vendor |

**Why the primary is not the fastest model.** `openai.gpt-oss-120b` measures
faster (0.10s vs 0.12s) and is what `oci-resume-app` runs — but that project
only needs single-shot completions. OpenClaw is an agentic coder and is useless
without tool calling; community LiteLLM configs for OCI gpt-oss explicitly set
`supports_function_calling=false`. Llama 4 Maverick is natively tool-calling,
nearly as fast, and open-weight, so it carries the same "no upstream vendor
retirement schedule" argument.

### "Works" has three levels, and they are not the same

1. **Listed** — `list-models` returns it. Proves nothing.
2. **Answers** — a real chat call succeeds. `check_env.sh` checks this.
3. **Emits tool calls** — nothing offline proves this. `validate.sh` prints the
   curl that settles it. **Run it.**

---

## Security Model

Two identities, deliberately separated:

| Identity | Used by | Grant |
|---|---|---|
| `openclaw-svc` user + API key | LiteLLM only | `use generative-ai-family` |
| `openclaw-dg` dynamic group | the agent's OCI CLI | read compartment, read usage-report |

The instance principal deliberately does **not** include Generative AI. If it
did, the agent could bypass the proxy, its master key and its model allowlist.

The API key exists because LiteLLM's **proxy** cannot use an instance
principal: the `oci/` provider supports one only via a Python `oci.signer`
object, and a YAML-configured proxy cannot supply one. It is the one place on
the box that holds key material — written at first boot to
`/etc/litellm-key.pem` (0600, owned by `openclaw`), never baked into the image
and never committed.

`terraform.tfstate` contains the desktop password and the API private key. It
is gitignored. There is no OCI Vault by design — see
[CLAUDE.md](CLAUDE.md#3-no-oci-vault--on-purpose).

---

## Teardown

```bash
./destroy.sh
```

Destroys the host, deletes every `openclaw-image` custom image (Packer creates
those outside Terraform, so Terraform will not remove them), then destroys the
core infrastructure. Image deletion failures are reported loudly rather than
swallowed — a silent `|| true` on a delete is how a teardown claims success
while leaving billable resources running.

---

## Known Gaps

- **Tool calling is unverified.** It could not be checked from the authoring
  workstation. Run the curl in `validate.sh` output on first deploy; this is
  the most likely thing to require a model swap.
- **No architecture diagram yet.** The AWS `.drawio`/`.png` were removed rather
  than left describing the wrong cloud.
- `terraform validate` has not been run against these modules: the provider
  plugins crash on the authoring workstation. `terraform fmt` parses both
  modules cleanly, so syntax is sound, but semantics are unproven until the
  first real apply.
