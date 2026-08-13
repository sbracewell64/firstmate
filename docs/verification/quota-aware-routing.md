# Quota-aware routing verification

Audience: maintainer verification.

This record holds reusable evidence for the one guarantee of `bin/fm-capacity-lib.sh` that a portable test cannot establish: that the join onto `quota-axi`'s real output works against the schema the vendor actually emits, and that the most-specific-scope rule discriminates correctly on live data.

Everything else about this seam is pinned portably in [`../../tests/fm-capacity-routing.test.sh`](../../tests/fm-capacity-routing.test.sh), which injects its own quota readings and needs no provider, no credential and no `quota-axi` at all.
That split is deliberate.
The three-valued mapping, the never-lower-the-floor rule, the deferral, the restart survival and the bounds are all logic and belong in CI.
Only the shape of the vendor's output is a fact about a program this repo does not own, so only that is refreshed here.

`bin/fm-capacity-lib.sh`'s header owns the mechanics, [`../configuration.md`](../configuration.md) "Quota-aware routing" owns the config schema, and `bin/fm-quota-axi-lib.sh` owns the compatibility floor.

Verified on 2026-08-11 on Linux 6.18.33.2-microsoft-standard-WSL2 with `quota-axi` 0.1.16 (`schemaVersion` 3) and jq 1.8.1.

The portable routing and restart-survival regressions were refreshed on 2026-08-13 with:

```sh
$ bash tests/fm-capacity-routing.test.sh
$ bash tests/fm-capacity-retry.test.sh
```

Both commands exited 0.
Together they covered the floor-preserving schedulable-set filter, the three-valued quota result, automatic restart-safe resumption, and the attempt-owned deferral bound.

## The vocabularies do not join by name, and the seam says so rather than guessing

Run against the live home's own `config/crew-dispatch.json`, which declares `quota_observable: true` for `claude` and `openai-codex` but names no `quota_axi_provider` for either:

```sh
$ bin/fm-route.sh capacity
quota source: read - quota-axi --json
  claude/opus: could_not_observe - capacity could not be observed for claude/opus (quota_axi_provider_unbound): _providers.claude declares readable quota but names no quota-axi provider, and the two vocabularies are not joined by name (repair: set /_providers/claude/quota_axi_provider to the quota-axi provider id this account actually meters against, recorded from evidence rather than from a matching prefix)
  google/gemini-2.5-flash: could_not_observe - capacity could not be observed for google/gemini-2.5-flash (provider_declares_no_quota_surface): _providers.google.quota_observable is false, so this provider publishes no quota this fleet can read (repair: none - this is a declared property of the provider, not a defect; the candidate stays eligible with its uncertainty disclosed)
  openai-codex/gpt-5.6-terra: could_not_observe - capacity could not be observed for openai-codex/gpt-5.6-terra (quota_axi_provider_unbound): _providers.openai-codex declares readable quota but names no quota-axi provider, and the two vocabularies are not joined by name (repair: set /_providers/openai-codex/quota_axi_provider to the quota-axi provider id this account actually meters against, recorded from evidence rather than from a matching prefix)
```

This is the state every home is in until an operator declares the binding, and it is the point of the design rather than a gap in it.
`quota-axi` reports providers as `claude`, `codex`, `cursor`, `copilot`, `grok` and `kimi`; the routing policy names them `claude`, `openai-codex`, `google` and `opencode`.
`claude` matching on both sides is a coincidence and `openai-codex` matching `codex` by prefix is not a contract, so nothing here infers either.
`google` and `opencode` have no `quota-axi` provider at all and are recorded as declared-unobservable rather than as unavailable.

## With the binding declared, the account windows read correctly

The same command against a copy of that config with `_providers.claude.quota_axi_provider = "claude"` and `_providers.openai-codex.quota_axi_provider = "codex"`:

```sh
$ bin/fm-route.sh capacity
quota source: read - quota-axi --json
  claude/opus: available - quota-axi claude all_models reports 6 percent remaining bounded by seven_day, resetting at 2026-08-15T23:00:00.102105+00:00
  openai-codex/gpt-5.6-terra: available - quota-axi codex all_models reports 87 percent remaining bounded by weekly, resetting at 2026-08-18T04:02:07.000Z
  opencode/nemotron-3-ultra-free: could_not_observe - capacity could not be observed for opencode/nemotron-3-ultra-free (provider_declares_no_quota_surface): _providers.opencode.quota_observable is false, so this provider publishes no quota this fleet can read (repair: none - this is a declared property of the provider, not a defect; the candidate stays eligible with its uncertainty disclosed)
```

Two independent facts are established here.
The percentages and their limiting windows are read from `quotaSemantics.effectiveAvailability[]` rather than recomputed, so the minimum across bounding windows stays `quota-axi`'s answer.
And both published timestamp forms convert: `+00:00` on the Claude window and `Z` on the Codex one both yield an epoch, which is what a deferral records as its retry condition.

## The most specific published scope wins, on live data

With `claude/fable` added to a pool in that same copy, the two Claude models in one pool resolve to different scopes and different verdicts:

```sh
$ bin/fm-route.sh capacity | grep claude
  claude/opus: available - quota-axi claude all_models reports 6 percent remaining bounded by seven_day, resetting at 2026-08-15T23:00:00.102105+00:00
  claude/fable: exhausted - quota-axi claude model:fable reports 0 percent remaining bounded by model:fable, resetting at 2026-08-15T23:00:00.091693+00:00
```

This is the discrimination that makes the rule correct rather than merely conservative.
`claude/fable` has a published `model:fable` window and is read from it; `claude/opus` has no published model scope, so its bound is the account's `all_models` entry, which is `quota-axi`'s statement about that account rather than an assumption made here.
An implementation that always read `all_models` would have called `claude/fable` available at the moment its own window was spent, and one that required a model scope would have refused to observe `claude/opus` at all.

## Refreshing this record

Run `bin/fm-route.sh capacity` against a home whose `_providers` entries declare their `quota_axi_provider` bindings, after any `quota-axi` upgrade.
What must still hold: the printed verdicts are `available`, `exhausted` or `could_not_observe` and nothing else; a provider `quota-axi` does not report is `could_not_observe` rather than either definite answer; and a model with a published `model:` scope is read from that scope rather than from `all_models`.
A `quota-axi` release that renames a provider id, drops `quotaSemantics.effectiveAvailability`, or stops publishing `resetsAt` degrades this seam to `could_not_observe` with the reason named rather than producing a wrong verdict, which is the failure mode to confirm rather than one to prevent.
