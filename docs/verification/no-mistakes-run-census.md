# Complete no-mistakes run census

Maintainer-verification record for the census and firstmate semantic-work join owned by `bin/fm-nm-run-lib.sh` and driven by `bin/fm-nm-census.sh`.
It records what has actually been measured about the installed no-mistakes generation and what the census guarantees over it; the script headers own the contract itself.

## Why a census exists at all

no-mistakes registers every managed run worktree as its own `repos.id`.
A run created from inside one is therefore invisible to the enclosing checkout's `no-mistakes axi status` and to `no-mistakes runs`, which lists a single repository's rows and carries no run id.
Both of firstmate's pre-existing reads were repository-scoped, so a hidden active run read as quiescence.
Upstream's recursive-gate containment prevents new descendants; it does not make firstmate's projection complete, and legacy, independently created, and future schema-compatible rows still have to be observed.

## Measured generation

Observed 2026-08-22 on Linux (WSL2), against the installed runtime.

```
$ no-mistakes --version
no-mistakes version v1.40.3 (d873960) 2026-07-22T01:41:41Z
```

The state database is `~/.no-mistakes/state.sqlite`, journal mode `wal`, `PRAGMA quick_check` `ok`, read through SQLite library 3.46.1.
`sqlite3(1)` is NOT installed on this host; the reader uses python3's `sqlite3` module, the same reader `bin/fm-independence-lib.sh` already uses, and reports `READER_UNAVAILABLE` rather than an empty universe when python3 is absent.

Schema fingerprint of the two tables the census reads, over their exact `sqlite_master` SQL:

```
sha256:693a8ead7f699de0c087758e2c85a4605c6385ab13ed4f47bcfdcd73e8d31b53
```

The required columns are `repos(id, working_path, upstream_url)` and `runs(id, repo_id, branch, head_sha, status)`.
Columns beyond those are read when present and never refused, so a newer release that only adds fields stays readable; `tests/fm-nm-census.test.sh` pins both directions.
The run-status vocabulary is the tool's own: `status IN ('pending', 'running')` is the active predicate the binary itself uses, and `('completed', 'failed', 'cancelled')` are terminal.
`awaiting_approval` and `fix_review` are STEP statuses, not run statuses, so a run parked at a gate is `running` in this table and is covered by the active predicate.

`no-mistakes axi status --run <id>` answers for any run from any initialized checkout, verified cross-repository on this host, so one usable directory corroborates the whole candidate-owning set.
From a directory that is not a git repository the same command prints `error: not in a git repository`; that is read as a refusal through `fm_nm_error_line`, never as an absent run.

## Preserved preimplementation census

The authoritative census taken before this seam existed is retained as historical evidence and is not rewritten by later observations.

| Property | Count |
| --- | --- |
| Registered repositories | 59 |
| Repository identities rooted under managed run worktrees | 55 |
| Total runs | 357 |
| Completed | 110 |
| Failed | 153 |
| Cancelled | 94 |
| Running or pending | 0 |
| Duplicate run ids | 0 |

The normalized private snapshot is `data/no-mistakes-complete-run-census-and-work-join/authoritative-census-20260822.json`, 385,247 bytes, SHA-256 `4b7f8bc0c7ee75a14ba623273bd2ee8ce76a0f156d05ed5e168513ed1f03cf4c`.
That file is private task evidence and is deliberately left byte-identical; this record cites it rather than restating it.

Re-observed through the landed reader on the same day, the census reproduces those exact counts:

```
$ bin/fm-nm-census.sh --scope /home/shane/kun-agent-workspace
fm-nm-census: verdict=OBSERVED_QUIESCENT non_vacuous=yes repositories=59 nested=55 runs=357 active=0 candidate_owning=0 cno=0 refusals=0
fm-nm-census: generation database=/home/shane/.no-mistakes/state.sqlite schema=sha256:693a8ead7f699de0c087758e2c85a4605c6385ab13ed4f47bcfdcd73e8d31b53 sqlite=3.46.1
fm-nm-census: REJECTED repo-scoped projection for /home/shane/kun-agent-workspace reports active=0 - a repository-scoped projection cannot define the authoritative universe: a run created inside a managed run worktree is registered under its own repository id and is absent from it
$ echo $?
0
```

That is the exact global-zero green, and it is non-vacuous: the zero was taken over a universe with 59 repositories and 357 runs in it, all enumerated and counted inside one read transaction.
`universe.non_vacuous` exists so a zero over an empty database can never be mistaken for this.

## What the census guarantees, and what it does not

Guaranteed, and pinned by `tests/fm-nm-census.test.sh`:

- One WAL-consistent read transaction covers the integrity check, the schema read, the declared counts, and every row, so a run that starts or ends mid-census cannot make the counts disagree with the rows.
- Every registered repository is enumerated, nested identities included, and a nested identity is resolved to its root by WALKING the enclosing chain rather than by trimming its path; a chain with no observable enclosure keeps the identity and reports `NESTED_ROOT_UNRESOLVED`.
- Every potentially candidate-owning run joins firstmate work exactly once, or is positively `UNRELATED`, or is `AMBIGUOUS`, or is `CNO`. A terminal row is enumerated and counted and is never a candidate mutation owner, however exactly its branch and head still match.
- Duplicate primary identity, and one piece of work claimed by two candidate-owning runs, are REFUSED rather than resolved.
- Unreadable, truncated, schema-incompatible, daemon-unreachable, refusal-on-exit-zero, contradicting, and generation-moving evidence all propagate as CNO. Only a complete clean enumeration with zero candidate-owning runs may say `OBSERVED_QUIESCENT`.

Not guaranteed, and stated because the gap is the honest part:

- The corroboration read asks the daemon about the runs the DATABASE already knows about. It cannot enumerate the daemon's own view independently, because no supported AXI surface lists runs globally, so a run known only to a daemon and absent from the database would not be seen. The database is where run creation writes, which is why it is the authority here; that reasoning is the limit, not a measurement.
- `PRAGMA quick_check(1)` stops at the first problem. It is an integrity screen, not a full `integrity_check`.
- The join uses firstmate's own durable records (`state/<id>.meta`, `state/<id>.landing`, `state/<id>.attempt`) plus the branch read from each worktree's git files. A task whose records were removed cannot be joined to, which is `UNRESOLVED_GOVERNED_RUN` rather than an absence.

## Refreshing this record

```
bin/fm-nm-census.sh --scope <a registered checkout>
bin/fm-test-run.sh tests/fm-nm-census.test.sh
```

Re-run both after any no-mistakes upgrade.
A changed schema changes `generation.schema_fingerprint`, which is the signal that the counts and vocabulary above need re-observing rather than inheriting.
