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
#     "<alias>|<oci-model-name>|<display name>[|<max tokens>[|nostream]]"
#
#   alias           what OpenClaw and LiteLLM call it. Keep it short; it shows
#                   up in curl commands and log lines.
#   oci-model-name  the exact Generative AI DISPLAY NAME, not an OCID. LiteLLM's
#                   oci/ provider addresses models by name, so the name is what
#                   ships. (oci-resume-app differs: it calls the inference API
#                   directly and must resolve a name to its region-specific
#                   OCID first.)
#   display name    the label shown in the OpenClaw model picker.
#   max tokens      OPTIONAL per-model output ceiling. See the note above
#                   GENAI_MODELS -- only needed where OCI 400s a larger ask.
#   nostream        OPTIONAL literal "nostream". Disables native streaming for
#                   that model only. Requires the max tokens field to be
#                   present (use the model's real ceiling) since it is 5th.
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
# Models: "<alias>|<oci-model-name>|<display name>[|<max output tokens>]"
# ------------------------------------------------------------------------------
#
# The 4th field is optional and caps output tokens for that model only.
#
# OpenClaw stamps every model it registers with maxTokens 8192 and sends that
# on each request.  OCI enforces a per-model ceiling and rejects anything above
# it with a 400 -- "Invalid 'maxTokens': Value is greater than maximum: 4096".
# LiteLLM retries, fails, returns a 500, and OpenClaw reports "request timed
# out".  Nothing in that message points at the real cause, and a small curl
# still succeeds, so it reads like a slow or unavailable model.  Both Meta
# models cap at 4096; gpt-oss and grok accepted 100000.  Measured 2026-09-02.
#
# This value is written into the OpenClaw PROVIDER config (models[].maxTokens),
# not the LiteLLM model_list.  That distinction cost an evening: a max_tokens
# in litellm_params is only a DEFAULT and loses to the value the client sends,
# so clamping there changes nothing.  The ceiling must be lowered on the
# client.  Do not "simplify" this back into litellm-config.yaml.
#
# Find a model's real ceiling by asking for more than it allows -- the 400 name
# the maximum:
#
#   curl -s http://localhost:4000/v1/chat/completions \
#     -H "Authorization: Bearer sk-openclaw" \
#     -H "Content-Type: application/json" \
#     -d '{"model":"<alias>","messages":[{"role":"user","content":"hi"}],
#          "max_tokens":100000}' | grep -o "maximum: [0-9]*"
#
# Leave the field off unless a model actually rejects 8192: the cap is a
# ceiling on every reply that model can produce, and a coding agent held to
# 4096 output tokens will truncate on long edits.
#
# The 5th field is optional too.  Set it to "nostream" where LiteLLM's OCI
# streaming adapter dies partway through a reply with "Chunk cannot be parsed
# as JSON: Expecting value: line 1 column 3 (char 2)" -- OCI emits a chunk the
# adapter cannot read (the HTTP status is 200; the failure is mid-stream).
# OpenClaw sees the stream stop and reports "request timed out", which again
# points nowhere near the cause.  "nostream" writes model_info.
# supports_native_streaming: false, so LiteLLM fetches the whole reply and
# chunks it locally -- no upstream stream to mis-parse.  Observed on
# llama-maverick 2026-09-02; intermittent, so retry several times before
# concluding it is fixed.
GENAI_MODELS=(
  "llama-maverick|meta.llama-4-maverick-17b-128e-instruct-fp8|Llama 4 Maverick (OCI)|4096|nostream"
  "llama-scout|meta.llama-4-scout-17b-16e-instruct|Llama 4 Scout (OCI)|4096"
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
  local entry alias model display maxtok stream
  for entry in "${GENAI_MODELS[@]}"; do
    IFS='|' read -r alias model display maxtok stream <<< "${entry}"
    # max_tokens must cross as a JSON number or null, and native_streaming as
    # a bool or null, never the string "": Terraform types them optional().
    # Absent means "leave it to the default", which is not the same as false.
    jq -n \
      --arg alias   "${alias}" \
      --arg model   "${model}" \
      --arg display "${display}" \
      --arg maxtok  "${maxtok:-}" \
      --arg stream  "${stream:-}" \
      '{alias: $alias, model: $model, display: $display,
        max_tokens: (if $maxtok == "" then null else ($maxtok | tonumber) end),
        native_streaming: (if $stream == "nostream" then false else null end)}'
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
