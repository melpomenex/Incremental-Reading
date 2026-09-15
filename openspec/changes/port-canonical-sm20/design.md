## Context

See `proposal.md` for motivation. The relevant current state:

- Canonical reference: the `sm20/` Python package at repo root (~4,000 lines, decoded
  from `sm20.exe`, importable and runnable here via `python3`). Entry points:
  `sm20.pipeline.review(state, grade, elapsed_days, fi, collection, today, ...)` with
  per-item `SM20State` and per-collection `SM20CollectionState` dataclasses.
- Plugin: `incrementalreading.koplugin/srs_engine.lua` (~370 lines) implements an old
  simplified single-model engine; `queue_view.lua` calls `review`/`preview`/
  `recordIntoMatrix`; `database.lua` persists `cards(stability, difficulty, repetition)`,
  a `reviews` log, and the old engine's `interval_matrix`/`count_matrix` tables;
  `main.lua` reads `card.stability` for display.
- Runtime: KOReader runs LuaJIT (Lua 5.1 semantics + `bit` library). `lua5.1` and
  `luajit` are available locally for testing; `python3` can execute the canonical
  package to generate reference outputs.

## Goals / Non-Goals

**Goals:**

- A module-by-module Lua port of `sm20/` whose outputs are numerically indistinguishable
  from the Python package for the same inputs.
- Durable, migratable persistence of the full per-item and per-collection scheduling
  state in the existing SQLite database.
- A no-KOReader test harness that proves parity via golden vectors generated from the
  canonical package.

**Non-Goals:**

- Porting `sm20/dat_files.py` (SuperMemo `.dat` import) and the opt-in R-Metric/LSRM
  diagnostics; only the weight adaptation the Arena blend needs is ported.
- New UI: no forgetting-index editor, no priority-percent input, no pure-M4 toggle in
  the UI (the pipeline flag is ported but defaults to off).
- Changing card management, cloze handling, or anything else `queue_view.lua` does
  besides the scheduling call sites.

## Decisions

### D1: Lua package mirrors the Python package file-for-file

Create `incrementalreading.koplugin/sm20/` with one `.lua` per Python module —
`kernel.lua`, `model1.lua`, `model2.lua`, `model3.lua`, `model5.lua`, `ensemble.lua`,
`weights.lua`, `arena.lua`, `pipeline.lua`, `state.lua` — each carrying the Python
module's docstring-provenance header in condensed form. `srs_engine.lua` remains as a
thin facade so `queue_view.lua`/`main.lua` keep a stable require, but its bespoke math
is deleted. A 1:1 file map makes parity review against the reference mechanical and
keeps future upstream fixes to `sm20/` directly diffable. Alternative rejected: one
monolithic engine file (harder to audit against the reference, recreates the current
problem).

### D2: Grade mapping is a single table — again→1, hard→3, good→4, easy→5

SuperMemo grades are 0–5 with `<3` = lapse everywhere in the pipeline; `3/4/5` receive
distinct grade factors in the kernel and M1. "Again" maps to grade 1 ("incorrect,
recalled with difficulty") — the conventional fail mapping in SM-derived tools; grade 2
maps to a surprisingly generous first-review stability (P[8]=9.17) and grade 0 to a
"blackout" we can't distinguish in a two-state reveal. Grades 0 and 2 stay unused.
The mapping lives in one table in `srs_engine.lua` so revisiting it is a one-line
change. Recorded as an assumption; it is the only place the four-button UI touches the
0–5 grade scale.

### D3: Delphi numerics — port the emulation helpers and rounding exactly

The kernel's `delphi_exp`/`delphi_ln`/`delphi_pow` (x87 80-bit / negative-base `pow`
semantics) are ported verbatim; plain `math.exp/log/^` are not substituted where the
reference uses the emulated variants. Delphi `Round` is banker's rounding
(round-half-to-even), matching Python 3's `round()`; Lua has neither built in, so a
shared `delphi_round(v)` helper is implemented once and used for every `round` in
`pipeline.lua` (finalization, min-growth guard). This is the single most likely source
of off-by-one intervals if botched.

### D4: DelphiLCG with a portable uint32 multiply

The reference PRNG (`state * 0x08088405 + 1 mod 2^32`) exceeds 2^53 in intermediate
products, so Lua doubles alone can't mask it. Use the LuaJIT `bit` library when present
(KOReader always has it) and a 16-bit-limb pure-Lua multiply fallback so the standalone
harness runs on plain `lua5.1`. Seeding follows the reference default (seed 0, fresh
stream per finalization call), which keeps the canonical default deterministic:
post-lapse jitter and dispersal produce reproducible values, and previews equal
committed results. Alternative rejected: seeding from `os.time()` per run — would break
preview/commit agreement, which the specs require.

### D5: Dispersal off, post-lapse on — matching the reference defaults

`pipeline.review` defaults `disperse=False`; the plugin adopts the same default for
both preview and commit (spec: deterministic previews). The post-lapse path is not
optional (grade < 3 on an item with a prior repetition always takes it) and its
Gaussian jitter rides the deterministic D4 stream. FI stays the canonical default 10;
`post_lapse_x` (priority percent) is fixed at 0 (no priority concept in the plugin).

### D6: Persistence — JSON blobs in SQLite, old matrix tables retired in place

- `cards` gains `srs_state TEXT` (JSON of the per-item state: DSR values, counters,
  M1/M2/M3 sub-states, `slot_stabilities`, lapse markers, `last_reviewed_at` epoch) and
  `lapses INTEGER`. The existing `stability/difficulty/repetition` columns are kept and
  written in sync (they feed stats and migration).
- A new single-row `collection_state` table holds one JSON blob: the M2 optimizer, the
  M3 matrices (8 arrays), and the Arena weights. Dense arrays ≈ 35k numbers (~300 KB
  JSON worst case) — acceptable for a once-per-session load and batch-bound flush on
  SQLite; sparse encoding is a later optimization if e-ink devices prove slow.
- JSON over Lua-serialization for cross-tool debuggability. Encoding uses KOReader's
  bundled `rapidjson` when available with a small vendored pure-Lua codec as fallback,
  so the standalone test harness has no KOReader dependency.
- Migration (bump `PRAGMA user_version`): add columns/table, backfill `srs_state` from
  existing `stability/difficulty/repetition` (`repetition − 1` into the canonical
  zero-based counter; `lapses` derived from the `reviews` log's fail grades when
  present, else 0; sub-states left at canonical defaults), preserve `next_review` due
  dates. The old `interval_matrix`/`count_matrix` tables are left in place, unused
  (rollback to the previous plugin version stays possible); dropping them is deferred
  to a future change.
- Flush strategy unchanged: per-review state mutates in memory; card rows + collection
  blob flush transactionally with the existing 10-review batch and on session close
  (spec: interrupted-session consistency).

### D7: Elapsed days and the day counter come from stored timestamps

`cards.last_reviewed_at` (UTC epoch seconds, written on flush) yields
`elapsed_days = (now − last_reviewed_at)/86400` (0 for never-reviewed). `today` for the
M1/M2/M3 day-stamped state is `floor(os.time()/86400)` (days since Unix epoch) — only
differences matter. This fixes the current bug-class where the engine is fed
`card.stability` as elapsed time. `queue_view.lua` passes the real value; the facade
keeps accepting the old call shape internally.

### D8: Parity via generated golden vectors in two formats

`tests/golden/generate_vectors.py` imports `sm20/` and emits, for each case, inputs and
expected outputs: kernel unit cases (all grades × representative D/S/t), each model's
unit cases, ensemble/finalization paths (pass, post-lapse, min-growth, dispersal
deterministic stream), Arena adaptation sequences, and multi-review `review(commit=
true)` sequences carrying full state between steps (state serialized after each step
and compared, not just intervals). It writes both `vectors.json` (inspectable) and
`vectors.lua` (a Lua module) — the Lua harness then needs no JSON parser.
`tests/run_tests.lua` + `tests/run.sh` run the harness under both `lua5.1` and `luajit`
with only `package.path` pointing at the plugin directory. Integer outputs (intervals)
compare exactly; floats compare with relative tolerance 1e-9 (libm differences between
Python and device C libraries).

### D9: Lua 5.1-compatible dialect throughout the port

No `goto`, no 5.2+ syntax, no `bit` dependency without fallback, `math.fmod`-style
helpers where needed — so the same files run under `lua5.1` (harness) and LuaJIT
(KOReader). The current `srs_engine.lua` uses `goto continue`, which is fine to lose.

## Risks / Trade-offs

- [libm divergence shifts a rounding boundary → off-by-one interval vs the Python
  reference] → tolerance policy (D8) accepts <1e-9 relative drift on floats; golden
  vectors deliberately include near-boundary cases so any systematic (not
  epsilon-level) divergence fails loudly.
- [First-review interval growth under canonical init values surprises existing users]
  → accepted: intervals change by design (**BREAKING** in proposal); migration keeps
  due dates so no card floods the queue on upgrade.
- [300 KB JSON blob rewrite per flush on slow e-ink devices] → flushes are
  batch-bound (10 reviews / session close); measure during apply; sparse encoding is a
  contained follow-up behind the same `collection_state` interface.
- [Port volume (~4k lines Python → ~4k lines Lua) invites transcription slips] →
  1:1 module map (D1), per-module golden vectors unlocked incrementally (D8), and
  vector generation is the first task, not the last.
- [`rapidjson` absent on an exotic KOReader build] → vendored codec fallback (D6);
  encode/decode round-trip is itself a golden-vector case.

## Migration Plan

1. Ship the port with `DB_SCHEMA_VERSION` bumped; `DB:init()` detects old versions and
   runs the D6 migration inside one transaction (`ALTER TABLE cards …`,
   `CREATE TABLE collection_state …`, backfills, `PRAGMA user_version`).
2. Rollback: reinstalling the previous plugin version works — it ignores
   `srs_state`/`collection_state`, and the old matrix tables were never dropped; the
   old engine reads `stability/difficulty/repetition`, which the new engine keeps
   writing in sync.
3. No server or export format changes; the `reviews` log keeps its schema (grade
   column now stores the integer SuperMemo grade; old float grades remain readable
   as historical rows).

## Open Questions

- None blocking. The again→1 mapping (D2) is the one judgment call users might
  reasonably contest; it is isolated to a single table and covered by spec scenarios.
