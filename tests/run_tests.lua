-- Lua parity harness for the sm20 Lua port.
--
-- Pure Lua 5.1 (also runs under LuaJIT). Loads tests/golden/vectors.lua
-- (generated from the canonical Python package) and compares the Lua port's
-- outputs against it. Suites whose Lua module is not present yet are SKIPPED,
-- so the harness is runnable at every stage of the port.
--
-- Comparison rules (matching tests/golden/generate_vectors.py conventions):
--   * expected integer values (exp % 1 == 0) compare EXACTLY;
--   * expected floats compare with relative tolerance 1e-9
--     (abs tol 1e-9 for values near zero);
--   * tables must have identical key sets on both sides;
--   * JSON null / Python None is dropped by the vector emitter, so an
--     expected-absent key means the Lua side must also omit the field
--     (nil-valued fields must not appear in Lua to_dict output).
--
-- Usage: lua5.1 tests/run_tests.lua   (or: luajit tests/run_tests.lua)

local script = arg and arg[0] or "tests/run_tests.lua"
local root = script:match("^(.*)tests[/\\]run_tests%.lua$") or "./"
if root == "" then root = "./" end
package.path = root .. "incrementalreading.koplugin/?.lua;" ..
    root .. "tests/?.lua;" .. package.path

local vectors = dofile(root .. "tests/golden/vectors.lua")

-- ---------------------------------------------------------------------------
-- comparator + reporting
-- ---------------------------------------------------------------------------

local pass_count, fail_count, skip_count = 0, 0, 0
local failures = {}

local function fmt(v)
  if type(v) == "number" then return string.format("%.17g", v) end
  return tostring(v)
end

local function num_equal(got, exp)
  if exp % 1 == 0 then
    return got == exp
  end
  local tol = 1e-9 * math.max(1.0, math.abs(exp))
  return math.abs(got - exp) <= tol
end

local function is_array(t)
  local n = #t
  if n == 0 then
    -- empty: array iff no other keys
    for _ in pairs(t) do return false end
    return true
  end
  for i = 1, n do
    if t[i] == nil then return false end
  end
  return true
end

local function deep_cmp(got, exp, path, errs)
  local tg, te = type(got), type(exp)
  if te == "number" then
    if tg ~= "number" then
      errs[#errs + 1] = string.format("%s: expected number %s, got %s (%s)",
        path, fmt(exp), fmt(got), tg)
    elseif not num_equal(got, exp) then
      errs[#errs + 1] = string.format("%s: expected %s, got %s",
        path, fmt(exp), fmt(got))
    end
    return
  end
  if te == "string" or te == "boolean" then
    if got ~= exp then
      errs[#errs + 1] = string.format("%s: expected %s, got %s",
        path, fmt(exp), fmt(got))
    end
    return
  end
  if te == "nil" then
    if got ~= nil then
      errs[#errs + 1] = string.format("%s: expected nil, got %s", path, fmt(got))
    end
    return
  end
  if te ~= "table" or tg ~= "table" then
    errs[#errs + 1] = string.format("%s: expected table, got %s/%s", path, tg, te)
    return
  end
  -- expected table (array or object): require identical key sets
  for k, v in pairs(exp) do
    local g = got[k]
    if g == nil and v ~= nil and type(v) ~= "table" then
      -- a nested expected table with zero-length arrays still needs a table
      errs[#errs + 1] = string.format("%s.%s: missing in got", path, tostring(k))
    else
      deep_cmp(g, v, path .. "." .. tostring(k), errs)
    end
  end
  for k in pairs(got) do
    if exp[k] == nil then
      errs[#errs + 1] = string.format("%s.%s: unexpected extra field in got",
        path, tostring(k))
    end
  end
end

local function check(name, got, exp)
  local errs = {}
  deep_cmp(got, exp, name, errs)
  if #errs == 0 then
    pass_count = pass_count + 1
    return true
  end
  fail_count = fail_count + 1
  for i = 1, math.min(#errs, 3) do
    failures[#failures + 1] = errs[i]
  end
  return false
end

local function check_true(name, cond, detail)
  if cond then
    pass_count = pass_count + 1
  else
    fail_count = fail_count + 1
    failures[#failures + 1] = name .. (detail and (": " .. detail) or "")
  end
end

-- digest matching generate_vectors.py: flatten nested arrays in index order
local function digest(x)
  local n, sum, sumsq = 0, 0.0, 0.0
  local function rec(t)
    if type(t) == "number" then
      n = n + 1
      sum = sum + t
      sumsq = sumsq + t * t
    elseif type(t) == "table" then
      for i = 1, #t do rec(t[i]) end
    end
  end
  rec(x)
  return { n = n, sum = sum, sumsq = sumsq }
end

local function try_require(mod)
  local ok, m = pcall(require, mod)
  if ok then return m end
  return nil
end

-- JSON codec round-trip checks (fallback codec when rapidjson is absent).
local function json_selftest()
  local json = try_require("sm20.json")
  if not json then return end
  local ST = try_require("sm20.state")
  local P = try_require("sm20.pipeline")

  local cases = {
    { 1, 2.5, -3.75, 0.1, 1e-7, 123456789, 44530, 0.30000000000000004 },
    { "a", 'b"c', "d\\e", "line\nbreak", "" },
    { true, false },
    { nested = { { 1.5, 2.5 }, { 3, 4 } }, x = 1.0 / 3.0, big = 2.0 ^ 42 },
    {},  -- empty object encodes as {}
  }
  for i, v in ipairs(cases) do
    local text = json.encode(v)
    local back = json.decode(text)
    check("json.roundtrip[" .. i .. "]", back, v)
  end

  if not ST then return end
  local coll = ST.new_collection_state()
  local st = ST.new_item_state()
  if P then
    P.review(st, 4, 0.0, 10, coll, 10, { commit = true })
    P.review(st, 3, 1.0, 10, coll, 11, { commit = true })
  end
  local coll_dict = ST.collection_to_dict(coll)
  local reloaded = ST.collection_from_dict(json.decode(json.encode(coll_dict)))
  check("json.collection-roundtrip", ST.collection_to_dict(reloaded), coll_dict)
  local item_dict = ST.item_to_dict(st)
  local reloaded_item = ST.item_from_dict(json.decode(json.encode(item_dict)))
  check("json.item-roundtrip", ST.item_to_dict(reloaded_item), item_dict)
end

-- ---------------------------------------------------------------------------
-- comparator self-test (hand-checked expectations)
-- ---------------------------------------------------------------------------

local function selftest()
  check("selftest.float-tolerance", 0.1 + 0.2, 0.3)  -- 0.30000000000000004 vs 0.3
  check("selftest.int-exact", 5, 5)
  check("selftest.negative-int", -2, -2)
  check("selftest.string", "abc", "abc")
  check("selftest.table", { a = 1.5, b = { 2.5, 3.5 } },
    { a = 1.5, b = { 2.5, 3.5 } })
  check("selftest.expected-nil", nil, nil)

  -- these MUST fail: verify via direct num_equal instead of check()
  local ok1 = num_equal(6, 5)            -- int mismatch
  local ok2 = num_equal(0.300001, 0.3)   -- float beyond tolerance
  local ok3 = num_equal(0.5, 0.49999999999999994) -- within tolerance (ok=true)
  check_true("selftest.int-mismatch-detected", ok1 == false)
  check_true("selftest.float-mismatch-detected", ok2 == false)
  check_true("selftest.float-within-tol", ok3 == true)

  local errs = {}
  deep_cmp({ a = 1 }, { a = 1, b = 2 }, "x", errs)
  check_true("selftest.missing-key-detected", #errs == 1 and errs[1]:find("missing") ~= nil)
  local errs2 = {}
  deep_cmp({ a = 1, z = 9 }, { a = 1 }, "y", errs2)
  check_true("selftest.extra-key-detected", #errs2 == 1 and errs2[1]:find("extra") ~= nil)

  local d = digest({ 1, { 2, 3 }, { { 4 } } })
  check("selftest.digest", d, { n = 4, sum = 10.0, sumsq = 30.0 })
end

-- ---------------------------------------------------------------------------
-- suite runners
-- ---------------------------------------------------------------------------

local runners = {}

runners.numerics = function(S)
  local num = try_require("sm20.num")
  local pipeline = try_require("sm20.pipeline")
  local ran = false
  if num then
    ran = true
    for _, c in ipairs(S.round) do
      check("numerics.round(" .. fmt(c.x) .. ")", num.py_round(c.x), c.y)
    end
    if num.CPythonRandom then
      local mt = num.CPythonRandom.new(0)
      for i, y in ipairs(S.mtrand_draws) do
        check("numerics.mtrand[" .. i .. "]", mt:random(), y)
      end
    end
  end
  if pipeline then
    ran = true
    local rng = pipeline.DelphiLCG.new(0)
    for i, y in ipairs(S.lcg_draws) do
      check("numerics.lcg[" .. i .. "]", rng:random(), y)
    end
    local rng2 = pipeline.DelphiLCG.new(0)
    for i, y in ipairs(S.lcg_gauss) do
      check("numerics.lcg_gauss[" .. i .. "]", rng2:gauss(), y)
    end
  end
  return ran
end

runners.kernel = function(S)
  local K = try_require("sm20.kernel")
  if not K then return false end
  for g = 0, 5 do
    check("kernel.init[" .. g .. "]", K.init_new_item(g), S.init[tostring(g)])
  end
  for i, c in ipairs(S.review) do
    local inp = c.input
    local out = K.review_kernel(inp.t, inp.grade, inp.D, inp.S)
    -- the generator folds compute_interval into each review case; Python's
    -- review_kernel itself does not return it
    out.interval = K.compute_interval(out.S_new)
    check("kernel.review[" .. i .. "]", out, c.expected)
  end
  for i, c in ipairs(S.interval) do
    check("kernel.interval[" .. i .. "]", K.compute_interval(c.S), c.interval)
  end
  return true
end

runners.model5 = function(S)
  local M = try_require("sm20.model5")
  if not M then return false end
  for i, c in ipairs(S.cases) do
    local inp = c.input
    check("model5[" .. i .. "]", M.model_5(inp.t, inp.grade, inp.S_old), c.expected)
  end
  return true
end

runners.ensemble = function(S)
  local E = try_require("sm20.ensemble")
  if not E then return false end
  for i, c in ipairs(S.cases) do
    local inp = c.input
    local w = inp.weights
    if w == "default" then w = nil end
    check("ensemble[" .. i .. "]",
      E.ensemble_stability(inp.m1, inp.m2, inp.m3, inp.m4, inp.m5, w), c.expected)
  end
  return true
end

runners.model1 = function(S)
  local M = try_require("sm20.model1")
  if not M then return false end
  for _, key in ipairs({ "fresh", "history" }) do
    local item = M.new_item_state()
    local history = nil
    for i, step in ipairs(S[key]) do
      local inp = step.input
      local res = M.model_1(item, inp.today, inp.grade, history)
      check("model1." .. key .. "[" .. i .. "]", res, step.expected)
      item = res.next_item
      if key == "history" then history = res.next_history end
    end
  end
  return true
end

runners.model2 = function(S)
  local M = try_require("sm20.model2")
  if not M then return false end
  for i, y in ipairs(S.axis) do
    check("model2.axis[" .. i .. "]", M.a_axis(i), y)
  end
  for i, c in ipairs(S.fresh_optimum) do
    check("model2.fresh_optimum[" .. i .. "]", M.fresh_optimum(c.a, c.r), c.value)
  end
  for i, c in ipairs(S.u_value_bucket) do
    check("model2.u_value[" .. i .. "]", M.u_value(c.a, c.r, c.bin), c.value)
    check("model2.u_bucket[" .. i .. "]", M.u_bucket(c.a, c.r, c.value), c.bucket)
  end
  for i, c in ipairs(S.bucket_edge) do
    check("model2.bucket_edge[" .. i .. "]", M.u_bucket(c.a, c.r, c.value), c.bucket)
  end

  -- seq_full: full optimizer snapshot per step
  local opt = M.ClassicM2Optimizer.new()
  local item = M.new_item_state()
  for i, step in ipairs(S.seq_full) do
    local inp = step.input
    local res = M.model_2(item, opt, inp.today, inp.grade, { commit = true })
    check("model2.seq_full.result[" .. i .. "]", res, step.expected)
    check("model2.seq_full.optimizer[" .. i .. "]", opt:to_dict(), step.optimizer)
    item = res.next_item
  end

  -- seq_digest: digest per step, full snapshot at the end
  local opt_b = M.ClassicM2Optimizer.new()
  local item_b = M.new_item_state()
  for i, step in ipairs(S.seq_digest) do
    local inp = step.input
    local res = M.model_2(item_b, opt_b, inp.today, inp.grade, { commit = true })
    check("model2.seq_digest.result[" .. i .. "]", res, step.expected)
    for field, d in pairs(step.digest) do
      check("model2.seq_digest." .. field .. "[" .. i .. "]",
        digest(opt_b[field]), d)
    end
    item_b = res.next_item
  end
  check("model2.seq_digest.final", opt_b:to_dict(), S.seq_digest_final)

  -- preview: commit=false must not mutate the optimizer
  local opt_p = M.ClassicM2Optimizer.new()
  local item_p = M.new_item_state()
  local res = M.model_2(item_p, opt_p, 10, 4, { commit = true })
  item_p = res.next_item
  local before = digest(opt_p:to_dict())
  local prev = M.model_2(item_p, opt_p, 20, 4, { commit = false })
  check("model2.preview.result", prev, S.preview.result)
  check("model2.preview.optimizer-unchanged", digest(opt_p:to_dict()), before)
  return true
end

runners.model3 = function(S)
  local M = try_require("sm20.model3")
  if not M then return false end
  local function run_mapper(name, fn)
    for i, c in ipairs(S.mappers[name]) do
      check("model3." .. name .. "[" .. i .. "]", fn(c.x or c.j or c.i), c.y)
    end
  end
  run_mapper("r_index", M.r_index)
  run_mapper("s_index", M.s_index)
  run_mapper("d_index", M.d_index)
  run_mapper("stability_axis", function(j) return M.stability_axis_value(j) end)
  run_mapper("interval_axis", function(i) return M.interval_axis_value(i) end)
  run_mapper("interval_category", M.interval_category)

  -- synthetic matrices per the generator's documented recipe: full 21^3
  -- zero-filled arrays, then the r,s,d in 1..20 subcube filled in (cells
  -- with an axis at 20 and the tail stay zero, matching Python's [0.0]*n)
  local n = 21 * 21 * 21
  local im, cm = {}, {}
  for i = 1, n do im[i] = 0.0; cm[i] = 0 end
  for r = 1, 20 do
    for s = 1, 20 do
      for d = 1, 20 do
        local off = (r - 1) * 441 + (s - 1) * 21 + (d - 1) + 1
        local s_center = math.log(s) / math.log(20.0) * 0.64 + 0.3
        im[off] = math.max(1.0, s_center * r * (20 - d + 1) * 0.5)
        cm[off] = math.max(1, (r * s) % 50)
      end
    end
  end
  check("model3.synthetic.digest", digest(im), S.synthetic.check.digest)
  check("model3.synthetic.first", { im[1], im[2], im[3], im[4], im[5] }, S.synthetic.check.first)
  check("model3.synthetic.last",
    { im[n - 4], im[n - 3], im[n - 2], im[n - 1], im[n] }, S.synthetic.check.last)
  check("model3.synthetic.count_digest", digest(cm), S.synthetic.check.count_digest)

  for i, c in ipairs(S.w3) do
    local inp = c.input
    local out = M.w3_model_path({
      t = inp.t, reps = inp.reps, lapses = inp.lapses, grade = inp.grade,
      D = inp.D, S_old = inp.S_old, old_interval = inp.old_interval,
      R = inp.R, interval_matrix = im, count_matrix = cm, prev_S = inp.prev_S,
    })
    check("model3.w3[" .. i .. "]", out, c.expected)
  end

  local matrices = M.new_matrix_state()
  local item = M.new_item_state()
  for i, step in ipairs(S.stateful.steps) do
    local inp = step.input
    local res = M.model_3_stateful(item, matrices, inp.today, inp.grade,
      { commit = true })
    check("model3.stateful.result[" .. i .. "]", res, step.expected)
    for field, d in pairs(step.digest) do
      check("model3.stateful." .. field .. "[" .. i .. "]",
        digest(matrices[field]), d)
    end
    item = res.next_item
  end
  check("model3.stateful.final", matrices:to_dict(), S.stateful.final)
  return true
end

runners.arena = function(S)
  local A = try_require("sm20.arena")
  if not A then return false end
  for i, c in ipairs(S.adapt) do
    local w = {}
    for j, v in ipairs(c.input.weights) do w[j] = v end
    A.adapt_weights(w, c.input.errors)
    check("arena.adapt[" .. i .. "]", w, c.expected)
  end
  for i, c in ipairs(S.errors) do
    check("arena.errors[" .. i .. "]",
      A.compute_model_errors(c.input.r, c.input.recalled), c.expected)
  end
  for i, c in ipairs(S.recall_prediction) do
    check("arena.recall[" .. i .. "]", A.recall_prediction(c.s, c.t), c.y)
  end
  local st = A.ArenaState.new()
  for i, step in ipairs(S.observe) do
    local inp = step.input
    st:observe(inp.slots, inp.elapsed, inp.recalled, inp.repetition_count)
    check("arena.observe[" .. i .. "]", st:to_dict(), step.expected)
  end
  local guard = A.ArenaState.new()
  guard:observe({ 2.0, 3.0, 5.0, 6.0, 4.0 }, 3.0, true, 0.0)
  guard:observe({ 2.0, 3.0, 5.0, 6.0, 4.0 }, 0.0, true, 5.0)
  guard:observe({ 2.0, 3.0, 0.0, 6.0, 4.0 }, 3.0, true, 5.0)
  check("arena.guards_noop", { weights = guard.weights,
    total_scored = guard.total_scored }, S.guards_noop)
  return true
end

runners.state = function(S)
  local ST = try_require("sm20.state")
  if not ST then return false end
  check("state.item_default", ST.item_to_dict(ST.new_item_state()), S.item_default)
  local it = ST.new_item_state()
  it.stability = 12.5
  it.difficulty = 0.33
  it.repetition = 7
  it.lapses = 2
  it.interval = 15.0
  it.post_lapse_family = 2
  it.lapse_ordinal = 1
  it.slot_stabilities = { 3.0, 4.0, 5.0, 6.0, 7.0 }
  it.m1_history = { factor = 2.1, stability = 9.0 }
  it.m2_state.last_review_day = 40
  it.m2_state.previous_interval = 6
  it.m2_state.repetitions = 3
  it.m2_state.lapses = 1
  it.m2_state.a_factor = 3.4
  it.m2_state.u_factor = 2.2
  it.m3_state.last_review_day = 40
  it.m3_state.previous_interval = 6
  it.m3_state.repetitions = 3
  it.m3_state.lapses = 1
  it.m3_state.stability = 9.5
  it.m3_state.difficulty = 0.4
  it.m3_state.previous_stability = 7.0
  it.m3_state.previous_stability_index = 8
  it.m3_state.previous_r_index = 17
  check("state.item_mutated", ST.item_to_dict(it), S.item_mutated)

  local coll = ST.new_collection_state()
  check("state.collection_arena", coll.arena:to_dict(), S.collection_default.arena)
  for field, d in pairs(S.collection_default.m2_digest) do
    check("state.m2_digest." .. field, digest(coll.m2_optimizer[field]), d)
  end
  for field, d in pairs(S.collection_default.m3_digest) do
    check("state.m3_digest." .. field, digest(coll.m3_matrices[field]), d)
  end
  local m2 = coll.m2_optimizer
  check("state.m2.matrix_row1", m2.matrix[1], S.m2_default_snippet.matrix_row1)
  check("state.m2.matrix_row20", m2.matrix[20], S.m2_default_snippet.matrix_row20)
  check("state.m2.first_grade", m2.first_grade, S.m2_default_snippet.first_grade)
  check("state.m2.second_grade", m2.second_grade, S.m2_default_snippet.second_grade)
  check("state.m2.row_exponent", m2.row_exponent, S.m2_default_snippet.row_exponent)
  check("state.m2.row_weight", m2.row_weight, S.m2_default_snippet.row_weight)
  return true
end

runners.pipeline_finalize = function(S)
  local P = try_require("sm20.pipeline")
  if not P then return false end
  for i, c in ipairs(S.retention_factor) do
    check("finalize.retention_factor[" .. i .. "]", P.retention_factor(c.fi), c.y)
  end
  for i, c in ipairs(S.dispersal) do
    local rng = P.DelphiLCG.new(0)
    check("finalize.dispersal[" .. i .. "]", P.dispersal(c.adjusted, rng), c.y)
  end
  for i, c in ipairs(S.post_lapse) do
    local rng = P.DelphiLCG.new(0)
    check("finalize.post_lapse[" .. i .. "]", P.post_lapse(c.adjusted, c.x, rng), c.y)
  end
  for i, c in ipairs(S.min_growth_guard) do
    check("finalize.min_growth_guard[" .. i .. "]",
      P.min_growth_guard(c.interval, c.used), c.y)
  end
  for i, c in ipairs(S.finalize) do
    local inp = c.input
    local rng = P.DelphiLCG.new(0)
    local out = P.finalize(inp.ensemble, inp.fi, {
      post_lapse_mode = inp.post_lapse,
      post_lapse_x = inp.post_lapse_x or 0.0,
      disperse = inp.disperse,
      rng = rng,
      used_interval = inp.used,
      min_growth = inp.min_growth,
    })
    check("finalize.finalize[" .. i .. "]", out, c.expected)
  end
  return true
end

runners.pipeline_review = function(S)
  local P = try_require("sm20.pipeline")
  local ST = try_require("sm20.state")
  if not P or not ST then return false end

  local function arena_dict(coll)
    return coll.arena:to_dict()
  end

  local state = ST.new_item_state()
  local collection = ST.new_collection_state()
  for i, step in ipairs(S.seq) do
    local inp = step.input
    local res = P.review(state, inp.grade, inp.elapsed, inp.fi, collection,
      inp.today, { commit = true })
    check("review.seq.result[" .. i .. "]", P.result_to_dict(res), step.expected)
    check("review.seq.state[" .. i .. "]", ST.item_to_dict(state), step.state)
    check("review.seq.arena[" .. i .. "]", arena_dict(collection), step.arena)
    for field, d in pairs(step.m2_digest) do
      check("review.seq.m2." .. field .. "[" .. i .. "]",
        digest(collection.m2_optimizer[field]), d)
    end
    for field, d in pairs(step.m3_digest) do
      check("review.seq.m3." .. field .. "[" .. i .. "]",
        digest(collection.m3_matrices[field]), d)
    end
  end
  check("review.final.m2", collection.m2_optimizer:to_dict(), S.final_collection.m2_optimizer)
  check("review.final.m3", collection.m3_matrices:to_dict(), S.final_collection.m3_matrices)
  check("review.final.arena", arena_dict(collection), S.final_collection.arena)

  local state_b = ST.new_item_state()
  local collection_b = ST.new_collection_state()
  for i, step in ipairs(S.seq_pure_m4) do
    local inp = step.input
    local res = P.review(state_b, inp.grade, inp.elapsed, inp.fi, collection_b,
      inp.today, { commit = true, pure_m4 = true })
    check("review.pure_m4.result[" .. i .. "]", P.result_to_dict(res), step.expected)
    check("review.pure_m4.state[" .. i .. "]", ST.item_to_dict(state_b), step.state)
  end

  -- previews: two commits, then no-commit reviews that must not mutate state
  local state_c = ST.new_item_state()
  local collection_c = ST.new_collection_state()
  P.review(state_c, 4, 0.0, 10, collection_c, 10, { commit = true })
  P.review(state_c, 3, 1.0, 10, collection_c, 11, { commit = true })
  local snap_state = ST.item_to_dict(state_c)
  local snap_arena = collection_c.arena:to_dict()
  local snap_m2 = digest(collection_c.m2_optimizer:to_dict())
  local snap_m3 = digest(collection_c.m3_matrices:to_dict())
  for i, step in ipairs(S.previews) do
    local res = P.review(state_c, step.input.grade, step.input.elapsed, 10,
      collection_c, 12, { commit = false })
    check("review.preview.result[" .. i .. "]", P.result_to_dict(res), step.expected)
  end
  check("review.preview.state-unchanged", ST.item_to_dict(state_c), snap_state)
  check("review.preview.arena-unchanged", collection_c.arena:to_dict(), snap_arena)
  check("review.preview.m2-unchanged", digest(collection_c.m2_optimizer:to_dict()), snap_m2)
  check("review.preview.m3-unchanged", digest(collection_c.m3_matrices:to_dict()), snap_m3)
  return true
end

-- ---------------------------------------------------------------------------
-- main
-- ---------------------------------------------------------------------------

selftest()
json_selftest()

local order = { "numerics", "kernel", "model5", "ensemble", "model1", "model2",
  "model3", "arena", "state", "pipeline_finalize", "pipeline_review" }

print("sm20 Lua parity harness (" .. _VERSION .. ")")
for _, name in ipairs(order) do
  local body = vectors.suites[name]
  local before_pass, before_fail = pass_count, fail_count
  local ok, ran = pcall(runners[name], body)
  if not ok then
    fail_count = fail_count + 1
    failures[#failures + 1] = "suite " .. name .. " errored: " .. tostring(ran)
    ran = true
  end
  local p, f = pass_count - before_pass, fail_count - before_fail
  if not ran then
    skip_count = skip_count + 1
    print(string.format("  %-18s SKIP (module not ported yet)", name))
  else
    print(string.format("  %-18s %d checks, %d failed", name, p + f, f))
  end
end

print(string.format("\nTotal: %d passed, %d failed, %d suite(s) skipped",
  pass_count, fail_count, skip_count))
if #failures > 0 then
  print("\nFailures (first 30):")
  for i = 1, math.min(#failures, 30) do
    print("  - " .. failures[i])
  end
  os.exit(1)
end
os.exit(0)
