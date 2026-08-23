# ==============================================================================
# FILE: accounts.tf
# ------------------------------------------------------------------------------
# Generates the password for the local openclaw Linux user. The instance sets
# it at first boot from a value injected through cloud-init.
#
# Format: <word>-<6-digit-number>, e.g. "rocket-482910" — memorable enough to
# type into an RDP prompt, which is the only place it is ever used.
#
# WHY THIS IS NOT IN OCI VAULT, unlike the AWS build's Secrets Manager entry:
# OCI holds a deleted vault in PENDING_DELETION for a mandatory 30 days, during
# which it still counts against a default tenancy limit of one vault. Any
# destroy/rebuild cycle then fails on LimitExceeded until the hold expires, and
# the documented workaround is to manually cancel the deletion and re-import.
# That is incompatible with a project whose whole point is apply/destroy on
# demand, so this repo follows the convention the other OCI projects here
# settled on: the password lives in tfstate and get_password.sh reads it back.
#
# tfstate therefore contains secrets. It is gitignored, and so is everything
# else Terraform writes.
# ==============================================================================

# ==============================================================================
# SECTION: Memorable Word List
# ==============================================================================

locals {
  memorable_words = [
    "bright", "simple", "orange", "window", "little",
    "people", "friend", "yellow", "animal", "family",
    "circle", "moment", "summer", "button", "planet",
    "rocket", "silver", "forest", "stream", "butter",
    "castle", "wonder", "gentle", "driver", "coffee"
  ]
}

# ==============================================================================
# SECTION: Password Generation
# ==============================================================================

resource "random_shuffle" "word" {
  input        = local.memorable_words
  result_count = 1
}

resource "random_integer" "num" {
  min = 100000
  max = 999999
}

locals {
  openclaw_password = format("%s-%d",
    random_shuffle.word.result[0],
    random_integer.num.result
  )
}
