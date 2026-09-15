## 1. Golden-vector infrastructure (build first — it gates every port task)

- [x] 1.1 Create `tests/golden/generate_vectors.py` that imports `sm20/` and emits
      case sets to `tests/golden/vectors.json` AND `tests/golden/vectors.lua`:
      kernel unit cases (every grade 0–5 × representative D/S/t tuples, plus
      first-review `init_new_item` per grade), M1/M2/M3/M5 unit cases, ensemble
      blend cases, finalization paths (plain pass, post-lapse with jitter stream,
      dispersal with DelphiLCG seed 0, min-growth guard incl. near-boundary
      values), Arena adaptation sequences, and multi-review `review(commit=True)`
      sequences whose per-item and collection state is serialized after every step.
      Verify: script runs clean, both output files exist, and spot-checked values
      match direct `python3 -c` invocations of the package.
- [x] 1.2 Create `tests/run_tests.lua` (pure Lua 5.1, loads vectors via
      `vectors.lua`, engine via `package.path`) and `tests/run.sh` executing it
      under both `lua5.1` and `luajit`; float comparisons at relative tolerance
      1e-9, integer outputs exact. Verify: harness runs green against a stub
      module set that implements only the tolerance/comparison plumbing (self-test
      with hand-checked expected values).

## 2. Lua port — stateless leaf modules

- [x] 2.1 Port `sm20/kernel.py` → `incrementalreading.koplugin/sm20/kernel.lua`,
      including `delphi_exp`/`delphi_ln`/`delphi_pow`, the 35 P-parameters, expert
      mixture, difficulty/stability updates, and `init_new_item`. Verify: kernel
      golden-vector cases pass under `lua5.1` and `luajit`.
- [x] 2.2 Port `sm20/model5.py`, `sm20/ensemble.py`, `sm20/weights.py` →
      `sm20/model5.lua`, `sm20/ensemble.lua`, `sm20/weights.lua`. Verify: their
      golden-vector cases pass on both interpreters.
- [x] 2.3 Port `sm20/model1.py` → `sm20/model1.lua` (item/history data as plain
      tables). Verify: M1 golden-vector cases pass, including grade-factor
      adjustment clamps for grades 3–5 and lapse reset behavior.

## 3. Lua port — stateful modules

- [x] 3.1 Port `sm20/model2.py` → `sm20/model2.lua` including
      `ClassicM2Optimizer` (matrix, grade graphs, rebuild, record-on-commit) and
      `Real48` quantization. Verify: M2 golden-vector sequences (multiple
      committed reviews sharing one optimizer) pass, and the optimizer state
      serialized after each step matches the vector.
- [x] 3.2 Port `sm20/model3.py` → `sm20/model3.lua` including `M3MatrixState`
      (all 8 arrays), matrix index math, outcome recording, and the replay path.
      Verify: M3 golden-vector sequences pass with matrix state matching after
      every step.
- [x] 3.3 Port `sm20/arena.py` → `sm20/arena.lua`: `recall_prediction`, signed
      error computation, the decoded weight update (mean-centering, `exp(0.0311 …)`
      step per constants, per-slot clamps, renormalize to 100), branch guards, and
      weight persistence fields. Verify: Arena golden-vector sequences pass —
      weights sum to 100 and stay within clamps after every step.

## 4. Lua port — pipeline and state

- [x] 4.1 Implement shared numerics per design D3/D4: `delphi_round`
      (round-half-to-even), `DelphiLCG` with LuaJIT-`bit` fast path and 16-bit-limb
      pure-Lua fallback, `gauss`. Verify: dedicated unit cases in the harness
      (banker's rounding at .5 boundaries; LCG stream matches the Python reference's
      first 100 draws from seed 0; gauss values match).
- [x] 4.2 Port `sm20/state.py` → `sm20/state.lua` (table constructors +
      to_dict/from_dict for per-item and collection state). Verify: state
      round-trip golden cases (serialize → deserialize → serialize) produce
      identical output in Lua and Python.
- [x] 4.3 Port `sm20/pipeline.py` → `sm20/pipeline.lua`: `retention_factor`,
      `dispersal`, `post_lapse`, `min_growth_guard`, `finalize`, and `review`
      (five models, ensemble vs pure-M4 selection, weight adaptation on commit,
      family/ordinal markers, full commit block). Verify: multi-review
      `review(commit=True)` golden sequences pass end-to-end — intervals exact,
      per-step state within tolerance.

## 5. Persistence and migration

- [x] 5.1 Vendor the JSON codec fallback (encode/decode for the state shapes:
      nested arrays/numbers/strings) under `sm20/json.lua`, using `rapidjson` when
      available. Verify: round-trip unit cases in the harness cover the full
      collection-state shape including empty/zero-filled arrays.
- [x] 5.2 Extend `database.lua`: new schema version, `cards.srs_state`,
      `cards.lapses`, `cards.last_reviewed_at`, single-row `collection_state`
      table; load/save helpers for per-item and collection state; keep
      `stability/difficulty/repetition` written in sync; keep the old
      `interval_matrix`/`count_matrix` tables untouched but unused. Verify:
      harness-driven test against a temp SQLite file creates, loads, and saves a
      collection blob and card states idempotently (KOReader-free sqlite stub or
      direct `sqlite3` CLI check acceptable — document which was used).
- [x] 5.3 Implement the migration path in `DB:init()` per design D6 (transaction:
      ALTER/CREATE, backfill `srs_state` from existing columns, derive `lapses`
      from the `reviews` log, preserve due dates, bump `user_version`). Verify:
      a fixture database built with the current plugin version migrates without
      error, retains cards/reviews/next_review values, and schedules on first
      review afterwards without nil errors.

## 6. Plugin integration

- [x] 6.1 Rewrite `srs_engine.lua` as the facade over `sm20/pipeline.lua`: grade
      mapping table (D2), `review`/`preview` with real elapsed days (D7),
      `formatInterval` unchanged; previews run with `commit=false` and no state
      mutation. Verify: facade unit cases in the harness — preview leaves a
      serialized snapshot of per-item + collection state byte-identical, commit
      mutates only the expected fields.
- [x] 6.2 Update `queue_view.lua`: pass elapsed days and grade mapping through the
      facade, persist per-item state with the batched flush, save collection state
      on batch and on close; preview labels use the deterministic finalized
      interval. Verify: manual smoke run of a review session (device or KOReader
      emulator) shows correct grade-button labels, records reviews, and re-opens
      with accumulated state (weights differ from defaults after enough reviews).
- [x] 6.3 Update `main.lua` call sites that used `card.stability` as an interval
      proxy to use the persisted scheduled interval; store integer SuperMemo
      grades in the `reviews` log. Verify: stats screen and card badge render
      sensible intervals after a mixed-grade session; `reviews.grade` values ∈
      {1,3,4,5}.

## 7. End-to-end verification and docs

- [x] 7.1 Run `tests/run.sh` (regenerating vectors) under `lua5.1` and `luajit`;
      fix divergences until all cases pass. Verify: script exits 0 on both
      interpreters; paste the summary line into the change notes.
- [x] 7.2 Full upgrade drill on a copy of a real plugin database: migrate → run a
      10-review session → close → reopen → confirm the post-lapse path (an
      "Again" on an established card lands in 1–11 days) and that Arena weights
      moved from the defaults. Verify: recorded observations in the change notes.
- [x] 7.3 Update the plugin README (or add one) documenting the engine's
      canonical source (`sm20/`), the grade mapping, the persistence layout, and
      how to run the parity suite. Verify: a fresh contributor can regenerate
      vectors and run the suite by following the README alone.
