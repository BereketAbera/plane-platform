#!/usr/bin/env bash
# Whether hosted production's Infisical is safe to publish, from the config it answers anyone at GET /api/v1/admin/config. Source it; do not
# execute it. Bash 3.2. scripts/hosted/edge.sh reads it before it opens 443 to everyone, and scripts/hosted/bootstrap.sh before Argo CD
# can deploy Infisical's route with 443 already open. The blackbox probe infisical-claimed asks the same two fields through the route.
#
# Not claimed means its first admin is still to be made, and the bootstrap call makes one for whoever posts first. Open to sign-up means
# anyone can make an account. The route refuses both calls, and this does not lean on that.

# The config's JSON on stdin, and one word out: claimed, unclaimed, open-to-sign-up, or unreadable for anything else, nothing included.
infisical_claim_verdict() {
  local verdict
  verdict="$(jq -r 'if (.config | type) != "object" then "unreadable"
    elif .config.initialized != true then "unclaimed"
    elif .config.allowSignUp != false then "open-to-sign-up"
    else "claimed" end' 2>/dev/null || true)"
  case "$verdict" in
    claimed | unclaimed | open-to-sign-up) printf '%s\n' "$verdict" ;;
    *) printf 'unreadable\n' ;;
  esac
}

# The same table the selftest reads, so a change to the verdict above has to keep each answer.
infisical_claim_selftest() {
  local failures=0 body want got
  while IFS='|' read -r want body; do
    [[ -n "$want" ]] || continue
    got="$(printf '%s' "$body" | infisical_claim_verdict)"
    if [[ "$got" == "$want" ]]; then
      printf ' ok %-16s %s\n' "$want" "$body"
    else
      printf 'fail %-16s %s, and it read %s\n' "$want" "$body" "$got"
      failures=$((failures + 1))
    fi
  done <<'TABLE'
claimed|{"config":{"initialized":true,"allowSignUp":false}}
unclaimed|{"config":{"initialized":false,"allowSignUp":true}}
unclaimed|{"config":{"initialized":false,"allowSignUp":false}}
open-to-sign-up|{"config":{"initialized":true,"allowSignUp":true}}
open-to-sign-up|{"config":{"initialized":true}}
unclaimed|{"config":{"allowSignUp":false}}
unclaimed|{"config":{"initialized":"true","allowSignUp":false}}
open-to-sign-up|{"config":{"initialized":true,"allowSignUp":"false"}}
unreadable|{"config":null}
unreadable|{"statusCode":404,"message":"Route GET:/api/v1/admin/config not found"}
unreadable|<!doctype html><title>Infisical</title>
unreadable|404 page not found
unreadable|
TABLE
  [[ "$failures" -eq 0 ]]
}
