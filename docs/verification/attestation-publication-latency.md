# Attestation publication latency

Audience: maintainer verification.

This record holds the measurement the `Require no-mistakes` reconciliation window is sized against.
[`docs/no-mistakes-attestation.md`](../no-mistakes-attestation.md) owns what that window does and does not cover; this owns how its number was reached and how to reach it again.
The window is a design limit rather than a preference, so re-measure before changing it.

## What is measured

For one head, the delay between the `pull_request` event that started its check and the moment its attestation became readable.
The event is the `created_at` of the first `no-mistakes-required.yml` run for that head, which is when the push that raised it was seen.
The publication is the committer time of the note commit that first added a note for that head on `refs/notes/no-mistakes`.

Both clocks are involved: the run time is GitHub's and the note time is the publishing machine's, so a host whose clock is far off would show as an outlier rather than as a shifted distribution.

## Measured on 2026-08-17, against sbracewell64/firstmate

```sh
git init -q notesprobe && cd notesprobe
git remote add origin https://github.com/sbracewell64/firstmate.git
git fetch -q --no-tags origin 'refs/notes/no-mistakes:refs/notes/no-mistakes'
git log --format='%H %cI' refs/notes/no-mistakes | while read -r c t; do
  for h in $(git diff-tree --root -r --no-commit-id --name-only "$c" | tr -d '/'); do
    printf '%s\t%s\n' "$h" "$(date -u -d "$t" +%Y-%m-%dT%H:%M:%SZ)"
  done
done | sort -u > notes-pub.tsv

gh api --paginate \
  'repos/sbracewell64/firstmate/actions/workflows/no-mistakes-required.yml/runs?per_page=100' \
  --jq '.workflow_runs[] | [.head_sha, .created_at] | @tsv' > runs.tsv

awk -F '\t' '!seen[$1]++ || $2 < earliest[$1] { earliest[$1]=$2 }
  END { for (head in earliest) print head "\t" earliest[head] }' notes-pub.tsv \
  | sort > notes-earliest.tsv
awk -F '\t' '!seen[$1]++ || $2 < earliest[$1] { earliest[$1]=$2 }
  END { for (head in earliest) print head "\t" earliest[head] }' runs.tsv \
  | sort > runs-earliest.tsv
join -t "$(printf '\t')" notes-earliest.tsv runs-earliest.tsv \
  | while IFS="$(printf '\t')" read -r head published started; do
      printf '%s\t%s\n' "$head" \
        "$(( $(date -u -d "$published" +%s) - $(date -u -d "$started" +%s) ))"
    done \
  | sort -t "$(printf '\t')" -k2,2n > publication-latency.tsv

awk -F '\t' '
  { value[NR]=$2 }
  END {
    printf "n=%d  min=%d  median=%d  max=%d\n", NR, value[1], value[(NR+1)/2], value[NR]
    split("30 45 60 90 120 180", bound, " ")
    for (i=1; i<=6; i++) {
      count=0
      for (j=1; j<=NR; j++) if (value[j] <= bound[i]) count++
      printf "<=%ds: %2d/%d\n", bound[i], count, NR
    }
  }
' publication-latency.tsv
```

The join of the earliest publication per head to the earliest run per head gave 45 heads carrying both.

Observed distribution, in seconds:

```text
n=45  min=9  median=200  max=1815
<=30s:  2/45
<=45s:  7/45
<=60s: 11/45
<=90s: 15/45
<=120s: 18/45
<=180s: 21/45
```

The eleven observations at or under 60 seconds end at 55, and the next observation is at 75.

## What it establishes

That publication latency is bimodal rather than spread.
A short delay is a publication that raced its own push; a long one is a pipeline that had not reached the step which publishes, and no bounded wait can cover that without waiting out a validation run.
60 seconds covers the near-miss cluster and stops before the tail, and the tail is recovered by re-evaluation rather than by waiting.

## What it does not establish

That this distribution holds for another repository, another pipeline configuration, or a delivery flow that publishes at a different step.
It is one repository's history at one date, and it is the basis for one number rather than a general claim about publication latency.
