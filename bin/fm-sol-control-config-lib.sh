# shellcheck shell=bash

if [ -n "${FM_SOL_CONTROL_CONFIG_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_SOL_CONTROL_CONFIG_LIB_SOURCED=1

FM_SOL_CONTROL_CONFIG_STATE=
FM_SOL_CONTROL_CONFIG_REPO=
FM_SOL_CONTROL_CONFIG_ISSUE=
FM_SOL_CONTROL_CONFIG_LANDING_REPOS=

# shellcheck disable=SC2034 # Outputs are consumed by sourcing callers.
fm_sol_control_config_read() {  # <config-file>
  local file=${1:-} raw parsed
  FM_SOL_CONTROL_CONFIG_STATE=invalid
  FM_SOL_CONTROL_CONFIG_REPO=
  FM_SOL_CONTROL_CONFIG_ISSUE=
  FM_SOL_CONTROL_CONFIG_LANDING_REPOS=
  if [ ! -e "$file" ]; then
    FM_SOL_CONTROL_CONFIG_STATE=absent
    return 1
  fi
  [ -f "$file" ] && [ -r "$file" ] || return 2
  raw=$(cat "$file" 2>/dev/null) || return 2
  parsed=$(printf '%s' "$raw" | jq -cer '
    if type == "object"
      and (keys | sort) == ["issue", "landing_domain", "repo"]
      and (.repo | type) == "string"
      and (.repo | test("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$"))
      and (((.issue | type) == "number")
        or ((.issue | type) == "string" and (.issue | test("^[0-9]+$"))))
      and (.landing_domain | type) == "object"
      and (.landing_domain.repos | type) == "array"
      and all(.landing_domain.repos[];
        (type == "string") and test("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$"))
    then [.repo, (.issue | tostring), ([.landing_domain.repos[] | ascii_downcase] | @json)] | @tsv
    else error("invalid sol-control schema")
    end
  ' 2>/dev/null) || return 2
  IFS=$'\t' read -r FM_SOL_CONTROL_CONFIG_REPO FM_SOL_CONTROL_CONFIG_ISSUE \
    FM_SOL_CONTROL_CONFIG_LANDING_REPOS <<< "$parsed"
  FM_SOL_CONTROL_CONFIG_STATE=valid
  return 0
}
