#!/usr/bin/env python3
"""Golden-vector generator for the Lua port of the canonical `sm20/` package.

Runs the canonical Python implementation and emits test vectors that the
Lua parity harness (tests/run_tests.lua) compares the port against.

Outputs (both regenerated together, do not edit by hand):
    tests/golden/vectors.json  - human-inspectable
    tests/golden/vectors.lua   - Lua module consumed by the harness

Numeric conventions:
  * Integer-valued expected outputs are compared EXACTLY by the harness
    (Lua must produce the same integer). Float outputs are compared with a
    relative tolerance of 1e-9.
  * The harness distinguishes the two by `value % 1 == 0` on the expected
    number, so generators must emit true integers (json ints) for
    integer fields.
  * No inf/nan is ever emitted (asserted via allow_nan=False).

Deterministic synthetic matrices for the direct w3 suite ("recipe"):
    N = 21*21*21
    for r in 1..20, s in 1..20, d in 1..20:
        off = (r-1)*441 + (s-1)*21 + (d-1)
        s_center = ln(s)/ln(20) * 0.64 + 0.3
        im[off]   = max(1.0, s_center * r * (20 - d + 1) * 0.5)
        cm[off]   = max(1, (r*s) % 50)
    (mirrors sm20/model3.py __main__; im/cm are 0-based flat arrays)

Digests (for large state arrays) are, per field, over the flattened array
in index order: {"n": count, "sum": linear sum, "sumsq": sum of squares}.
The Lua port must flatten in the same nested-index order.
"""

import json
import math
import os
import random
import sys
from dataclasses import asdict

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, REPO_ROOT)

from sm20 import arena as AR  # noqa: E402
from sm20 import ensemble as EN  # noqa: E402
from sm20 import kernel as K  # noqa: E402
from sm20 import model1 as M1  # noqa: E402
from sm20 import model2 as M2  # noqa: E402
from sm20 import model3 as M3  # noqa: E402
from sm20 import model5 as M5  # noqa: E402
from sm20 import pipeline as PL  # noqa: E402
from sm20 import state as ST  # noqa: E402
from sm20 import weights as WT  # noqa: E402

SUITES = {}


def suite(name):
    def register(fn):
        SUITES[name] = fn
        return fn
    return register


# ---------------------------------------------------------------------------
# digests / helpers
# ---------------------------------------------------------------------------

def _flat(x, out):
    if isinstance(x, list):
        for v in x:
            _flat(v, out)
    elif isinstance(x, (int, float)):
        out.append(float(x))


def digest(x):
    vals = []
    _flat(x, vals)
    return {
        "n": len(vals),
        "sum": math.fsum(vals) if False else sum(vals),  # plain order-sensitive sum
        "sumsq": sum(v * v for v in vals),
    }


def m2_digest(opt):
    return {name: digest(getattr(opt, name)) for name in (
        "matrix", "empirical", "cell_cases", "remembered", "observed",
        "row_exponent", "row_weight", "first_grade", "first_grade_cases",
        "second_grade", "second_grade_cases",
    )}


def m3_digest(mat):
    return {name: digest(getattr(mat, name)) for name in (
        "outcome_count", "outcome_success", "smoothing_count", "smoothing_value",
        "lapse_observed", "lapse_remembered",
        "first_stage_observed", "first_stage_remembered",
    )}


def synthetic_matrices():
    n = 21 * 21 * 21
    im = [0.0] * n
    cm = [0] * n
    for r in range(1, 21):
        for s in range(1, 21):
            for d in range(1, 21):
                off = (r - 1) * 441 + (s - 1) * 21 + (d - 1)
                s_center = math.log(s) / math.log(20.0) * 0.64 + 0.3
                im[off] = max(1.0, s_center * r * (20 - d + 1) * 0.5)
                cm[off] = max(1, (r * s) % 50)
    return im, cm


# ---------------------------------------------------------------------------
# suites
# ---------------------------------------------------------------------------

@suite("numerics")
def s_numerics():
    xs = [-2.5, -1.75, -1.5, -0.75, -0.5, -0.25, -0.0, 0.25, 0.5, 0.75,
          1.5, 2.5, 2.675, 3.5, 4.5, 7.5, 8.5, 0.49999999999999994,
          2.5000000000000004, 36040.5, 1460.5, 1461.5]
    rounds = [{"x": x, "y": round(x)} for x in xs]

    lcg = PL.DelphiLCG(0)
    draws = [lcg.random() for _ in range(64)]
    lcg2 = PL.DelphiLCG(0)
    gauss = [lcg2.gauss(0.0, 1.0) for _ in range(8)]

    mt = random.Random(0)
    mt_draws = [mt.random() for _ in range(64)]

    # Self-check: the LCG's first draw follows from the recurrence directly.
    assert abs(draws[0] - (((0 * 0x08088405 + 1) & 0xFFFFFFFF) / 2.0 ** 32)) < 1e-18

    return {
        "round": rounds,
        "lcg_draws": draws,
        "lcg_gauss": gauss,
        "mtrand_draws": mt_draws,
    }


@suite("kernel")
def s_kernel():
    init = {str(g): K.init_new_item(g) for g in range(6)}

    grid = []
    for g in range(6):
        st = K.init_new_item(g)
        grid.append((0.0, g, st["D"], st["S"]))
        grid.append((float(st["S"]), g, st["D"], st["S"]))
    grid += [
        (15, 5, 0.2, 55.0), (50, 5, 0.2, 55.0), (80, 5, 0.2, 55.0),
        (30, 4, 0.35, 30.0), (30, 3, 0.40, 30.0), (20, 4, 0.5, 20.0),
        (35, 3, 0.6, 20.0), (45, 0, 0.4, 30.0), (50, 1, 0.3, 40.0),
        (25, 2, 0.5, 20.0), (100, 1, 0.15, 60.0), (0, 5, 0.3, 50.0),
        (0, 0, 0.3, 50.0), (365, 5, 0.1, 1000.0), (0.5, 4, 0.5, 1.0),
        (20, 5, 0.0, 30.0), (20, 3, 1.0, 30.0), (20, 0, 1.0, 30.0),
        (500, 4, 0.3, 10.0), (15, 3, 0.1, 50.0),
    ]
    reviews = []
    for t, g, d, s in grid:
        out = K.review_kernel(t=t, grade=g, D=d, S=s)
        reviews.append({
            "input": {"t": t, "grade": g, "D": d, "S": s},
            "expected": {
                "S_new": out["S_new"], "D_new": out["D_new"],
                "A": out["A"], "ratio": out["ratio"],
                "interval": K.compute_interval(out["S_new"]),
            },
        })

    # Spot-check: grade 5 out-schedules grade 3 on the same mature item.
    out3 = K.review_kernel(t=30, grade=3, D=0.35, S=30.0)
    out5 = K.review_kernel(t=30, grade=5, D=0.35, S=30.0)
    assert out5["S_new"] > out3["S_new"]

    intervals = []
    for s in [0.0, 0.5, 0.7, 0.8, 1.4, 1.6, 2.5, 17.66, 44529.5, 44530.5, 60000.0]:
        intervals.append({"S": s, "interval": K.compute_interval(s)})

    return {"init": init, "review": reviews, "interval": intervals}


@suite("model5")
def s_model5():
    cases = []
    for s in [1.0, 2.0, 5.0, 10.0, 50.0, 200.0]:
        for g in range(6):
            for t in [0.0, s / 2.0, s, 3.0 * s]:
                cases.append({
                    "input": {"t": t, "grade": g, "S_old": s},
                    "expected": M5.model_5(t, g, s),
                })
    return {"cases": cases}


@suite("ensemble")
def s_ensemble():
    slots = [
        (1.0, 2.0, 3.0, 4.0, 5.0),
        (3.4, 10.6, 7.2, 25.5, 9.9),
        (100.0, 1.0, 50.0, 9.0, 3.7),
    ]
    weight_sets = [
        None,                                          # defaults
        [10.0, 20.0, 30.0, 25.0, 15.0],
        [0.0, 0.0, 0.0, 0.0, 0.0],                     # zero-sum -> M3 fallback
        [50.0, 0.0, 50.0, 0.0, 0.0],
    ]
    cases = []
    for slot in slots:
        for w in weight_sets:
            cases.append({
                "input": {"m1": slot[0], "m2": slot[1], "m3": slot[2],
                          "m4": slot[3], "m5": slot[4],
                          "weights": w if w else "default"},
                "expected": EN.ensemble_stability(*slot, weights=w),
            })
    # Self-check: default-weight blend is the documented formula.
    m1, m2, m3, m4, m5 = slots[1]
    manual = (6.0 * round(m1) + 14.0 * round(m2) + 45.0 * m3 + 25.0 * m4 + 10.0 * m5) / 100.0
    assert abs(EN.ensemble_stability(m1, m2, m3, m4, m5) - manual) < 1e-12
    return {"cases": cases}


@suite("model1")
def s_model1():
    steps_spec = [(100, 4), (103, 3), (109, 5), (120, 4), (150, 2),
                  (151, 4), (160, 3), (200, 5)]

    def run(with_history):
        item = M1.M1ItemState()
        history = None
        steps = []
        for today, grade in steps_spec:
            res = M1.model_1(item, today, grade, history=history if with_history else None)
            steps.append({
                "input": {"today": today, "grade": grade},
                "expected": asdict(res),
            })
            item = res.next_item
            if with_history:
                history = res.next_history
        return steps

    return {"fresh": run(False), "history": run(True)}


@suite("model2")
def s_model2():
    unit_axis = [M2.a_axis(i) for i in range(1, 21)]
    unit_fresh = [
        {"a": a, "r": r, "value": M2._fresh_optimum(a, r)}
        for a in (1, 5, 10, 20) for r in (1, 2, 3, 10, 20)
    ]
    unit_u = [
        {"a": a, "r": r, "bin": b,
         "value": M2.u_value(a, r, b), "bucket": M2.u_bucket(a, r, M2.u_value(a, r, b))}
        for a in (1, 10, 20) for r in (1, 2, 5) for b in (1, 10, 20)
    ]
    bucket_edge = [
        {"a": 10, "r": 2, "value": v, "bucket": M2.u_bucket(10, 2, v)}
        for v in (1.0, 1.5, 2.0, 2.45, 2.5, 3.0, 4.0, 6.9, 7.0, 10.0, 12.0)
    ]

    def result_dict(res):
        return asdict(res)

    # Sequence A: full optimizer snapshot after every step.
    seq_a_steps = [(10, 4), (13, 4), (25, 3), (28, 2), (30, 4)]
    opt = M2.ClassicM2Optimizer()
    item = M2.M2ItemState()
    seq_a = []
    for today, grade in seq_a_steps:
        res = M2.model_2(item, opt, today, grade, commit=True)
        item = res.next_item
        seq_a.append({
            "input": {"today": today, "grade": grade},
            "expected": result_dict(res),
            "optimizer": opt.to_dict(),
        })

    # Sequence B: longer, digests per step, full snapshot at the end.
    # The (200, 2) step reviews very late and fails -> observed_u lands in the
    # capped U bin, exercising the Mersenne-Twister tail-fix branch.
    seq_b_steps = [(50, 4), (55, 3), (70, 5), (200, 2), (203, 1),
                   (210, 4), (400, 3), (900, 5)]
    opt_b = M2.ClassicM2Optimizer()
    item_b = M2.M2ItemState()
    seq_b = []
    for today, grade in seq_b_steps:
        res = M2.model_2(item_b, opt_b, today, grade, commit=True)
        item_b = res.next_item
        seq_b.append({
            "input": {"today": today, "grade": grade},
            "expected": result_dict(res),
            "digest": m2_digest(opt_b),
        })
    seq_b_final = opt_b.to_dict()

    # Preview: commit=False must not touch the optimizer.
    opt_p = M2.ClassicM2Optimizer()
    item_p = M2.M2ItemState()
    res = M2.model_2(item_p, opt_p, 10, 4, commit=True)
    item_p = res.next_item
    before = m2_digest(opt_p)
    prev = M2.model_2(item_p, opt_p, 20, 4, commit=False)
    after = m2_digest(opt_p)
    assert before == after

    return {
        "axis": unit_axis,
        "fresh_optimum": unit_fresh,
        "u_value_bucket": unit_u,
        "bucket_edge": bucket_edge,
        "seq_full": seq_a,
        "seq_digest": seq_b,
        "seq_digest_final": seq_b_final,
        "preview": {"result": result_dict(prev), "digest_unchanged": True},
    }


@suite("model3")
def s_model3():
    mappers = {
        "r_index": [{"x": x, "y": M3.r_index(x)}
                    for x in [0.005, 0.1, 0.3, 0.5, 0.7, 0.9, 0.95, 0.995, 1.0]],
        "s_index": [{"x": x, "y": M3.s_index(x)}
                    for x in [0.0, 0.7, 1.0, 2.0, 3.0, 10.0, 30.0, 55.0,
                              365.0, 1000.0, 6000.0, 44530.0, 100000.0]],
        "d_index": [{"x": x, "y": M3.d_index(x)}
                    for x in [-0.1, 0.0, 0.001, 0.5, 0.999, 1.0, 1.5]],
        "stability_axis": [{"j": j, "y": M3.stability_axis_value(j)} for j in range(1, 21)],
        "interval_axis": [{"i": i, "y": M3.interval_axis_value(i)} for i in range(1, 37)],
        "interval_category": [{"i": i, "y": M3.interval_category(i)}
                              for i in [0, 1, 2, 5, 10, 20, 35, 36, 40, 50,
                                        100, 365, 1000, 5000, 40000]],
    }

    im, cm = synthetic_matrices()
    recipe_check = {"digest": digest(im), "first": im[:5], "last": im[-5:],
                    "count_digest": digest(cm)}
    w3_cases = []
    for grade, d in [(0, 0.30), (2, 0.30), (3, 0.30), (5, 0.30), (3, 0.80), (5, 0.05)]:
        out = M3.w3_model_path(
            t=30.0, reps=5, lapses=1, grade=grade, D=d,
            S_old=30.0, old_interval=30.0, R=0.9,
            interval_matrix=im, count_matrix=cm, prev_S=25.0)
        w3_cases.append({
            "input": {"t": 30.0, "reps": 5, "lapses": 1, "grade": grade,
                      "D": d, "S_old": 30.0, "old_interval": 30.0,
                      "R": 0.9, "prev_S": 25.0},
            "expected": out,
        })

    steps_spec = [(10, 4), (13, 4), (25, 3), (28, 2), (30, 4), (90, 5)]
    matrices = M3.M3MatrixState()
    item = M3.M3ItemState()
    steps = []
    for today, grade in steps_spec:
        res = M3.model_3_stateful(item, matrices, today, grade, commit=True)
        # The caller in pipeline.py re-assigns previous_interval after
        # finalization; model_3_stateful itself leaves it 0.
        item = res.next_item
        steps.append({
            "input": {"today": today, "grade": grade},
            "expected": asdict(res),
            "digest": m3_digest(matrices),
        })

    return {
        "mappers": mappers,
        "synthetic": {"recipe": "main_synthetic", "check": recipe_check},
        "w3": w3_cases,
        "stateful": {"steps": steps, "final": matrices.__dict__},
    }


@suite("arena")
def s_arena():
    adapt_cases = []
    for weights, errors in [
        ([6.0, 14.0, 45.0, 25.0, 10.0], [0.1, -0.2, 0.05, 0.0, -0.3]),
        ([6.0, 14.0, 45.0, 25.0, 10.0], [1.0, 1.0, -1.0, -1.0, 0.5]),
        ([30.0, 2.0, 25.0, 95.0, 0.1], [-1.0, 1.0, -1.0, 1.0, 0.0]),
        ([10.0, 10.0, 10.0, 10.0, 10.0], [0.0, 0.0, 0.0, 0.0, 0.0]),
    ]:
        w = list(weights)
        out = AR.adapt_weights(w, list(errors))
        assert abs(sum(out) - 100.0) < 1e-9
        adapt_cases.append({
            "input": {"weights": weights, "errors": errors},
            "expected": out,
        })

    err_cases = [
        {"r": [0.9, 0.8, 0.7, 0.6, 0.5], "recalled": True},
        {"r": [0.9, 0.8, 0.7, 0.6, 0.5], "recalled": False},
    ]
    recall_cases = [
        {"s": s, "t": t, "y": AR.recall_prediction(s, t)}
        for s in (1.0, 10.0, 50.0) for t in (0.0, 1.0, 10.0, 100.0)
    ]

    state = AR.ArenaState()
    slots_spec = [
        ([2.0, 3.0, 5.0, 6.0, 4.0], 3.0, True),
        ([2.5, 4.0, 6.0, 9.0, 5.0], 6.0, False),
        ([3.0, 5.0, 8.0, 12.0, 6.0], 8.0, True),
        ([3.5, 6.0, 10.0, 15.0, 7.0], 12.0, True),
        ([1.0, 1.0, 1.0, 40.0, 2.0], 5.0, False),
        ([4.0, 7.0, 12.0, 20.0, 9.0], 15.0, True),
    ]
    observe_steps = []
    for slots, elapsed, recalled in slots_spec:
        state.observe(tuple(slots), elapsed, recalled, repetition_count=5.0)
        observe_steps.append({
            "input": {"slots": slots, "elapsed": elapsed, "recalled": recalled,
                      "repetition_count": 5.0},
            "expected": {
                "weights": list(state.weights),
                "decayed_sse": list(state.decayed_sse),
                "decayed_blend_sse": state.decayed_blend_sse,
                "decayed_sm19_sse": state.decayed_sm19_sse,
                "decayed_count": state.decayed_count,
                "total_scored": state.total_scored,
            },
        })

    guard = AR.ArenaState()
    guard.observe((2.0, 3.0, 5.0, 6.0, 4.0), 3.0, True, repetition_count=0.0)
    guard.observe((2.0, 3.0, 5.0, 6.0, 4.0), 0.0, True, repetition_count=5.0)
    guard.observe((2.0, 3.0, 0.0, 6.0, 4.0), 3.0, True, repetition_count=5.0)  # r3 guard

    return {
        "adapt": adapt_cases,
        "errors": [{"input": c, "expected": AR.compute_model_errors(*c["r"], recalled=c["recalled"])}
                   for c in err_cases],
        "recall_prediction": recall_cases,
        "observe": observe_steps,
        "guards_noop": {"weights": list(guard.weights),
                        "total_scored": guard.total_scored},
    }


@suite("state")
def s_state():
    item_default = ST.SM20State().to_dict()
    mutated = ST.SM20State(
        stability=12.5, difficulty=0.33, repetition=7, lapses=2, interval=15.0,
        post_lapse_family=2, lapse_ordinal=1,
        slot_stabilities=(3.0, 4.0, 5.0, 6.0, 7.0),
        m1_history=M1.M1HistoryPoint(factor=2.1, stability=9.0),
        m2_state=M2.M2ItemState(last_review_day=40, previous_interval=6,
                                repetitions=3, lapses=1, a_factor=3.4,
                                u_factor=2.2),
        m3_state=M3.M3ItemState(last_review_day=40, previous_interval=6,
                                repetitions=3, lapses=1, stability=9.5,
                                difficulty=0.4, previous_stability=7.0,
                                previous_stability_index=8, previous_r_index=17),
    )
    collection = ST.SM20CollectionState()
    return {
        "item_default": item_default,
        "item_mutated": mutated.to_dict(),
        "collection_default": {
            "arena": {
                "weights": list(collection.arena.weights),
                "decayed_sse": list(collection.arena.decayed_sse),
                "decayed_blend_sse": collection.arena.decayed_blend_sse,
                "decayed_sm19_sse": collection.arena.decayed_sm19_sse,
                "decayed_count": collection.arena.decayed_count,
                "total_scored": collection.arena.total_scored,
            },
            "m2_digest": m2_digest(collection.m2_optimizer),
            "m3_digest": m3_digest(collection.m3_matrices),
        },
        "m2_default_snippet": {
            "matrix_row1": collection.m2_optimizer.matrix[0],
            "matrix_row20": collection.m2_optimizer.matrix[19],
            "first_grade": collection.m2_optimizer.first_grade,
            "second_grade": collection.m2_optimizer.second_grade,
            "row_exponent": collection.m2_optimizer.row_exponent,
            "row_weight": collection.m2_optimizer.row_weight,
        },
    }


@suite("pipeline_finalize")
def s_finalize():
    fi_cases = [{"fi": fi, "y": PL.retention_factor(fi)}
                for fi in [1, 2, 5, 10, 15, 20, 30, 50]]

    disp_cases = []
    for adjusted in [1.0, 5.5, 30.0, 100.0, 365.0]:
        rng = PL.DelphiLCG(0)
        disp_cases.append({"adjusted": adjusted, "y": PL.dispersal(adjusted, rng)})

    pl_cases = []
    for adjusted in [1.0, 5.0]:
        for x in [0.0, 25.0, 50.0, 75.0, 100.0]:
            rng = PL.DelphiLCG(0)
            pl_cases.append({"adjusted": adjusted, "x": x,
                             "y": PL.post_lapse(adjusted, x, rng)})

    mg_cases = []
    for interval, used in [(1, 1), (1, 2), (2, 5), (10, 20), (50, 69), (50, 70),
                           (80, 71), (100, 100), (100, 200), (1600, 1460),
                           (1601, 1461), (2000, 1461), (44530, 1462),
                           (44530, 3000), (30, 3), (33, 30), (31, 30)]:
        mg_cases.append({"interval": interval, "used": used,
                         "y": PL.min_growth_guard(interval, used)})

    fin_cases = []
    combos = [
        {"ensemble": 25.0, "fi": 10, "post_lapse": False, "disperse": False,
         "min_growth": False, "used": 1},
        {"ensemble": 3.0, "fi": 10, "post_lapse": True, "post_lapse_x": 0.0,
         "disperse": False, "min_growth": False, "used": 1},
        {"ensemble": 3.0, "fi": 10, "post_lapse": True, "post_lapse_x": 60.0,
         "disperse": False, "min_growth": False, "used": 1},
        {"ensemble": 25.0, "fi": 10, "post_lapse": False, "disperse": True,
         "min_growth": False, "used": 1},
        {"ensemble": 2.0, "fi": 10, "post_lapse": False, "disperse": False,
         "min_growth": True, "used": 20},
        {"ensemble": 2.0, "fi": 20, "post_lapse": False, "disperse": False,
         "min_growth": True, "used": 1500},
        {"ensemble": 100.0, "fi": 5, "post_lapse": False, "disperse": False,
         "min_growth": False, "used": 1},
    ]
    for c in combos:
        rng = PL.DelphiLCG(0)
        out = PL.finalize(
            c["ensemble"], c["fi"],
            post_lapse_mode=c["post_lapse"],
            post_lapse_x=c.get("post_lapse_x", 0.0),
            disperse=c["disperse"], rng=rng,
            used_interval=c["used"], min_growth=c["min_growth"])
        fin_cases.append({"input": c,
                          "expected": {"adjusted": out.adjusted,
                                       "raw": out.raw,
                                       "interval": out.interval}})
    return {
        "retention_factor": fi_cases,
        "dispersal": disp_cases,
        "post_lapse": pl_cases,
        "min_growth_guard": mg_cases,
        "finalize": fin_cases,
    }


def _review_step_result(res):
    return asdict(res)


@suite("pipeline_review")
def s_review():
    def run_sequence(steps, pure_m4=False):
        state = ST.SM20State()
        collection = ST.SM20CollectionState()
        out_steps = []
        for today, grade, elapsed in steps:
            res = PL.review(state, grade, elapsed, 10, collection, today,
                            commit=True, pure_m4=pure_m4)
            out_steps.append({
                "input": {"today": today, "grade": grade, "elapsed": elapsed,
                          "fi": 10},
                "expected": _review_step_result(res),
                "state": state.to_dict(),
                "arena": {
                    "weights": list(collection.arena.weights),
                    "decayed_sse": list(collection.arena.decayed_sse),
                    "decayed_blend_sse": collection.arena.decayed_blend_sse,
                    "decayed_sm19_sse": collection.arena.decayed_sm19_sse,
                    "decayed_count": collection.arena.decayed_count,
                    "total_scored": collection.arena.total_scored,
                },
                "m2_digest": m2_digest(collection.m2_optimizer),
                "m3_digest": m3_digest(collection.m3_matrices),
            })
        return out_steps, collection

    steps_a = [(10, 4, 0.0), (11, 3, 1.0), (14, 5, 3.0), (24, 4, 10.0),
               (49, 2, 25.0), (50, 4, 1.0), (52, 3, 2.0), (92, 5, 40.0),
               (192, 1, 100.0), (194, 5, 2.0)]
    seq_a, coll_a = run_sequence(steps_a)

    steps_b = [(10, 4, 0.0), (12, 5, 2.0), (20, 4, 8.0), (50, 2, 30.0),
               (51, 3, 1.0), (80, 4, 29.0), (160, 5, 80.0), (500, 4, 340.0)]
    seq_b, _ = run_sequence(steps_b, pure_m4=True)

    # Preview sequence: two commits, then four no-commit previews that must
    # not mutate any state.
    state = ST.SM20State()
    collection = ST.SM20CollectionState()
    PL.review(state, 4, 0.0, 10, collection, 10, commit=True)
    PL.review(state, 3, 1.0, 10, collection, 11, commit=True)
    before_state = state.to_dict()
    before_arena = list(collection.arena.weights)
    before_m2 = m2_digest(collection.m2_optimizer)
    before_m3 = m3_digest(collection.m3_matrices)
    previews = []
    for grade in [3, 4, 2, 5]:
        res = PL.review(state, grade, 1.0, 10, collection, 12, commit=False)
        previews.append({"input": {"grade": grade, "elapsed": 1.0},
                         "expected": _review_step_result(res)})
    assert state.to_dict() == before_state
    assert list(collection.arena.weights) == before_arena
    assert m2_digest(collection.m2_optimizer) == before_m2
    assert m3_digest(collection.m3_matrices) == before_m3

    return {
        "seq": seq_a,
        "final_collection": {
            "m2_optimizer": coll_a.m2_optimizer.to_dict(),
            "m3_matrices": coll_a.m3_matrices.__dict__,
            "arena": {
                "weights": list(coll_a.arena.weights),
                "decayed_sse": list(coll_a.arena.decayed_sse),
                "decayed_blend_sse": coll_a.arena.decayed_blend_sse,
                "decayed_sm19_sse": coll_a.arena.decayed_sm19_sse,
                "decayed_count": coll_a.arena.decayed_count,
                "total_scored": coll_a.arena.total_scored,
            },
        },
        "seq_pure_m4": seq_b,
        "previews": previews,
        "previews_state_unchanged": True,
    }


# ---------------------------------------------------------------------------
# emitters
# ---------------------------------------------------------------------------

def to_lua_literal(v):
    if v is None:
        return "nil"
    if v is True:
        return "true"
    if v is False:
        return "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        if v != v or v in (float("inf"), float("-inf")):
            raise ValueError(f"non-finite float in vectors: {v}")
        return repr(v)
    if isinstance(v, str):
        return json.dumps(v)
    if isinstance(v, (list, tuple)):
        return "{ " + ", ".join(to_lua_literal(x) for x in v) + " }"
    if isinstance(v, dict):
        parts = []
        for k, x in v.items():
            parts.append(f"[{json.dumps(str(k))}] = {to_lua_literal(x)}")
        return "{\n" + ",\n".join(parts) + "\n}"


def main():
    result = {"suites": {}}
    for name, fn in SUITES.items():
        result["suites"][name] = fn()

    golden_dir = os.path.dirname(os.path.abspath(__file__))
    json_path = os.path.join(golden_dir, "vectors.json")
    lua_path = os.path.join(golden_dir, "vectors.lua")

    with open(json_path, "w") as f:
        json.dump(result, f, indent=1, allow_nan=False)

    with open(lua_path, "w") as f:
        f.write("-- Generated by tests/golden/generate_vectors.py -- DO NOT EDIT.\n")
        f.write("return " + to_lua_literal(result) + "\n")

    counts = {name: (len(json.dumps(body)) // 1024) for name, body in result["suites"].items()}
    print(f"wrote {json_path}")
    print(f"wrote {lua_path}")
    for name, kb in counts.items():
        print(f"  suite {name}: ~{kb} KB")


if __name__ == "__main__":
    main()
