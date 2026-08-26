# shellcheck shell=bash
# fm-model-price-lib.sh - single owner of the question "is this model's price,
# observed FRESHLY and FROM THE PROVIDER, exactly zero on every axis?"
# Usage: . bin/fm-model-price-lib.sh
#
# WHY THIS EXISTS, and why it is not folded into the model registry.
# bin/fm-model-registry-lib.sh answers whether a RECORDED price is zero. That
# recorded price is a local file the provider never sees, and the thing that makes
# a name safe is its price - so a name-based allowlist is structurally blind to a
# repricing, exactly as that library's own price-drift section says. Its drift
# check closes half of that: it compares the recorded price against a catalogue
# file already on disk, and is deliberately "free, local file reads only - no
# network". Nothing closed the other half, which is that the catalogue file on
# disk is itself a copy that ages.
#
# This library is the other half. It reads the PROVIDER, now, and answers with a
# freshness bound attached. It is a separate file rather than more functions in
# the registry library for a reason worth stating: that library is local, free,
# and safe to call anywhere, including inside a tight loop over every task's meta.
# A network read has none of those properties, and quietly giving an existing
# local-only owner an network dependency is how a cheap check becomes one nobody
# can run at session start.
#
# ONE OWNER, TWO SOURCES. The provider publishes the price in two documents, and
# they answer different questions:
#
#   CATALOGUE   the model listing. Supplies the ADVERTISED model-level price, the
#               slug, and the metadata generation (`created`). It CANNOT say which
#               endpoint will serve a request, and therefore cannot say what that
#               request will actually cost.
#   ENDPOINTS   the per-model endpoint listing. Supplies the RESOLVED endpoint's
#               provider identity and its own price, and how many endpoints exist.
#               This is the only source that can answer what a dispatch pays.
#
# Both are normalized into the same shape and folded ONCE, by fm_model_price_fold.
# This follows the "two sources are allowed; two answers are not" rule in the
# firstmate-coding-guidelines skill: each normalizer states what its source cannot
# supply, and neither answers a narrower question and has the answer credited to
# the wider one. A model advertised at zero whose resolved endpoint is priced is a
# DIFFERENT observation from one advertised at a price, and collapsing them would
# lose the only evidence that the endpoint check is not redundant.
#
# ONLY `ZERO` IS ELIGIBLE, and every other verdict is INELIGIBLE rather than free.
# That includes every could-not-observe verdict. This is the load-bearing rule:
# an unreachable provider, a malformed document, an absent model, an unparseable
# price and an aged observation are all reasons the price is UNKNOWN, and an
# unknown price under a zero-budget rule is a refusal, never a default to free.
# fm_model_price_class keeps the three observation values distinguishable so a
# reader can still tell an observed charge from a failed observation, because the
# repairs differ; what it never does is let the second one dispatch.
#
# ENFORCEMENT SCOPE - the same deliberate asymmetry the model registry uses, for
# the same reason:
#
#   Provider declares no `price_metadata` -> INERT. Nothing is fetched and nothing
#       refuses. A home that never opted in behaves byte-identically to one built
#       before this existed, and the recorded-price rules in
#       bin/fm-model-registry-lib.sh continue to govern alone.
#   Provider declares `price_metadata`    -> FAIL CLOSED. Every verdict above
#       except ZERO refuses. Opting a provider in is what buys the guarantee, and
#       it is one declarative edit to add and one to remove.
#
# The validator in bin/fm-model-registry-lib.sh is what makes that opt-in complete
# rather than partial: once a provider declares `price_metadata`, each of its
# allowlisted models MUST also carry the recorded identity and observation time
# this library compares against. A half-declared opt-in is a config error caught
# at config-edit time, not a surprise at dispatch.
#
# NO CREDENTIAL EVER PARTICIPATES. Every fetch here reads a PUBLIC document, and
# fm_model_price_fetch is built so that stays true even on a machine configured
# otherwise: `-q` suppresses .curlrc and `--no-netrc` suppresses ~/.netrc, so an
# operator's ambient auth configuration cannot attach a credential to a request
# this library makes. Nothing here reads, prints, logs, or transports a key, and
# the price of a model is not a secret.
#
# docs/configuration.md "Model registry (config/models.json)" owns the schema
# fields this reads. .agents/skills/model-onboarding/SKILL.md owns the admission
# policy and the observation levels. This header owns the mechanics.

# Idempotent guard: bin/fm-spawn.sh and bin/fm-model-verify.sh may both be in one
# process tree, and a re-source must not redefine constants under set -u.
if [ -n "${FM_MODEL_PRICE_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_MODEL_PRICE_LIB_SOURCED=1

FM_MODEL_PRICE_SCHEMA='fm-model-price.v1'

# The O1 freshness ceiling, in seconds. The model-onboarding skill defines O1 as
# "probe before first dispatch each day", so one day is the widest an observation
# at probation may be trusted. A registry may declare a NARROWER window and that
# wins; a wider one is clamped to this. Same ceiling idiom as the promotion
# authority rows in bin/fm-model-registry-lib.sh - a home may be more conservative
# than the policy, never more permissive - and it is a ceiling rather than a
# default so that forgetting to declare a window cannot widen one.
FM_MODEL_PRICE_O1_MAX_AGE_SECONDS=86400

# Seconds any single metadata fetch may take. Bounded for the same reason every
# probe in bin/fm-model-verify.sh is: this runs on the dispatch path, and a
# request that hangs presents to supervision as a stale worker, which makes the
# monitor the fault.
FM_MODEL_PRICE_FETCH_TIMEOUT=${FM_MODEL_PRICE_FETCH_TIMEOUT:-15}

# ---------------------------------------------------------------------------
# Verdict vocabulary
# ---------------------------------------------------------------------------
#
# A closed set. Every value except ZERO is INELIGIBLE. They are kept separate
# rather than collapsed into one refusal because each names a different repair,
# and a refusal a reader cannot act on is worse than none.
#
#   ZERO               eligible: freshly observed, exactly zero on every axis.
#   PRICED             the advertised model-level price is not exactly zero.
#                      Covers a one-sided positive price, which is not a special
#                      case here: a zero prompt price with a positive completion
#                      price is simply not zero on every axis.
#   PRICED_ENDPOINT    the model advertises zero and the RESOLVED endpoint is
#                      priced. Distinct from PRICED on purpose: it is the only
#                      observation that shows the endpoint read earning its cost.
#   AMBIGUOUS_ENDPOINT the endpoint listing does not name exactly one endpoint,
#                      so which one serves the request is undetermined and no
#                      price can be attributed to the dispatch at all.
#   IDENTITY_MISMATCH  the two sources disagree, or the freshly observed identity
#                      differs from the one the evidence was recorded against.
#   STALE              the observation is older than the freshness window.
#   UNREACHABLE        a source could not be fetched.
#   MALFORMED          a source was fetched and is not the document expected.
#   MISSING            a source parsed and does not contain this model.
#   UNKNOWN_PRICE      the model is present and carries no usable price.

# fm_model_price_class <verdict>
# Echo which of the THREE observation values a verdict carries. Every consumer
# refuses on anything but ZERO regardless; this exists so a report can still say
# whether the fleet saw a charge or failed to look, because those need different
# repairs. It never softens a refusal - see the header.
fm_model_price_class() {  # <verdict>
  case "${1:-}" in
    ZERO) printf 'observed-good\n' ;;
    PRICED|PRICED_ENDPOINT|AMBIGUOUS_ENDPOINT|IDENTITY_MISMATCH) printf 'observed-bad\n' ;;
    STALE|UNREACHABLE|MALFORMED|MISSING|UNKNOWN_PRICE) printf 'could-not-observe\n' ;;
    *) printf 'could-not-observe\n' ;;
  esac
}

# ---------------------------------------------------------------------------
# Declared sources
# ---------------------------------------------------------------------------

# fm_model_price_declared <registry-file> <provider>
# Echo "<catalogue-url>\t<endpoints-url-template>" when this provider has opted
# in, and nothing when it has not. A provider that declares only one of the two
# echoes nothing and returns 2: a half-declared opt-in must not read as an absent
# one, and the validator refuses it at config-edit time so this is a backstop.
fm_model_price_declared() {  # <registry-file> <provider>
  local reg=${1:-} provider=${2:-} pair
  [ -n "$reg" ] && [ -n "$provider" ] || return 1
  [ -f "$reg" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  pair=$(jq -r --arg p "$provider" '
    (.providers[$p]?.price_metadata? // null) as $pm
    | if $pm == null then empty
      else [($pm.catalogue_url? // ""), ($pm.endpoints_url_template? // "")] | @tsv
      end' "$reg" 2>/dev/null) || return 1
  [ -n "$pair" ] || return 1
  case "$pair" in
    *$'\t') return 2 ;;
    $'\t'*) return 2 ;;
  esac
  printf '%s\n' "$pair"
}

# fm_model_price_window <registry-file>
# Echo the freshness window in seconds. Return non-zero without echoing when the
# registry declares one that cannot be read as a positive whole number, because a
# window that cannot be determined must refuse rather than silently fall back to
# the widest one this build allows.
fm_model_price_window() {  # <registry-file>
  local reg=${1:-} declared
  [ -f "$reg" ] || { printf '%s\n' "$FM_MODEL_PRICE_O1_MAX_AGE_SECONDS"; return 0; }
  command -v jq >/dev/null 2>&1 || { printf '%s\n' "$FM_MODEL_PRICE_O1_MAX_AGE_SECONDS"; return 0; }
  declared=$(jq -r '.observation?.levels?.O1?.price_max_age_seconds? // empty' "$reg" 2>/dev/null || true)
  [ -n "$declared" ] || { printf '%s\n' "$FM_MODEL_PRICE_O1_MAX_AGE_SECONDS"; return 0; }
  case "$declared" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$declared" -gt 0 ] 2>/dev/null || return 1
  if [ "$declared" -lt "$FM_MODEL_PRICE_O1_MAX_AGE_SECONDS" ]; then
    printf '%s\n' "$declared"
  else
    printf '%s\n' "$FM_MODEL_PRICE_O1_MAX_AGE_SECONDS"
  fi
}

# ---------------------------------------------------------------------------
# Time
# ---------------------------------------------------------------------------
#
# Both conversions go through jq rather than date(1), matching the `secs($iso)`
# idiom bin/fm-model-registry-lib.sh already uses. `date -d @<epoch>` and
# `date -d <iso>` are GNU extensions that BSD date rejects outright, and a
# freshness check that silently stops parsing on one supported platform would
# report every observation unreadable - a could-not-observe caused by the
# instrument, which is the failure this whole library is built to refuse.

# fm_model_price_iso <epoch> -> UTC ISO-8601, or empty when it cannot convert.
fm_model_price_iso() {  # <epoch>
  local epoch=${1:-}
  case "$epoch" in
    ''|*[!0-9]*) return 1 ;;
  esac
  command -v jq >/dev/null 2>&1 || return 1
  jq -r -n --argjson e "$epoch" '$e | strftime("%Y-%m-%dT%H:%M:%SZ")' 2>/dev/null
}

# fm_model_price_epoch <iso> -> epoch seconds, or empty when it cannot parse.
fm_model_price_epoch() {  # <iso>
  local iso=${1:-} out
  [ -n "$iso" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  out=$(jq -r -n --arg t "$iso" '
    (try ($t | sub("Z$"; "+0000") | strptime("%Y-%m-%dT%H:%M:%S%z") | mktime)
     catch (try ($t | sub("Z$"; "") | sub("\\.[0-9]+$"; "")
                   | strptime("%Y-%m-%dT%H:%M:%S") | mktime) catch null))
    | if . == null then empty else tostring end' 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# ---------------------------------------------------------------------------
# Transport
# ---------------------------------------------------------------------------

# fm_model_price_fetch <url> <outfile>
# Retrieve one PUBLIC metadata document. Return 0 on success; non-zero means the
# source was UNREACHABLE, which is a could-not-observe and never a price.
#
# `-q` and `--no-netrc` are load-bearing rather than tidiness: they stop an
# operator's ambient curl configuration from attaching a credential to a request
# this library makes. See the header - no credential ever participates here.
# `file://` works through the same code path, which is what lets the tests drive
# this exact function rather than a stub of it.
fm_model_price_fetch() {  # <url> <outfile>
  local url=${1:-} out=${2:-}
  [ -n "$url" ] && [ -n "$out" ] || return 1
  command -v curl >/dev/null 2>&1 || return 1
  curl -q -sS --no-netrc --fail \
    --max-time "$FM_MODEL_PRICE_FETCH_TIMEOUT" \
    -H 'Accept: application/json' \
    -o "$out" -- "$url" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Normalizers - one per source, each stating what its source cannot supply
# ---------------------------------------------------------------------------

# The catalogue normalizer. Emits {found, slug, created, prompt, completion} or a
# reason. It deliberately emits NO endpoint field: this source cannot see which
# endpoint serves a request, and a normalizer that guessed one would hand the
# fold an answer to a question its source never asked.
# shellcheck disable=SC2016 # jq program, not shell expansion.
FM_MODEL_PRICE_CATALOGUE_JQ='
  def num($v): if ($v | type) == "number" then $v
               elif ($v | type) == "string" then ($v | tonumber? // null)
               else null end;
  if type != "object" or (.data? | type) != "array" then
    {reason: "MALFORMED"}
  else
    ([ .data[] | select((.id? // "") == $slug) ]) as $hits
    | if ($hits | length) == 0 then {reason: "MISSING"}
      elif ($hits | length) > 1 then {reason: "IDENTITY_MISMATCH"}
      else $hits[0] as $m
        | (num($m.pricing?.prompt?)) as $p
        | (num($m.pricing?.completion?)) as $c
        | if $p == null or $c == null then {reason: "UNKNOWN_PRICE"}
          else {found: true, slug: ($m.id // ""),
                created: ($m.created? // null),
                prompt: $p, completion: $c}
          end
      end
  end'

# The endpoints normalizer. Emits the RESOLVED endpoint identity and its own
# price, plus the count that decides whether "resolved" means anything at all.
# More than one endpoint is AMBIGUOUS_ENDPOINT rather than a best-effort pick:
# with two endpoints there is no single price to attribute to the dispatch, and
# picking the cheaper one would be inventing an answer the source did not give.
# shellcheck disable=SC2016 # jq program, not shell expansion.
FM_MODEL_PRICE_ENDPOINTS_JQ='
  def num($v): if ($v | type) == "number" then $v
               elif ($v | type) == "string" then ($v | tonumber? // null)
               else null end;
  if type != "object" or (.data? | type) != "object" then
    {reason: "MALFORMED"}
  elif ((.data.endpoints? | type) != "array") then
    {reason: "MALFORMED"}
  elif ((.data.id? // "") != $slug) then
    {reason: "MISSING"}
  elif ((.data.endpoints | length) != 1) then
    {reason: "AMBIGUOUS_ENDPOINT", endpoint_count: (.data.endpoints | length)}
  else
    .data as $d | .data.endpoints[0] as $e
    | (num($e.pricing?.prompt?)) as $p
    | (num($e.pricing?.completion?)) as $c
    | if $p == null or $c == null then {reason: "UNKNOWN_PRICE"}
      else {found: true, slug: ($d.id // ""),
            created: ($d.created? // null),
            endpoint: ($e.tag? // $e.name? // ""),
            endpoint_provider: ($e.provider_name? // ""),
            endpoint_count: 1,
            prompt: $p, completion: $c}
      end
  end'

# ---------------------------------------------------------------------------
# The single fold
# ---------------------------------------------------------------------------

# fm_model_price_fold <catalogue-json> <endpoints-json> <model> <observed-at-iso>
# Echo one fm-model-price.v1 record. This is the ONLY place a verdict is decided;
# every consumer reads the verdict rather than re-deriving one from the parts.
#
# Order matters and is not arbitrary. A source that could not be read is reported
# before any price claim is made about it, and identity is agreed between the two
# sources before either price is trusted - because two documents describing two
# different models would otherwise let one supply the identity and the other the
# price, which is the credited-to-the-wrong-subject failure in miniature.
fm_model_price_fold() {  # <catalogue-json> <endpoints-json> <model> <observed-at>
  local cat_json=${1:-} ep_json=${2:-} model=${3:-} at=${4:-}
  command -v jq >/dev/null 2>&1 || return 1
  jq -c -n \
    --argjson cat "$cat_json" \
    --argjson ep "$ep_json" \
    --arg model "$model" \
    --arg at "$at" \
    --arg schema "$FM_MODEL_PRICE_SCHEMA" '
    def base: {schema: $schema, model: $model, observed_at: $at};
    # A source that failed is the whole answer: nothing downstream may claim a
    # price for a document that was never read.
    if ($cat.reason? // null) != null then
      base + {verdict: $cat.reason, detail: ("model catalogue: " + $cat.reason)}
    elif ($ep.reason? // null) != null then
      base + ({verdict: $ep.reason, detail: ("endpoint listing: " + $ep.reason)}
              + (if ($ep.endpoint_count? // null) != null
                 then {endpoint_count: $ep.endpoint_count} else {} end))
    elif ($cat.slug != $ep.slug) or ($cat.created != $ep.created) then
      base + {verdict: "IDENTITY_MISMATCH",
              slug: $cat.slug, created: $cat.created,
              detail: ("the model catalogue names " + ($cat.slug|tostring)
                       + "@" + ($cat.created|tostring)
                       + " and the endpoint listing names " + ($ep.slug|tostring)
                       + "@" + ($ep.created|tostring))}
    else
      base + {slug: $ep.slug, created: $ep.created,
              endpoint: $ep.endpoint, endpoint_provider: $ep.endpoint_provider,
              endpoint_count: $ep.endpoint_count,
              prompt: $ep.prompt, completion: $ep.completion,
              catalogue_prompt: $cat.prompt, catalogue_completion: $cat.completion}
      # The advertised price is judged first so that PRICED and PRICED_ENDPOINT
      # stay distinguishable. Reversing these two would report every priced model
      # as a priced endpoint and erase the evidence that the endpoint read finds
      # something the catalogue read cannot.
      | if ($cat.prompt != 0) or ($cat.completion != 0) then
          . + {verdict: "PRICED",
               detail: ("the advertised price is prompt=" + ($cat.prompt|tostring)
                        + " completion=" + ($cat.completion|tostring)
                        + ", which is not exactly zero")}
        elif ($ep.prompt != 0) or ($ep.completion != 0) then
          . + {verdict: "PRICED_ENDPOINT",
               detail: ("the model advertises zero but its resolved endpoint \""
                        + ($ep.endpoint|tostring) + "\" is priced prompt="
                        + ($ep.prompt|tostring) + " completion="
                        + ($ep.completion|tostring))}
        else
          . + {verdict: "ZERO",
               detail: ("prompt and completion are exactly zero on the advertised model and on its single resolved endpoint \""
                        + ($ep.endpoint|tostring) + "\"")}
        end
    end' 2>/dev/null
}

# fm_model_price_observe <registry-file> <model-key> [<now-epoch>]
# Fetch both sources for one registry key and echo the folded record. Return
# non-zero WITHOUT echoing only when this provider has not opted in, so a caller
# can tell "not checked" from "checked and refused" - those are different facts
# with different consequences and must never collapse.
#
#   1  NOTHING TO CHECK: no model selected, a harness-native bare model name, an
#      absent registry, or a provider that declared no price_metadata. Inert.
#   2  the declaration is half-written, or the registry is present and could not
#      be read at all. A broken safety file must never read as an absent one.
#
# Any other outcome ECHOES a record, including every failure to observe, because
# a failed observation is a result this fleet records rather than a gap it skips.
#
# The rc 1 / rc 2 split carries the same enforcement asymmetry the model registry
# uses, and getting it backwards would be severe in either direction: reading an
# absent registry as a broken one refuses every dispatch in every home that never
# opted in, and reading a broken declaration as an absent one silently disables
# the check in the one home that did.
fm_model_price_observe() {  # <registry-file> <model-key> [<now-epoch>]
  local reg=${1:-} key=${2:-} now=${3:-} provider model_id declared rc
  local cat_url ep_tmpl ep_url tmpd cat_norm ep_norm at

  # No model selected, or a bare harness-native selector: no provider credential
  # is involved, so there is no provider to ask for a price. Same boundary
  # fm_model_zero_budget_decision draws, for the same reason.
  [ -n "$key" ] && [ "$key" != default ] || return 1
  case "$key" in */*) ;; *) return 1 ;; esac

  [ -n "$reg" ] || return 1
  [ -f "$reg" ] || return 1
  # jq missing with a registry PRESENT is a refusal rather than inertness: the
  # opt-in cannot be read, so the check cannot be shown to be unnecessary.
  command -v jq >/dev/null 2>&1 || return 2

  provider=$(jq -r --arg k "$key" '.models[$k]?.provider? // ($k | split("/")[0])' "$reg" 2>/dev/null) || return 2
  model_id=$(jq -r --arg k "$key" '.models[$k]?.model_id? // ($k | split("/") | .[1:] | join("/"))' "$reg" 2>/dev/null) || return 2
  [ -n "$provider" ] && [ -n "$model_id" ] || return 2

  declared=$(fm_model_price_declared "$reg" "$provider")
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  cat_url=${declared%%$'\t'*}
  ep_tmpl=${declared#*$'\t'}
  ep_url=${ep_tmpl//\{model_id\}/$model_id}

  now=${now:-$(date -u +%s)}
  at=$(fm_model_price_iso "$now")

  tmpd=$(mktemp -d "${TMPDIR:-/tmp}/fm-model-price.XXXXXX") || return 2

  # An unreachable source is normalized into the SAME shape a malformed one
  # produces, so the fold has exactly one input contract and no branch here can
  # accidentally skip it.
  if fm_model_price_fetch "$cat_url" "$tmpd/catalogue.json"; then
    cat_norm=$(jq -c --arg slug "$model_id" "$FM_MODEL_PRICE_CATALOGUE_JQ" "$tmpd/catalogue.json" 2>/dev/null) \
      || cat_norm='{"reason":"MALFORMED"}'
    [ -n "$cat_norm" ] || cat_norm='{"reason":"MALFORMED"}'
  else
    cat_norm='{"reason":"UNREACHABLE"}'
  fi
  if fm_model_price_fetch "$ep_url" "$tmpd/endpoints.json"; then
    ep_norm=$(jq -c --arg slug "$model_id" "$FM_MODEL_PRICE_ENDPOINTS_JQ" "$tmpd/endpoints.json" 2>/dev/null) \
      || ep_norm='{"reason":"MALFORMED"}'
    [ -n "$ep_norm" ] || ep_norm='{"reason":"MALFORMED"}'
  else
    ep_norm='{"reason":"UNREACHABLE"}'
  fi
  rm -rf "$tmpd"

  fm_model_price_fold "$cat_norm" "$ep_norm" "$model_id" "$at"
}

# ---------------------------------------------------------------------------
# The decision a consumer acts on
# ---------------------------------------------------------------------------

# fm_model_price_decision <record> <registry-file> <model-key> [<now-epoch>]
# Return 0 only when this record admits a dispatch. Echo one actionable refusal
# otherwise. Three independent conditions must all hold, and each is checked here
# rather than inside the fold because each reads something the fold never saw:
#
#   1. the verdict is ZERO;
#   2. the observation is INSIDE the freshness window, so a record cannot be
#      carried forward past the point its evidence expired;
#   3. the freshly observed identity matches the identity the recorded evidence
#      was taken against, so a reused slug or a regenerated model is refused
#      rather than inheriting the trust of the thing it replaced.
fm_model_price_decision() {  # <record> <registry-file> <model-key> [<now-epoch>]
  local rec=${1:-} reg=${2:-} key=${3:-} now=${4:-} verdict detail window
  local at_epoch age rec_slug rec_created obs_slug obs_created

  if [ -z "$rec" ]; then
    printf 'the freshly observed price for %s could not be determined at all; refusing rather than dispatching an unpriced model\n' "$key"
    return 1
  fi
  command -v jq >/dev/null 2>&1 || {
    printf 'jq is required to read the observed price for %s, and is not installed; refusing rather than dispatching an unpriced model\n' "$key"
    return 1
  }

  verdict=$(printf '%s' "$rec" | jq -r '.verdict // ""' 2>/dev/null || true)
  detail=$(printf '%s' "$rec" | jq -r '.detail // ""' 2>/dev/null || true)
  if [ -z "$verdict" ]; then
    printf 'the observed-price record for %s is unreadable; refusing rather than dispatching an unpriced model\n' "$key"
    return 1
  fi
  if [ "$verdict" != ZERO ]; then
    printf 'zero-cost check refuses %s: %s [%s, %s]\n' \
      "$key" "$detail" "$verdict" "$(fm_model_price_class "$verdict")"
    return 1
  fi

  # (2) Freshness. A ZERO verdict that has aged out is STALE, and stale is not a
  # weaker pass - it is the same could-not-observe as never having looked.
  if ! window=$(fm_model_price_window "$reg"); then
    printf 'zero-cost check refuses %s: the freshness window in %s is not a positive whole number of seconds [STALE, could-not-observe]\n' "$key" "$reg"
    return 1
  fi
  now=${now:-$(date -u +%s)}
  at_epoch=$(fm_model_price_epoch \
    "$(printf '%s' "$rec" | jq -r '.observed_at // ""' 2>/dev/null || true)") || at_epoch=
  if [ -z "$at_epoch" ]; then
    printf 'zero-cost check refuses %s: the observation carries no readable time, so its freshness cannot be established [STALE, could-not-observe]\n' "$key"
    return 1
  fi
  age=$((now - at_epoch))
  if [ "$age" -lt 0 ] || [ "$age" -gt "$window" ]; then
    printf 'zero-cost check refuses %s: the price observation is %ds old against a %ds freshness window [STALE, could-not-observe]\n' \
      "$key" "$age" "$window"
    return 1
  fi

  # (3) Identity. Compared only when the allowlist recorded one; the validator
  # requires it for every allowlisted model of an opted-in provider, so an absent
  # record here means this model is not allowlisted at all - which the zero-budget
  # decision in bin/fm-model-registry-lib.sh already refuses on its own axis.
  rec_slug=$(jq -r --arg k "$key" '.zero_budget?.allowlist[$k]?.identity_at_verification?.slug? // empty' "$reg" 2>/dev/null || true)
  rec_created=$(jq -r --arg k "$key" '.zero_budget?.allowlist[$k]?.identity_at_verification?.created? // empty' "$reg" 2>/dev/null || true)
  if [ -n "$rec_slug" ] || [ -n "$rec_created" ]; then
    obs_slug=$(printf '%s' "$rec" | jq -r '.slug // ""' 2>/dev/null || true)
    obs_created=$(printf '%s' "$rec" | jq -r '.created // ""' 2>/dev/null || true)
    if [ "$obs_slug" != "$rec_slug" ] || [ "$obs_created" != "$rec_created" ]; then
      printf 'zero-cost check refuses %s: the provider now serves %s@%s where the recorded zero-price evidence was taken against %s@%s [IDENTITY_MISMATCH, observed-bad]\n' \
        "$key" "${obs_slug:-unnamed}" "${obs_created:-unnamed}" \
        "${rec_slug:-unnamed}" "${rec_created:-unnamed}"
      return 1
    fi
  fi
  return 0
}

# fm_model_price_record_path [<state-dir>]
# The volatile per-home record of what the provider last said. Deliberately a
# SEPARATE file from state/model-health.json rather than another key inside it:
# availability and price are independent axes everywhere else in this fleet, and
# merging them would let one file's semantics ("is it reachable?") lend authority
# to the other's ("what does it cost?"). Volatile like model-health.json, for the
# same reason - config/models.json holds durable routing decisions and this holds
# a perishable observation, so this script never writes that one.
fm_model_price_record_path() {  # [<state-dir>]
  local state=${1:-}
  state=${state:-${STATE:-${FM_STATE_OVERRIDE:-${FM_HOME:-.}/state}}}
  printf '%s\n' "$state/model-price.json"
}

# fm_model_price_record_write <state-dir> <key> <record>
# Merge one observation into that file. Best effort: this is evidence, and a home
# whose state directory is unwritable must still get the REFUSAL from the
# decision above rather than losing it to a failed write.
fm_model_price_record_write() {  # <state-dir> <key> <record>
  local state=${1:-} key=${2:-} rec=${3:-} path merged
  [ -n "$key" ] && [ -n "$rec" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  path=$(fm_model_price_record_path "$state")
  mkdir -p "$(dirname "$path")" 2>/dev/null || return 0
  [ -f "$path" ] && jq -e . "$path" >/dev/null 2>&1 || printf '{"models":{}}\n' > "$path" 2>/dev/null || return 0
  merged=$(jq -c --arg k "$key" --argjson r "$rec" \
    '.models = ((.models // {}) | .[$k] = $r) | .updated_at = $r.observed_at' \
    "$path" 2>/dev/null) || return 0
  [ -n "$merged" ] || return 0
  printf '%s\n' "$merged" > "$path" 2>/dev/null || true
}

# fm_model_price_meta_lines <record>
# Echo the dispatch-evidence lines bin/fm-spawn.sh writes into state/<id>.meta.
# Kept here, beside the record's producer, so the field names cannot drift from
# the record they are read out of.
fm_model_price_meta_lines() {  # <record>
  local rec=${1:-}
  [ -n "$rec" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  printf '%s' "$rec" | jq -r '
    [ (if (.slug // "") != "" then "price_slug=" + .slug else empty end),
      (if (.created // null) != null then "price_metadata_created=" + (.created|tostring) else empty end),
      (if (.endpoint // "") != "" then "price_endpoint=" + .endpoint else empty end),
      (if (.endpoint_provider // "") != "" then "price_endpoint_provider=" + .endpoint_provider else empty end),
      (if (.observed_at // "") != "" then "price_observed_at=" + .observed_at else empty end),
      (if (.prompt // null) != null then "price_prompt=" + (.prompt|tostring) else empty end),
      (if (.completion // null) != null then "price_completion=" + (.completion|tostring) else empty end),
      (if (.verdict // "") != "" then "price_verdict=" + .verdict else empty end) ]
    | .[]' 2>/dev/null || true
}
