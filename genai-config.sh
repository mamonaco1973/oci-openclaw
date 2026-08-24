# ==============================================================================
# genai-config.sh
# ==============================================================================
# Single source of truth for the OCI Generative AI models exposed through
# LiteLLM. Sourced by apply.sh, destroy.sh, check_env.sh and validate.sh so the
# pre-flight probe, the Terraform apply and the on-instance LiteLLM config can
# never drift apart.
#
# ------------------------------------------------------------------------------
# Adding, removing or reordering models
# ------------------------------------------------------------------------------
# Edit GENAI_MODELS below. Any number from 1 upward works; nothing else in the
# project needs touching. The whole pipeline is driven from this array:
#
#   check_env.sh   probes every entry and refuses to deploy if one is dead
#   apply.sh       renders the array to JSON and hands it to Terraform
#   userdata.sh    generates the LiteLLM model_list and registers the models
#                  with OpenClaw at first boot
#   validate.sh    reports the list and builds the tool-calling check
#
# Format, one model per line, pipe-delimited:
#
#     "<alias>|<oci-model-name>|<display name>"
#
#   alias           what OpenClaw and LiteLLM call it. Keep it short; it shows
#                   up in curl commands and log lines.
#   oci-model-name  the exact Generative AI DISPLAY NAME, not an OCID. LiteLLM's
#                   oci/ provider addresses models by name, so the name is what
#                   ships. (oci-resume-app differs: it calls the inference API
#                   directly and must resolve a name to its region-specific
#                   OCID first.)
#   display name    the label shown in the OpenClaw model picker.
#
# GENAI_PRIMARY names the alias agents default to. It MUST appear in the array
# above; check_env.sh rejects a primary that does not.
#
# ------------------------------------------------------------------------------
# Why us-chicago-1
# ------------------------------------------------------------------------------
# Measured with probe_genai.py by calling chat() against every listed CHAT model
# in each region:
#
#   us-ashburn-1   8 callable. No Meta, no OpenAI. Grok wildly erratic --
#                  0.4s to 68s on an identical 5-token request.
#   us-chicago-1  10 callable. Meta AND OpenAI both answer. Slowest 2.6s.
#
# Ashburn cannot run the default lineup at all: it serves neither the Meta nor
# the OpenAI models. Do not "simplify" the region back to the us-ashburn-1 the
# other OCI projects in this repo use.
#
# ------------------------------------------------------------------------------
# Why the primary is not the fastest model
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
# gpt-oss-120b is primary. It is the fastest of the four AND the one observed
# actually driving OpenClaw's Exec tool end to end on a live box.
#
# THIS REVERSES AN EARLIER DECISION -- read before changing it back.
#
# Maverick was originally primary, justified by community LiteLLM configs that
# set supports_function_calling=false for OCI gpt-oss. That claim was never
# tested and is wrong on this stack. What was actually observed, 2026-08-23:
#
#   gpt-oss-120b   emitted a real tool call in OpenClaw -- the UI rendered a
#                  Tool block and the command ran.
#   llama-maverick returned a populated tool_calls array to a raw curl, but in
#                  OpenClaw it NARRATED the call instead, printing literal
#                  text like [exec command="..."] into the reply. Nothing ran.
#
# So raw tool-calling capability and reliable tool USE under OpenClaw's full
# system prompt are different properties, and only the second one matters here.
# Maverick has the first and not the second.
#
# Test both properties before promoting any model: the curl in configure.md
# proves capability, and an actual "create a file and read it back" request in
# the UI proves use. A model that passes the curl can still narrate.
#
# VERIFY TOOL CALLING BEFORE TRUSTING A SWAP. check_env.sh probes every model
# here, but that only proves it answers a plain chat call -- being listed proves
# even less. Nothing offline proves a model will emit a TOOL CALL through
# LiteLLM, and one that will not is useless to OpenClaw however fast it is.
# validate.sh prints the curl that settles it against the running proxy; run it
# before concluding a model change worked.
# ==============================================================================

# ------------------------------------------------------------------------------
# Models: "<alias>|<oci-model-name>|<display name>"
# ------------------------------------------------------------------------------
GENAI_MODELS=(
  "llama-maverick|meta.llama-4-maverick-17b-128e-instruct-fp8|Llama 4 Maverick (OCI)"
  "llama-scout|meta.llama-4-scout-17b-16e-instruct|Llama 4 Scout (OCI)"
  "gpt-oss-120b|openai.gpt-oss-120b|GPT-OSS 120B (OCI)"
  "grok-4|xai.grok-4.20-non-reasoning|Grok 4 (OCI)"
)

# Alias agents default to. Must be one of the aliases above, and should be a
# tool-calling model.
GENAI_PRIMARY="gpt-oss-120b"

# Region that actually serves the models above.
export OCI_REGION="${OCI_REGION:-us-chicago-1}"


# ==============================================================================
# Helpers — used by apply.sh, destroy.sh, check_env.sh and validate.sh
# ==============================================================================

# Emit GENAI_MODELS as a JSON array of {alias, model, display} objects.
#
# This is what Terraform consumes: a complex TF_VAR_ is parsed as JSON, so the
# array crosses into HCL as a list(object(...)) with no shell quoting games.
# Built with jq rather than string concatenation so a display name containing a
# quote or a backslash cannot produce malformed JSON.
genai_models_json() {
  local entry alias model display
  for entry in "${GENAI_MODELS[@]}"; do
    IFS='|' read -r alias model display <<< "${entry}"
    jq -n \
      --arg alias   "${alias}" \
      --arg model   "${model}" \
      --arg display "${display}" \
      '{alias: $alias, model: $model, display: $display}'
  done | jq -s '.'
}

# Emit just the OCI model names, one per line — for the availability probes.
genai_model_names() {
  local entry
  for entry in "${GENAI_MODELS[@]}"; do
    printf '%s\n' "${entry}" | cut -d'|' -f2
  done
}

# Emit just the aliases, one per line.
genai_model_aliases() {
  local entry
  for entry in "${GENAI_MODELS[@]}"; do
    printf '%s\n' "${entry}" | cut -d'|' -f1
  done
}

# Resolve an alias to its OCI model name. Empty output means "not found".
genai_model_for_alias() {
  local want="$1" entry alias model
  for entry in "${GENAI_MODELS[@]}"; do
    IFS='|' read -r alias model _ <<< "${entry}"
    if [ "${alias}" = "${want}" ]; then
      printf '%s' "${model}"
      return 0
    fi
  done
  return 1
}

# Export the pair Terraform needs. Callers run this after sourcing.
genai_export_tf_vars() {
  TF_VAR_models="$(genai_models_json)"
  TF_VAR_primary_alias="${GENAI_PRIMARY}"
  export TF_VAR_models TF_VAR_primary_alias
}

# Emit GENAI_MODELS as base64-encoded JSON, for handing to Packer.
#
# Base64 because this crosses a `packer build -var` boundary and then a shell
# provisioner's environment: raw JSON would need escaping at both hops, and a
# display name containing a quote or apostrophe would break one of them.
genai_models_b64() {
  genai_models_json | jq -c '.' | base64 -w0
}
