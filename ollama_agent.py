"""
ollama_agent.py
Helper functions for the NetLogo model:
- LLM-assisted dispatch decision
- LLM-assisted route selection from top-3 shortest candidate paths
- Shortest-path baseline routing
- Caching and fallback logic

Requirements:
    pip install requests networkx

Ollama:
    ollama serve
    ollama pull llama3.1:8b
"""

import json
import re
import time
from typing import Dict, List, Any, Tuple

import networkx as nx
import requests


OLLAMA_URL = "http://localhost:11434/api/generate"
MODEL_NAME = "llama3.1:8b"

dispatch_cache: Dict[str, int] = {}
route_cache: Dict[str, int] = {}


def _build_graph(time_matrix: List[List[float]]) -> nx.DiGraph:
    """Build a directed complete graph from a travel-time matrix."""
    g = nx.DiGraph()
    n = len(time_matrix)
    for i in range(n):
        for j in range(n):
            if i != j:
                w = float(time_matrix[i][j])
                if w > 0:
                    g.add_edge(i, j, weight=w)
    return g


def _path_time(path: List[int], time_matrix: List[List[float]]) -> float:
    return sum(float(time_matrix[path[i]][path[i + 1]]) for i in range(len(path) - 1))


def _path_avg_risk(path: List[int], risk_matrix: List[List[float]]) -> float:
    if len(path) < 2:
        return 0.0
    risks = [float(risk_matrix[path[i]][path[i + 1]]) for i in range(len(path) - 1)]
    return sum(risks) / len(risks)


def _ask_ollama(prompt: str, timeout: int = 60) -> str:
    """Call local Ollama. Returns raw response text, or empty string on failure."""
    payload = {
        "model": MODEL_NAME,
        "prompt": prompt,
        "stream": False,
        "options": {
            "temperature": 0,
            "num_predict": 8,
        },
    }
    try:
        r = requests.post(OLLAMA_URL, json=payload, timeout=timeout)
        r.raise_for_status()
        return r.json().get("response", "").strip()
    except Exception:
        return ""


def _extract_first_int(text: str) -> int | None:
    m = re.search(r"-?\d+", text or "")
    return int(m.group(0)) if m else None


def shortest_path_json(current: int, target: int, time_matrix: List[List[float]]) -> str:
    """Baseline shortest path. Returns JSON string for NetLogo."""
    start = time.perf_counter()
    g = _build_graph(time_matrix)
    try:
        path = nx.shortest_path(g, current, target, weight="weight")
    except Exception:
        path = [current, target]
    elapsed = time.perf_counter() - start
    return json.dumps({
        "path": path,
        "base_time": _path_time(path, time_matrix),
        "decision_time": elapsed,
    })


def top_k_paths(current: int, target: int, time_matrix: List[List[float]], risk_matrix: List[List[float]], k: int = 3) -> List[Dict[str, Any]]:
    """Return top-k shortest simple paths by travel time."""
    g = _build_graph(time_matrix)
    options = []
    try:
        gen = nx.shortest_simple_paths(g, current, target, weight="weight")
        for idx, path in enumerate(gen):
            if idx >= k:
                break
            options.append({
                "rank": idx + 1,
                "path": path,
                "base_time": _path_time(path, time_matrix),
                "avg_risk": _path_avg_risk(path, risk_matrix),
            })
    except Exception:
        options = [{
            "rank": 1,
            "path": [current, target],
            "base_time": float(time_matrix[current][target]),
            "avg_risk": float(risk_matrix[current][target]),
        }]

    while len(options) < k and options:
        # Pad using the last valid option so NetLogo always receives 3 choices.
        copy_opt = dict(options[-1])
        copy_opt["rank"] = len(options) + 1
        options.append(copy_opt)

    return options


def choose_dispatch_json(
    current_time_block: int,
    current_node: int,
    demand: List[int],
    window_end: List[float],
    time_matrix: List[List[float]],
) -> str:
    """
    LLM-assisted dispatch.
    The LLM outputs only one demand node number.

    Improved version:
    - Adds projected arrival time
    - Adds deadline slack after travel
    - Marks whether a node is reachable before deadline
    - Gives a heuristic rank to guide the LLM
    - Fallback chooses best feasible node first, then least-late node
    """
    start = time.perf_counter()

    candidates = []
    for node in range(1, len(demand)):
        remaining = int(demand[node])
        if remaining > 0:
            travel_time = float(time_matrix[current_node][node])
            deadline = float(window_end[node])
            projected_arrival = float(current_time_block) + travel_time
            hours_left = deadline - float(current_time_block)
            slack_after_arrival = deadline - projected_arrival
            feasible_before_deadline = projected_arrival <= deadline

            if slack_after_arrival < 0:
                urgency = "already_late_or_infeasible"
            elif slack_after_arrival < 24:
                urgency = "urgent"
            else:
                urgency = "safe"

            # Lower score is better.
            # Strongly penalize infeasible/late arrivals, but still allow them if all are late.
            lateness_penalty = max(0.0, -slack_after_arrival) * 5.0
            demand_bonus = remaining * 0.5
            score = travel_time + lateness_penalty - demand_bonus

            candidates.append({
                "node": node,
                "remaining_demand": remaining,
                "deadline": round(deadline, 2),
                "hours_left_to_deadline": round(hours_left, 2),
                "travel_time_from_current": round(travel_time, 2),
                "projected_arrival_time": round(projected_arrival, 2),
                "slack_after_arrival": round(slack_after_arrival, 2),
                "feasible_before_deadline": feasible_before_deadline,
                "urgency": urgency,
                "heuristic_score_lower_is_better": round(score, 2),
            })

    if not candidates:
        return json.dumps({
            "node": -1,
            "decision_time": time.perf_counter() - start,
            "cached": False
        })

    # Sort candidates before giving them to the LLM.
    # This makes the prompt easier and reduces random bad choices.
    candidates = sorted(
        candidates,
        key=lambda c: (
            not c["feasible_before_deadline"],
            c["heuristic_score_lower_is_better"],
            c["travel_time_from_current"],
            -c["remaining_demand"],
            c["node"],
        )
    )

    fallback_node = candidates[0]["node"]

    key = json.dumps({
        "time_block": current_time_block,
        "current_node": current_node,
        "candidates": candidates,
    }, sort_keys=True)

    if key in dispatch_cache:
        return json.dumps({
            "node": dispatch_cache[key],
            "decision_time": time.perf_counter() - start,
            "cached": True,
        })

    prompt = f"""
You are the Dispatch Agent for a post-earthquake relief delivery simulation.

Goal:
Maximize on-time delivered demand before the 480-hour simulation limit.

Decision rule:
1. Prefer nodes that can still be reached before their deadline.
2. Among feasible nodes, prefer urgent nodes with low slack after arrival.
3. Avoid very long travel times unless the node has high unmet demand or is the only feasible urgent option.
4. If all nodes are already late or infeasible, choose the node with the best heuristic_score_lower_is_better.
5. The candidate list is already sorted from best heuristic choice to worst.
6. When current time is above 300 hours, strongly prioritize short travel time and reachable nodes. Avoid low-demand nodes with high travel time unless no better feasible option exists.
7. Output only one node number. Do not explain.

Current time block: {current_time_block} hours
Truck current node: {current_node}

Candidate demand nodes:
{json.dumps(candidates, indent=2)}

Answer with only one node number:
""".strip()

    raw = _ask_ollama(prompt)
    chosen = _extract_first_int(raw)

    valid_nodes = {c["node"] for c in candidates}
    if chosen not in valid_nodes:
        chosen = fallback_node

    dispatch_cache[key] = chosen

    return json.dumps({
        "node": chosen,
        "decision_time": time.perf_counter() - start,
        "cached": False,
    })


def choose_route_json(
    current: int,
    target: int,
    time_matrix: List[List[float]],
    risk_matrix: List[List[float]],
) -> str:
    """
    LLM-assisted route selection.
    Python computes top-3 shortest paths; LLM chooses option 1, 2, or 3.

    Improved version:
    - Adds disruption probability
    - Adds expected travel time under the uncertainty model
    - Sorts options by expected time
    - Fallback chooses lowest expected travel time
    """
    start = time.perf_counter()

    options = top_k_paths(current, target, time_matrix, risk_matrix, k=3)

    improved_options = []
    for opt in options:
        base_time = float(opt["base_time"])
        avg_risk = float(opt["avg_risk"])
        actual_disruption_probability = avg_risk / 10.0
        expected_risk_penalty = 2.0 * actual_disruption_probability

        expected_time = base_time * (1.0 + expected_risk_penalty)

        improved_options.append({
            "rank": opt["rank"],
            "path": opt["path"],
            "base_time": round(base_time, 2),
            "avg_risk": round(avg_risk, 2),
            "disruption_probability": round(actual_disruption_probability, 3),
            "expected_risk_penalty": round(expected_risk_penalty, 3),
            "expected_travel_time": round(expected_time, 2),
        })

    # Sort by expected travel time, then base time, then risk.
    improved_options = sorted(
        improved_options,
        key=lambda o: (
            o["expected_travel_time"],
            o["base_time"],
            o["avg_risk"],
            o["rank"],
        )
    )

    for idx, opt in enumerate(improved_options):
        opt["rank"] = idx + 1

    key = json.dumps({
        "current": current,
        "target": target,
        "options": improved_options,
    }, sort_keys=True)

    fallback_rank = improved_options[0]["rank"]

    if key in route_cache:
        rank = route_cache[key]
        chosen = next(o for o in improved_options if o["rank"] == rank)

        return json.dumps({
            "choice": rank,
            "path": chosen["path"],
            "base_time": chosen["base_time"],
            "avg_risk": chosen["avg_risk"],
            "decision_time": time.perf_counter() - start,
            "cached": True,
        })

    prompt = f"""
You are the Routing Agent for a post-earthquake relief delivery simulation.

Goal:
Choose the route that is most likely to deliver quickly under uncertainty.

Decision rule:
1. Prefer the lowest expected_travel_time.
2. Choose a safer route only if its expected_travel_time is close to the fastest option.
3. Do not choose a much longer route just because it has lower risk.
4. The options are already sorted by expected_travel_time from best to worst.
5. Output only one integer: 1, 2, or 3.
6. Do not explain.

Current node: {current}
Target node: {target}

Route options:
{json.dumps(improved_options, indent=2)}

Answer with only 1, 2, or 3:
""".strip()

    raw = _ask_ollama(prompt)
    rank = _extract_first_int(raw)

    valid_ranks = {o["rank"] for o in improved_options}
    if rank not in valid_ranks:
        rank = fallback_rank

    route_cache[key] = rank
    chosen = next(o for o in improved_options if o["rank"] == rank)

    return json.dumps({
        "choice": rank,
        "path": chosen["path"],
        "base_time": chosen["base_time"],
        "avg_risk": chosen["avg_risk"],
        "decision_time": time.perf_counter() - start,
        "cached": False,
    })


def reset_caches() -> str:
    dispatch_cache.clear()
    route_cache.clear()
    return "ok"
