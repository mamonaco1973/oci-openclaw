# ==============================================================================
# FILE: accounts.tf
# ------------------------------------------------------------------------------
# Generates the password for the local openclaw Linux user. The instance sets
# it at first boot from a value injected through cloud-init.
#
# Format: <word>-<6-digit-number>, e.g. "rocket-482910" — memorable enough to
# type into an RDP prompt, which is the only place it is ever used.
#
# The password lives in terraform.tfstate, which is gitignored, and
# get_password.sh reads it back.
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
