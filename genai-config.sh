# ==============================================================================
# genai-config.sh
# ==============================================================================
# Single source of truth for the OCI Generative AI models exposed through
# LiteLLM. Sourced by apply.sh and check_env.sh so the pre-flight probe, the
# Terraform apply and the on-instance LiteLLM config can never drift apart.
#
# These are model DISPLAY NAMES, not OCIDs. Unlike oci-resume-app -- which
# calls the inference API directly and must resolve a name to its region
# specific OCID -- LiteLLM's oci/ provider addresses models by name, so the
# name is what ships. check_env.sh still resolves each one against
# list-models to fail before a deploy rather than after it.
#
# ------------------------------------------------------------------------------
# Why us-chicago-1
# ------------------------------------------------------------------------------
# Measured with oci-resume-app/probe_genai.py by calling chat() against every
# listed CHAT model in each region:
#
#   us-ashburn-1   8 callable. No Meta, no OpenAI. Grok wildly erratic --
#                  0.4s to 68s on an identical 5-token request.
#   us-chicago-1  10 callable. Meta AND OpenAI both answer. Slowest 2.6s.
#
# Ashburn cannot run this project at all: it serves neither the Meta nor the
# OpenAI models below. Do not "simplify" the region back to the us-ashburn-1
# the other OCI projects in this repo use.
#
# ------------------------------------------------------------------------------
# Why Llama 4 Maverick is primary and not the fastest model
# ------------------------------------------------------------------------------
# OpenClaw is an agentic coder: it is useless without tool calling. That
# reorders the list, because raw latency stops being the deciding factor.
#
# Chicago timings at 5 max_tokens, fastest first:
#     0.10s  openai.gpt-oss-120b
#     0.12s  meta.llama-4-maverick-17b-128e-instruct-fp8   <- primary
#     0.26s  meta.llama-4-scout-17b-16e-instruct
#     0.38s  xai.grok-4.20-non-reasoning
#     0.57s  google.gemini-2.5-flash
#
# gpt-oss-120b is faster and is what oci-resume-app runs, but that project
# only needs single-shot completions. Community LiteLLM configs for OCI
# gpt-oss explicitly set supports_function_calling=false; a model that cannot
# call tools cannot drive OpenClaw. Maverick is natively tool-calling, nearly
# as fast, and open-weight -- so it carries the same "no upstream vendor
# retirement schedule" argument that made gpt-oss attractive in the first
# place, unlike Gemini 2.5 (being retired on GCP) or the Grok line (ten
# variants retired on a single day, 2026-08-15).
#
# gpt-oss-120b is still deployed, as a non-tool fallback for plain chat.
#
# VERIFY TOOL CALLING BEFORE TRUSTING A SWAP. check_env.sh runs
# probe_genai.py against every model below, but that only proves the model
# answers a plain chat call -- being listed proves even less. Nothing
# offline proves it will emit a TOOL CALL through LiteLLM, and a model that
# will not is useless to OpenClaw however fast it is. validate.sh prints the
# one-line curl that settles it against the running proxy; run it before
# concluding a model swap worked.
# ==============================================================================

# Primary agentic model -- must support tool calling.
export GENAI_PRIMARY_MODEL="meta.llama-4-maverick-17b-128e-instruct-fp8"

# Secondary models offered in the OpenClaw model picker.
export GENAI_FAST_MODEL="meta.llama-4-scout-17b-16e-instruct"
export GENAI_OSS_MODEL="openai.gpt-oss-120b"
export GENAI_GROK_MODEL="xai.grok-4.20-non-reasoning"

# Region that actually serves the models above.
export OCI_REGION="${OCI_REGION:-us-chicago-1}"
