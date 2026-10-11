#!/usr/bin/env python3
"""Banked-scratchpad timing model driven by RTL access traces.

GFLOW's access schedule is static (data-independent), so back-pressure only
*stretches* the schedule: the sequence of accesses is unchanged, each cycle's
access group simply takes as many cycles as the memory needs. This replays a
trace captured from cycle-accurate RTL simulation (+MEMTRACE) through a model
with finite bandwidth, word-interleaved banks and access latency.

  cycles = ideal_cycles + sum(service_cycles - 1) + (latency - 1)

service cycles for one group = max( ceil(words / BW), busiest bank's count ).
"""
import math, sys


def load(path):
    rows = []
    for ln in open(path):
        p = ln.split()
        if len(p) == 8:
            rows.append(tuple(int(x) for x in p))
    return rows


def words_of(row, N):
    """Word addresses touched in one GFLOW cycle."""
    _, aA, aAd, bA, bAd, wA, wAd, wM = row
    w = []
    if aA: w += [aAd // 4 + i for i in range(N)]
    if bA: w += [bAd // 4 + i for i in range(N)]
    if wA: w += [wAd // 4 + i for i in range(N) if (wM >> i) & 1]
    return w


def simulate(rows, N, bw=None, banks=None, lat=1):
    """Return total cycles added by the memory system."""
    stall = 0
    for r in rows:
        w = words_of(r, N)
        if not w:
            continue
        need = 1
        if bw:
            need = max(need, math.ceil(len(w) / bw))
        if banks:
            cnt = {}
            for a in w:
                b = a % banks
                cnt[b] = cnt.get(b, 0) + 1
            need = max(need, max(cnt.values()))
        stall += need - 1
    return stall + max(0, lat - 1)


if __name__ == "__main__":
    rows = load(sys.argv[1])
    N = int(sys.argv[2]) if len(sys.argv) > 2 else 4
    print(f"{len(rows)} traced GFLOW cycles; peak words/cycle "
          f"{max((len(words_of(r, N)) for r in rows), default=0)}")
