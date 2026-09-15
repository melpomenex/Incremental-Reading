# Incremental Reading for KOReader

An incremental-reading / spaced-repetition plugin for
[KOReader](https://koreader.rocks): highlight text while reading to create
cards, then review them through a queue with cloze support.

## The scheduling engine

Reviews are scheduled by a **faithful Lua port of the canonical SuperMemo 20
algorithm** that lives in [`sm20/`](../sm20/) at the repository root — a
decoded, tested Python port of `sm20.exe`:

- all five Algorithm Arena competitor models run on every review
  (M1 SM-2, M2 SM-15 optimizer, M3 SM-19 matrix scheduler, M4 SM-20 kernel,
  M5 FSRS),
- the weighted ensemble blend (defaults 6/14/45/25/10) drives scheduling,
- the finalization pipeline applies the forgetting-index factor, the
  post-lapse curve, clamping, rounding, and the minimum-growth guard,
- the Arena weights adapt on every committed review using the decoded
  update rule (`FUN_00af40d0`) and persist across sessions.

The port is module-for-module identical in layout:
[`sm20/`](sm20/) here contains one `.lua` per Python module (plus `num.lua`
for shared numerics — Python-style banker's rounding, exact 32-bit math, and
CPython's Mersenne Twister — and `json.lua` for state serialization).
`srs_engine.lua` is a thin facade mapping the four grade buttons onto
SuperMemo grades:

| Button | SuperMemo grade |
|---|---|
| Again | 1 (lapse) |
| Hard  | 3 |
| Good  | 4 |
| Easy  | 5 |

## Verifying the port (parity suite)

The engine is checked against the canonical Python package with golden
vectors — no KOReader installation needed:

```sh
sh tests/run.sh
```

This regenerates the vectors (`tests/golden/generate_vectors.py` runs
`sm20/`), runs the Lua parity harness (`tests/run_tests.lua`) and the
database upgrade drill (`tests/run_db_drill.lua`) under every available Lua
interpreter (`lua5.1`, `luajit`). Integer outputs (intervals, indices,
counts) must match exactly; floats match within a 1e-9 relative tolerance.

To regenerate vectors only:

```sh
python3 tests/golden/generate_vectors.py
```

## Persistence layout

Scheduling state lives in the plugin's SQLite database:

- `cards.srs_state` — the full per-item canonical state as JSON (DSR values,
  M1/M2/M3 sub-states, prior-review model predictions, lapse markers),
  kept in sync with the plain `stability` / `difficulty` / `repetition` /
  `lapses` / `interval_days` / `last_reviewed_at` columns,
- `collection_state` (single row) — the collection-wide state as JSON:
  the M2 optimizer, the M3 matrices, and the adapted Arena weights,
- `reviews` — the review log; `grade` stores the integer SuperMemo grade
  (1/3/4/5; historical rows from the previous engine keep the old float
  scale),
- the previous engine's `interval_matrix` / `count_matrix` tables are left
  in place but unused, so rolling back to the old plugin version stays
  possible.

Databases created by the previous plugin version are migrated in place on
first load: due dates and review history are preserved, per-card canonical
state is backfilled (lapses derived from the old "again" grades), and the
canonical repetition counter is the old one minus one.

## Repository layout

- `incrementalreading.koplugin/` — the plugin (`main.lua`, `queue_view.lua`,
  `database.lua`, `srs_engine.lua`, and the `sm20/` engine port)
- `sm20/` — the canonical Python reference implementation (do not edit the
  Lua port to change scheduling behavior without changing it here first;
  then regenerate the golden vectors)
- `tests/` — the parity suite (see above)
