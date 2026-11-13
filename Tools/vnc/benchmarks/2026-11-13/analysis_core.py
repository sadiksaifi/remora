"""Inference functions extracted unchanged from the frozen completed-series analysis."""
from collections import Counter
import itertools
import math
import random
import statistics as st

ROUNDS = tuple(range(1, 7))

CLIENTS = ("R", "S")

ACTIONS = ("scroll", "type", "menu")

DIRECTIONS = ("forward", "reverse")

CELLS = tuple((action, direction) for action in ACTIONS for direction in DIRECTIONS)

BOOTSTRAP_DRAWS = 20_000

SEED = 68_2026_1112

ALPHA = 0.05

def quantile_sorted(values, p):
    """Linear interpolation at (n-1)*p, the inclusive/type-7 convention."""
    position = (len(values) - 1) * p
    lower = math.floor(position)
    upper = math.ceil(position)
    return values[lower] + (values[upper] - values[lower]) * (position - lower)

def describe(values):
    values = sorted(values)
    return {"n": len(values), "median_ms": st.median(values),
        "iqr_ms": quantile_sorted(values, .75) - quantile_sorted(values, .25),
        "min_ms": values[0], "max_ms": values[-1]}

def scaled_iqr_difference(r, s):
    # Equal zero spreads have contrast zero; otherwise the range is [-2,2].
    return 2 * (r - s) / (r + s) if r + s else 0.0

def pool(data, indices, client, action, direction=None):
    return [row["latencyMS"] for i in indices for row in data[i, client, action]
        if row.get("inputSent") is True and (direction is None or row["direction"] == direction)]

def primary(data, indices, client, action):
    direction = None if action == "scroll" else "forward"
    medians = [st.median(pool(data, (i,), client, action, direction)) for i in indices]
    return {"round_medians_ms": medians, "median_of_round_medians_ms": st.median(medians),
        "round_median_population_sd_ms": st.pstdev(medians),
        "all_trials": describe(pool(data, indices, client, action, direction))}

def exact_tests(data):
    observed, permutations = {}, []
    for cell in CELLS:
        a, d = cell
        observed[cell] = describe(pool(data, ROUNDS, "R", a, d))["iqr_ms"] - describe(pool(data, ROUNDS, "S", a, d))["iqr_ms"]
    nominal = Counter()
    observed_global = None
    for swaps in itertools.product((False, True), repeat=6):
        differences, contrasts = {}, []
        for cell in CELLS:
            a, d = cell
            values = {client: [] for client in CLIENTS}
            for index, i in enumerate(ROUNDS):
                for client in CLIENTS:
                    source = ("S" if client == "R" else "R") if swaps[index] else client
                    values[client].extend(pool(data, (i,), source, a, d))
            r, s = (describe(values[client])["iqr_ms"] for client in CLIENTS)
            differences[cell] = r - s
            contrasts.append(scaled_iqr_difference(r, s))
            nominal[cell] += differences[cell] >= observed[cell] - 1e-12
        statistic = max(0.0, *contrasts)
        permutations.append(statistic)
        if not any(swaps):
            observed_global = statistic
    count = sum(value >= observed_global - 1e-12 for value in permutations)
    return {cell: nominal[cell] / 64 for cell in CELLS}, {
        "statistic": observed_global, "upper_tail_assignments": count, "assignments": 64,
        "p_one_sided": count / 64, "alpha": ALPHA,
        "reject_joint_exchangeability_in_greater_spread_direction": count / 64 <= ALPHA,
        "nonrejection_is_not_equivalence": True, "permutation_statistics": permutations}

def bootstrap(data, draws=BOOTSTRAP_DRAWS):
    """Resample whole paired rounds; keep every trial and cell together."""
    rng, cache, samples = random.Random(SEED), {}, []
    for _ in range(draws):
        indices = tuple(sorted(rng.choices(ROUNDS, k=6)))
        # Draw order cannot affect these statistics. Cache repeated multisets;
        # all 20,000 ordered draws still contribute to the percentile interval.
        if indices not in cache:
            values = {}
            for a, d in CELLS:
                r, s = (describe(pool(data, indices, c, a, d)) for c in CLIENTS)
                values[f"{a}.{d}.iqr_difference_ms"] = r["iqr_ms"] - s["iqr_ms"]
                values[f"{a}.{d}.median_difference_ms"] = r["median_ms"] - s["median_ms"]
            for a in ACTIONS:
                r, s = (primary(data, indices, c, a) for c in CLIENTS)
                values[f"primary.{a}.round_median_difference_ms"] = r["median_of_round_medians_ms"] - s["median_of_round_medians_ms"]
                values[f"primary.{a}.all_trial_median_difference_ms"] = r["all_trials"]["median_ms"] - s["all_trials"]["median_ms"]
            cache[indices] = values
        samples.append(cache[indices])
    intervals = {}
    for key in samples[0]:
        values = sorted(sample[key] for sample in samples)
        intervals[key] = [quantile_sorted(values, .025), quantile_sorted(values, .975)]
    return intervals, len(cache)

def analyze(data):
    nominal, global_test = exact_tests(data)
    intervals, unique = bootstrap(data)
    result = {"primary_latency": {}, "directional_spread": {}, "global_spread_test": global_test,
        "bootstrap": {"seed": SEED, "draws": BOOTSTRAP_DRAWS, "distinct_resampled_pair_multisets": unique,
            "interval": "pointwise 95% paired-cluster percentile; not simultaneous and not proof of equivalence"}}
    for a in ACTIONS:
        r, s = (primary(data, ROUNDS, c, a) for c in CLIENTS)
        gap = r["median_of_round_medians_ms"] - s["median_of_round_medians_ms"]
        result["primary_latency"][a] = {"R": r, "S": s, "median_of_round_medians_difference_ms": gap,
            "no_more_than_10ms_slower_point_estimate": gap <= 10,
            "round_median_difference_ci95_ms": intervals[f"primary.{a}.round_median_difference_ms"],
            "all_trial_median_difference_ms": r["all_trials"]["median_ms"] - s["all_trials"]["median_ms"],
            "all_trial_median_difference_ci95_ms": intervals[f"primary.{a}.all_trial_median_difference_ms"],
            "historical_round_sd_R_no_greater": r["round_median_population_sd_ms"] <= s["round_median_population_sd_ms"]}
    for a, d in CELLS:
        r, s = (describe(pool(data, ROUNDS, c, a, d)) for c in CLIENTS)
        result["directional_spread"][f"{a}.{d}"] = {"R": r, "S": s,
            "iqr_difference_ms": r["iqr_ms"] - s["iqr_ms"],
            "scaled_iqr_difference": scaled_iqr_difference(r["iqr_ms"], s["iqr_ms"]),
            "iqr_difference_ci95_ms": intervals[f"{a}.{d}.iqr_difference_ms"],
            "median_difference_ms": r["median_ms"] - s["median_ms"],
            "median_difference_ci95_ms": intervals[f"{a}.{d}.median_difference_ms"],
            "nominal_p_one_sided_descriptive_only": nominal[a, d]}
    result["all_primary_latency_point_estimates_within_10ms_slower"] = all(
        row["no_more_than_10ms_slower_point_estimate"] for row in result["primary_latency"].values())
    result["overall_variability_pass"] = None
    result["inference_scope"] = "Performed-input latencies only; menu reverse is conditional on the open precondition. Workflow outcome rates are separate, not reliability equivalence."
    return result
