#!/usr/bin/env python3
"""Mechanical layout-quality check for the signal-chain sheets.

WHY THIS EXISTS
Diagram quality was being judged by eye: render a PNG, look at it, decide it
feels cluttered. That works but it doesn't survive a refactor — a change to
node grouping or a Graphviz attribute can quietly make a sheet worse and
nobody notices until someone opens it during a service. This turns the two
defects that actually matter into numbers, so a regression fails a check
instead of waiting to be spotted.

WHAT IT MEASURES
  crossings     Edge-vs-edge intersections in open space. The single best
                proxy for "looks like spaghetti". Intersections that land
                inside a node box are NOT counted here — those are the other
                metric, and counting them twice would double-punish one fault.
  through_nodes Edge paths that pass through a node box they are not
                connected to. This is the serious one: on a wiring diagram a
                line crossing a box reads as a connection that does not
                exist.
  self_overlap  Edge paths that cut deep through the body of their OWN
                endpoint node — what a link does when its port is on the far
                side of the box and it has to cross the box to reach it. Not
                a false connection, but it looks like a short circuit. This
                is the metric that catches splines=ortho (7 on the stage
                sheet, versus 0 for polyline) and it is why ortho was
                rejected despite being tidier by every other measure.
  edge_len      Total path length in inches. A tie-breaker, not a goal —
                shorter is usually tidier, but squeezing length at the cost
                of crossings is the wrong trade.
  area          Canvas area in square inches. Also a tie-breaker. A sheet
                that grows but un-crosses itself is a win.

crossings, through_nodes and self_overlap are the gates; edge_len and area
are reported but never fail the run, because grouping nodes logically
legitimately costs some compactness and we do not want that fight every
time.

USAGE
  ./signal-chain-layout-check.py                 # check against baseline
  ./signal-chain-layout-check.py --update-baseline
  ./signal-chain-layout-check.py --json

Exits non-zero if a gated metric got worse than the committed baseline.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
BACKEND = HERE.parent
PROJECT = BACKEND.parent.parent
BASELINE = HERE / "signal-chain-layout-baseline.json"

sys.path.insert(0, str(BACKEND))

# Sampled points per cubic segment. 24 is well past the point where the
# numbers stop moving; the cost is irrelevant at this graph size.
SAMPLES = 24
# Node boxes are inflated by this (inches) when deciding whether a crossing
# is "in open space". Two edges leaving the same port necessarily converge at
# the box edge, and that convergence is not a crossing anyone can see.
CROSS_MARGIN = 0.18
# ...and deflated by this when deciding whether a path runs THROUGH a box, so
# an edge that merely grazes a corner is not reported.
THROUGH_MARGIN = 0.04
# An edge always dips a little way into its own node to meet the port. Only
# count it as cutting through its own body once this fraction of the sampled
# path is inside the box — well above the few percent a normal port entry
# costs, well below the ~16-30% that a wrong-side entry produces.
SELF_OVERLAP_FRACTION = 0.12


def plain(dot_src: str) -> str:
    r = subprocess.run(
        ["dot", "-Tplain"], input=dot_src, text=True, capture_output=True
    )
    if r.returncode != 0:
        raise SystemExit(f"dot failed: {r.stderr[:400]}")
    return r.stdout


def parse_plain(text: str):
    """-> (scale, w, h, {name: (x, y, w, h)}, [(tail, head, [(x, y), ...])])

    `dot -Tplain` gives node centres and sizes in inches, and edge paths as
    cubic Bezier control points (1 + 3k of them). Tokens are whitespace
    separated with quoted labels, so shlex-style splitting is required.
    """
    import shlex

    scale = w = h = 0.0
    nodes, edges = {}, []
    for line in text.splitlines():
        if not line.strip():
            continue
        f = shlex.split(line)
        if f[0] == "graph":
            scale, w, h = float(f[1]), float(f[2]), float(f[3])
        elif f[0] == "node":
            nodes[f[1]] = (float(f[2]), float(f[3]), float(f[4]), float(f[5]))
        elif f[0] == "edge":
            tail, head, n = f[1], f[2], int(f[3])
            pts = [(float(f[4 + 2 * i]), float(f[5 + 2 * i])) for i in range(n)]
            edges.append((tail, head, pts))
    return scale, w, h, nodes, edges


def flatten(pts):
    """Bezier control points -> a dense polyline we can do geometry on."""
    if len(pts) < 4:
        return list(pts)
    out = []
    for i in range(0, len(pts) - 3, 3):
        p0, p1, p2, p3 = pts[i : i + 4]
        for s in range(SAMPLES + 1):
            t = s / SAMPLES
            u = 1 - t
            out.append(
                (
                    u * u * u * p0[0]
                    + 3 * u * u * t * p1[0]
                    + 3 * u * t * t * p2[0]
                    + t * t * t * p3[0],
                    u * u * u * p0[1]
                    + 3 * u * u * t * p1[1]
                    + 3 * u * t * t * p2[1]
                    + t * t * t * p3[1],
                )
            )
    return out


def in_box(pt, box, margin):
    x, y = pt
    cx, cy, bw, bh = box
    return (
        abs(x - cx) <= bw / 2 + margin and abs(y - cy) <= bh / 2 + margin
    )


def seg_intersect(a, b, c, d):
    """Proper intersection point of ab and cd, or None. Collinear overlap is
    deliberately ignored — two edges drawn along each other is a different
    (and much rarer) defect than a crossing."""

    def cross(o, p, q):
        return (p[0] - o[0]) * (q[1] - o[1]) - (p[1] - o[1]) * (q[0] - o[0])

    d1, d2 = cross(c, d, a), cross(c, d, b)
    d3, d4 = cross(a, b, c), cross(a, b, d)
    if ((d1 > 0) != (d2 > 0)) and ((d3 > 0) != (d4 > 0)):
        t = d1 / (d1 - d2)
        return (a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1]))
    return None


def measure(dot_src: str) -> dict:
    _, w, h, nodes, edges = parse_plain(plain(dot_src))
    paths = [(t, hd, flatten(p)) for t, hd, p in edges]

    # --- edges passing through unrelated node boxes ---
    through = 0
    for tail, head, pts in paths:
        for name, box in nodes.items():
            if name in (tail, head):
                continue
            if any(in_box(p, box, -THROUGH_MARGIN) for p in pts):
                through += 1

    # --- edges cutting through the body of their own endpoint node ---
    self_overlap = 0
    for tail, head, pts in paths:
        for name in (tail, head):
            box = nodes.get(name)
            if box is None:
                continue
            inside = sum(1 for p in pts if in_box(p, box, -THROUGH_MARGIN))
            if inside > len(pts) * SELF_OVERLAP_FRACTION:
                self_overlap += 1
    # --- crossings in open space ---
    crossings = 0
    for i in range(len(paths)):
        ti, hi, pi = paths[i]
        for j in range(i + 1, len(paths)):
            tj, hj, pj = paths[j]
            endpoint_boxes = [
                nodes[n] for n in (ti, hi, tj, hj) if n in nodes
            ]
            hit = False
            for a in range(len(pi) - 1):
                for b in range(len(pj) - 1):
                    x = seg_intersect(pi[a], pi[a + 1], pj[b], pj[b + 1])
                    if x is None:
                        continue
                    # Not a visible crossing if it happens where these edges
                    # meet their own nodes, or inside any box at all.
                    if any(in_box(x, bx, CROSS_MARGIN) for bx in endpoint_boxes):
                        continue
                    if any(in_box(x, bx, 0.0) for bx in nodes.values()):
                        continue
                    hit = True
                    break
                if hit:
                    break
            crossings += 1 if hit else 0

    edge_len = 0.0
    for _, _, pts in paths:
        edge_len += sum(
            ((pts[k + 1][0] - pts[k][0]) ** 2 + (pts[k + 1][1] - pts[k][1]) ** 2)
            ** 0.5
            for k in range(len(pts) - 1)
        )
    return {
        "crossings": crossings,
        "through_nodes": through,
        "self_overlap": self_overlap,
        "edge_len": round(edge_len, 1),
        "area": round(w * h, 1),
        "nodes": len(nodes),
        "edges": len(paths),
    }


GATED = ("crossings", "through_nodes", "self_overlap")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--update-baseline", action="store_true")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    import yaml

    from app import signal_chain as sc

    data = yaml.safe_load((PROJECT / "docs/signal-chain.yaml").read_text())
    problems = sc.validate(data)
    if problems:
        print("signal-chain.yaml does not validate:")
        for p in problems:
            print(f"  - {p}")
        return 1

    # Measure BOTH orientations, but only gate the one the dashboard actually
    # serves (the sheet's own rankdir, else TB). The other is reachable only
    # by hand-writing a ?rankdir= query — the UI never sends one — so holding
    # it to the same standard would mean fighting dot over a view no operator
    # will ever open. It is still reported, so a real collapse is visible.
    results, served = {}, {}
    for sheet in data.get("diagrams") or []:
        sid = sheet["id"]
        want = sheet.get("rankdir") or "TB"
        served[sid] = want
        for rankdir in ("TB", "LR"):
            dot_src = sc.build_dot(data, rankdir=rankdir, diagram_id=sid)
            key = f"{sid}/{rankdir}"
            results[key] = measure(dot_src)
            results[key]["served"] = rankdir == want

    if args.json:
        print(json.dumps(results, indent=2, sort_keys=True))

    if args.update_baseline:
        BASELINE.write_text(json.dumps(results, indent=2, sort_keys=True) + "\n")
        print(f"baseline written: {BASELINE.relative_to(PROJECT)}")
        for key in sorted(results):
            m = results[key]
            print(
                f"  {key:12} crossings={m['crossings']:3}  "
                f"through_nodes={m['through_nodes']:3}  "
                f"self_overlap={m['self_overlap']:3}  "
                f"edge_len={m['edge_len']:7}  area={m['area']:7}"
            )
        return 0

    if not BASELINE.is_file():
        print(f"no baseline at {BASELINE}; run with --update-baseline")
        return 1
    base = json.loads(BASELINE.read_text())

    failed = False
    for key in sorted(results):
        m = results[key]
        b = base.get(key)
        tag = "served" if m["served"] else "alt   "
        if b is None:
            print(f"  {key:12} [{tag}] NEW (no baseline entry)")
            failed = failed or m["served"]
            continue
        bits = []
        for name in GATED:
            delta = m[name] - b[name]
            flag = "WORSE" if delta > 0 else ("better" if delta < 0 else "same")
            if delta > 0 and m["served"]:
                failed = True
            bits.append(f"{name}={m[name]}({delta:+d} {flag})")
        print(
            f"  {key:12} [{tag}] " + "  ".join(bits)
            + f"  edge_len={m['edge_len']}  area={m['area']}"
        )

    print(
        "FAIL: served layout regressed"
        if failed
        else "OK: no regression in any served layout"
    )
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
