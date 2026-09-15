# Implementation notes — port-canonical-sm20

## Parity suite (task 7.1)

Final `sh tests/run.sh` result (regenerated vectors, all suites, all
interpreters):

- `lua5.1`  — `Total: 1124 passed, 0 failed, 0 suite(s) skipped`
- `luajit`  — `Total: 1124 passed, 0 failed, 0 suite(s) skipped`
- `lua 5.5` — `Total: 1124 passed, 0 suite(s) skipped` (same 1124/0)

Suite breakdown (per interpreter): numerics 158, kernel 49, model5 144,
ensemble 12, model1 16, model2 214, model3 165, arena 25, state 28,
pipeline_finalize 47, pipeline_review 247, json round-trip 7 (incl. harness
self-checks). Integer outputs exact; floats at 1e-9 relative tolerance.

## DB upgrade drill (task 7.2)

`lua5.1 tests/run_db_drill.lua` (and `luajit`): `DRILL PASSED: 27 passed, 0
failed`. Method: KOReader-free via `tests/stub/` — a sqlite3-CLI-backed
`lua-ljsqlite3` stub plus `datastorage`/`device` stubs (documented choice
per task 5.2; the stub autocommits each statement, so transaction atomicity
is not exercised — outcomes are).

Observations recorded during the drill:

- Migration: all four new columns added; old `interval_matrix`/
  `count_matrix` left in place; `user_version` 20260530 → 20260915; due
  dates preserved; lapses derived from old float "again" grades (grade <
  0.3); canonical state backfilled for all cards with `repetition` shifted
  by one and `last_review_day` seeded from the recovered review instant.
- Session: grades stored as integers {1,3,4,5}; post-lapse intervals for
  "Again" on established cards landed in 1..11 days; previews deterministic
  and non-mutating; Arena weights moved off the defaults and still summed
  to 100.
- Reopen: collection state (incl. adapted weights) round-tripped exactly;
  cards rescheduled into the future; persisted card state showed the
  canonical lapse flow (rep 4 → pass 5 → lapse 1 → pass 2, lapses 2);
  prior-review slot predictions persisted for arena scoring.

## Caveat (task 6.2)

No KOReader installation or emulator was available in this environment, so
the on-device visual smoke run was not performed. The grade-button labels
come from the same facade preview path the drill exercises (deterministic,
non-mutating); `queue_view.lua` and `main.lua` pass a Lua 5.1 parse and all
engine/DB paths are covered by the automated suites. A quick manual session
on a device remains recommended before release.

## Notable implementation decisions beyond design.md

- CPython's `random.Random(0)` (MT19937, `init_by_array` with key `{0}`) is
  ported exactly in `sm20/num.lua` because M2's capped-U-bin tail fix
  consumes that stream when no RNG is passed (Python: `rng or
  random.Random(0)`). The numerics suite pins the first 64 draws exactly.
- `tests/stub/lua-ljsqlite3` implements the ljsqlite3 API subset over the
  `sqlite3` CLI (column-major `exec`, positional `step`, chained
  `clearbind():reset()`), which is what made the drill possible without
  KOReader's C bindings.
