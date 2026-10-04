"""Maximum-cardinality, minimum-cost bipartite association for the Labs tracker.

A private helper of `tools/labs/temporal_tracks.py` (CONTRACT.md section 7).
Pure functions over ONE batch's feasible-edge graph: no tracker state, no I/O,
no NumPy, no clock, no randomness and no recursion, so identical input gives an
identical answer on every box and in every process.

WHY NOT GREEDY. The contract forbids nearest-neighbour assignment, and the
public case `maximum-cardinality-before-nearest-edge` is exactly the shape that
punishes it: track t1 can reach `left` (cost 400000) and `middle` (360000),
track t2 can only reach `middle` (440000). Taking the cheapest edge first gives
t1 `middle`, strands t2, and loses one of the two tracks that a maximum
matching keeps. So cardinality is maximised FIRST, and cost minimised only
among matchings of that size.

HOW. `optimal()` is successive shortest augmenting paths: augment one track at a
time along a minimum-cost path in the residual graph, where the reverse arc of
an already matched edge carries the negative of its cost. Bellman-Ford with a
work queue (SPFA) rather than Dijkstra, because those reverse arcs are negative
and a potential-based Dijkstra would need a dual-feasibility argument this
module does not have to make. Two properties make it the contract's answer:

  * processing each track once, in order, still reaches MAXIMUM cardinality --
    if no augmenting path leaves track i, none can pass through it either (an
    alternating path enters a track only along its matched edge, and i has
    none), so the induction over processed tracks holds;
  * a maximum matching whose residual graph holds no negative cycle is already
    minimum-cost among maximum matchings: two maximum matchings differ only by
    even alternating cycles (a differing path would be an augmenting path for
    one of them), and every such cycle has non-negative cost. Augmenting along
    a SHORTEST path is what keeps negative cycles out.

Costs are the contract's non-negative integers, so no scaling or float
arithmetic enters the optimisation itself.

AMBIGUITY. `solve_component()` also answers the contract's abstention question:
is there a DIFFERENT maximum-cardinality matching within `ambiguity_margin` of
the best one? It follows the method the contract names -- forbid each selected
edge in turn and solve again -- which is K+1 solves, not the K! permutations of
a brute force. A forbidden edge that drops the cardinality below K proves
nothing (the alternative must also have size K) and is skipped. Two shortcuts
keep the common batch cheap without weakening the answer: when a component's
edge count equals its matching size every edge is used, so no different
matching of that size exists; and `forced_pairs()` recognises the whole-batch
case where every non-isolated track and detection has exactly one edge, so
every component is a single forced edge and no solve is needed at all.
"""
from __future__ import annotations

from collections import deque
from typing import Sequence

__all__ = ["components", "forced_pairs", "optimal", "solve_component"]

_INF = float("inf")


def optimal(adj: Sequence[Sequence[tuple[int, int]]], n_tracks: int, n_dets: int
            ) -> tuple[int, int, list[int]]:
    """A maximum-cardinality, minimum-cost matching of one graph.

    `adj[t]` lists `(detection, cost)` pairs with `cost` a non-negative int;
    detections absent from `adj[t]` have no feasible edge. Returns
    `(K, total_cost, match_track)` where `match_track[t]` is the detection
    matched to track `t`, or -1.
    """
    match_t = [-1] * n_tracks
    match_d = [-1] * n_dets
    match_cost = [0] * n_dets          # cost of the edge each matched detection carries
    total = 0
    size = 0
    n = n_tracks + n_dets              # node ids: track t -> t, detection j -> n_tracks + j
    for start in range(n_tracks):
        if match_t[start] >= 0:
            continue
        dist = [_INF] * n
        prev = [-1] * n
        arc = [0] * n                  # residual cost of the arc that set dist[]
        queued = [False] * n
        q = deque([start])
        queued[start] = True
        dist[start] = 0
        while q:
            u = q.popleft()
            queued[u] = False
            du = dist[u]
            if u < n_tracks:
                own = match_t[u]
                for j, c in adj[u]:
                    if j == own:
                        continue       # saturated forward arc: only its reverse remains
                    v = n_tracks + j
                    nd = du + c
                    if nd < dist[v]:
                        dist[v] = nd
                        prev[v] = u
                        arc[v] = c
                        if not queued[v]:
                            queued[v] = True
                            q.append(v)
            else:
                j = u - n_tracks
                t = match_d[j]
                if t >= 0:
                    nd = du - match_cost[j]
                    if nd < dist[t]:
                        dist[t] = nd
                        prev[t] = u
                        arc[t] = -match_cost[j]
                        if not queued[t]:
                            queued[t] = True
                            q.append(t)
        best = -1
        best_d = _INF
        for j in range(n_dets):
            if match_d[j] < 0:
                dj = dist[n_tracks + j]
                if dj < best_d:
                    best_d = dj
                    best = j
        if best < 0:
            continue                   # no augmenting path from this track: it stays free
        node = n_tracks + best
        path = []
        while node != start:
            path.append(node)
            node = prev[node]
        path.append(start)
        path.reverse()                 # track, detection, track, detection, ... , free detection
        for i in range(0, len(path) - 1, 2):
            t = path[i]
            j = path[i + 1] - n_tracks
            match_t[t] = j
            match_d[j] = t
            match_cost[j] = arc[n_tracks + j]
        total += best_d                # the path's residual cost IS the cost change
        size += 1
    return size, total, match_t


def components(adj: Sequence[Sequence[tuple[int, int]]],
               radj: Sequence[Sequence[int]]) -> list[tuple[list[int], list[int]]]:
    """Split the feasible-edge graph into connected components.

    Returns `[(track_indices, detection_indices)]` for every component that has
    at least one edge, in ascending order of each component's first track.
    Isolated tracks and isolated detections belong to no component: the contract
    lets the first coast and makes the second start a new track.
    """
    seen_t = [False] * len(adj)
    seen_d = [False] * len(radj)
    out: list[tuple[list[int], list[int]]] = []
    for first in range(len(adj)):
        if seen_t[first] or not adj[first]:
            continue
        seen_t[first] = True
        tracks: list[int] = []
        dets: list[int] = []
        stack: list[tuple[bool, int]] = [(True, first)]
        while stack:
            is_track, i = stack.pop()
            if is_track:
                tracks.append(i)
                for j, _cost in adj[i]:
                    if not seen_d[j]:
                        seen_d[j] = True
                        stack.append((False, j))
            else:
                dets.append(i)
                for t in radj[i]:
                    if not seen_t[t]:
                        seen_t[t] = True
                        stack.append((True, t))
        out.append((tracks, dets))
    return out


def forced_pairs(adj: Sequence[Sequence[tuple[int, int]]],
                 radj: Sequence[Sequence[int]], n_edges: int) -> list[tuple[int, int]] | None:
    """`[(track, detection)]` when every component is one forced edge, else None.

    A component whose every track and every detection has degree 1 IS that
    single edge, so its maximum matching has size 1, uses the only edge, and no
    different matching of that size exists -- unambiguous without a solve. The
    test is one count: `n_edges` equals the number of non-isolated tracks only
    when each of them has exactly one edge (degrees are >= 1 by construction),
    and likewise for detections.
    """
    busy_t = 0
    for a in adj:
        if a:
            busy_t += 1
    if n_edges != busy_t:
        return None
    busy_d = 0
    for r in radj:
        if r:
            busy_d += 1
    if n_edges != busy_d:
        return None
    pairs = []
    for t, a in enumerate(adj):
        if a:
            pairs.append((t, a[0][0]))
    return pairs


def solve_component(adj: list[list[tuple[int, int]]], n_tracks: int, n_dets: int,
                    margin: int) -> tuple[list[int], str | None]:
    """Solve ONE connected component and decide whether it is ambiguous.

    Returns `(match_track, reason)`; `reason` is None when the component's best
    matching stands, or `"cost_tie"` when a different maximum-cardinality
    matching costs no more than the best plus `margin`. The caller reports
    `"merge"` itself: that rule is geometric, and it takes precedence.
    """
    n_edges = 0
    for a in adj:
        n_edges += len(a)
    size, cost, match_t = optimal(adj, n_tracks, n_dets)
    if n_edges == size:
        # Every feasible edge is used, so a different matching of this size does
        # not exist -- whatever the margin says.
        return match_t, None
    limit = cost + margin
    for t in range(n_tracks):
        j = match_t[t]
        if j < 0:
            continue
        banned = list(adj)
        banned[t] = [e for e in adj[t] if e[0] != j]
        size2, cost2, _ = optimal(banned, n_tracks, n_dets)
        if size2 == size and cost2 <= limit:
            return match_t, "cost_tie"
    return match_t, None
