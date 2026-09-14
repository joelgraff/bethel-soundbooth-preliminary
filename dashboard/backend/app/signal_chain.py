"""Renders docs/signal-chain.yaml into SVG sheets via Graphviz.

Why Graphviz rather than a JS diagramming library: `record`/HTML-label nodes
give individually-addressable *named ports*, which is the hard requirement
here (a link connects Booth PC's `DP-4` to a specific extender input, not just
"the PC to the extender"). Mermaid has no real port primitive, and `dot` was
already installed on this machine, so this adds no new dependency — same
pattern as the rest of the dashboard shelling out to systemctl/journalctl/
ffmpeg rather than pulling in a library.

Node labels are HTML-like rather than `record` shapes: records give you ports
but no styling control at all, so the device name and its port labels render
identically and a node reads as an undifferentiated row of cells.

Port placement follows rankdir — inputs left / outputs right in LR, inputs top
/ outputs bottom in TB. Getting this wrong makes every edge arrive on the
wrong face of the box and loop around it.

Read-only: this module never writes the YAML. Editing goes through
docs_editor.py like the other reference docs.
"""
from __future__ import annotations

import subprocess
from pathlib import Path

import yaml

SIGNAL_CHAIN_PATH = "docs/signal-chain.yaml"
RENDER_TIMEOUT_SEC = 20


class SignalChainError(RuntimeError):
    pass

# Edge colors by signal kind. Chosen to stay legible on the dark background
# and to be distinguishable from each other for the common forms of color
# blindness (blue / green / amber differ in lightness, not just hue).
KIND_COLOR = {
    "video": "#7aa2f7",
    "audio": "#7ec699",
    "control": "#e0af68",
    "network": "#7dcfff",
    "power": "#f7768e",
}
KIND_LABEL = {
    "video": "Video",
    "audio": "Audio",
    "control": "Control",
    "network": "Network",
    "power": "Power",
}

# Per-group tint for the device-name cell, so a node still tells you which
# zone it belongs to when you're looking at it in isolation.
GROUP_TINT = {
    "stage": "#2b3a55",
    "booth": "#2f3a4d",
    "foh": "#2b4a3c",
    "sanctuary": "#36304a",
    "maintenance": "#33373d",
}
DEFAULT_TINT = "#2f3a4d"

BG = "#0d1117"
CELL_BORDER = "#46516244"
PORT_BG = "#171e2b"
PORT_FG = "#aebacd"
NAME_FG = "#f0f4f9"


def esc(s):
    return (str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def classify_port_sides(node, links):
    """{port_id: 'in'|'out'|'both'}. Explicit port['side'] wins; otherwise
    infer from how the port is used across links — only a target -> in, only
    a source -> out, both (or on a two-way link) -> both. This is what puts
    inputs on the left and outputs on the right so edges land facing the
    direction they arrive from instead of arcing around the node body."""
    port_ids = {p["id"] for p in (node.get("ports") or [])}
    usage = {pid: set() for pid in port_ids}
    for link in links:
        for role, ref in (("from", link["from"]), ("to", link["to"])):
            if "." not in ref:
                continue
            node_id, port_id = ref.split(".", 1)
            if node_id == node["id"] and port_id in usage:
                usage[port_id].add(role)
                if link.get("direction") == "two-way":
                    usage[port_id].update({"from", "to"})

    sides = {}
    for p in node.get("ports") or []:
        pid = p["id"]
        if p.get("side") in ("in", "out", "both"):
            sides[pid] = p["side"]
            continue
        roles = usage.get(pid, set())
        sides[pid] = (
            "out" if roles == {"from"}
            else "in" if roles == {"to"}
            else "both" if roles
            else "out"
        )
    return sides


def port_cell(port, align, rowspan=1, colspan=1):
    span = f' ROWSPAN="{rowspan}"' if rowspan > 1 else ""
    span += f' COLSPAN="{colspan}"' if colspan > 1 else ""
    return (
        f'<TD PORT="{port["id"]}" BGCOLOR="{PORT_BG}" ALIGN="{align}"{span}'
        f'><FONT POINT-SIZE="9.5" COLOR="{PORT_FG}">{esc(port["label"])}</FONT></TD>'
    )


def node_html_label(node, links, horizontal=True):
    """Port placement follows rankdir. In LR the graph flows left-to-right, so
    inputs belong in a left column and outputs in a right one. In TB it flows
    top-to-bottom, so the same split has to become a top row and a bottom row
    — otherwise every edge arrives on the wrong face of the box and loops
    around it, which is exactly the arcing this layout is meant to avoid."""
    tint = GROUP_TINT.get(node.get("group"), DEFAULT_TINT)
    name_cell_inner = (
        f'<FONT POINT-SIZE="12.5" COLOR="{NAME_FG}"><B>{esc(node["label"])}</B></FONT>'
    )
    ports = node.get("ports") or []
    table_open = (
        f'<<TABLE BORDER="0" CELLBORDER="1" CELLSPACING="0" CELLPADDING="6" '
        f'COLOR="{CELL_BORDER}">'
    )

    if not ports:
        return (
            f'{table_open}<TR><TD BGCOLOR="{tint}" CELLPADDING="7">'
            f'{name_cell_inner}</TD></TR></TABLE>>'
        )

    sides = classify_port_sides(node, links)
    ins = [p for p in ports if sides[p["id"]] in ("in", "both")]
    outs = [p for p in ports if sides[p["id"]] == "out"]
    lanes = max(len(ins), len(outs), 1)

    # Uneven port counts: rather than padding the short side with empty cells
    # (blank boxes read as "something is missing"), let its last real port
    # span the leftover lanes so both sides end flush.
    def span_for(plist, i):
        return lanes - i if i == len(plist) - 1 else 1

    body = []
    if horizontal:
        for i in range(lanes):
            cells = []
            if i < len(ins):
                cells.append(port_cell(ins[i], "LEFT", rowspan=span_for(ins, i)))
            if i == 0:
                cells.append(
                    f'<TD ROWSPAN="{lanes}" BGCOLOR="{tint}" ALIGN="CENTER">'
                    f"{name_cell_inner}</TD>"
                )
            if i < len(outs):
                cells.append(port_cell(outs[i], "RIGHT", rowspan=span_for(outs, i)))
            if cells:
                body.append("<TR>" + "".join(cells) + "</TR>")
    else:
        if ins:
            body.append(
                "<TR>"
                + "".join(
                    port_cell(p, "CENTER", colspan=span_for(ins, i))
                    for i, p in enumerate(ins)
                )
                + "</TR>"
            )
        body.append(
            f'<TR><TD COLSPAN="{lanes}" BGCOLOR="{tint}" ALIGN="CENTER">'
            f"{name_cell_inner}</TD></TR>"
        )
        if outs:
            body.append(
                "<TR>"
                + "".join(
                    port_cell(p, "CENTER", colspan=span_for(outs, i))
                    for i, p in enumerate(outs)
                )
                + "</TR>"
            )

    return table_open + "".join(body) + "</TABLE>>"


def legend_label(kinds_used, has_unverified):
    """Solid color swatch cells rather than dash glyphs — a 3px-tall filled
    TD reads as a line sample at any zoom; a '──' character does not."""
    def swatch(color):
        return (
            f'<TD WIDTH="24" HEIGHT="8" FIXEDSIZE="TRUE" BGCOLOR="{color}"></TD>'
        )

    def row(color, text):
        return (
            f'<TR>{swatch(color)}<TD ALIGN="LEFT" CELLPADDING="3">'
            f'<FONT POINT-SIZE="9.5" COLOR="{PORT_FG}">{text}</FONT></TD></TR>'
        )

    rows = [
        f'<TR><TD COLSPAN="2" ALIGN="LEFT"><FONT POINT-SIZE="10" COLOR="{NAME_FG}">'
        f'<B>LEGEND</B></FONT></TD></TR>'
    ]
    rows += [row(KIND_COLOR[k], KIND_LABEL.get(k, k)) for k in kinds_used]
    if has_unverified:
        rows.append(row("#5c6673", "faded + dashed = not yet verified"))
    rows.append(row("#5c6673", "arrows both ends = two-way link"))
    return (
        f'<<TABLE BORDER="0" CELLBORDER="0" CELLSPACING="3" CELLPADDING="2">'
        + "".join(rows) + "</TABLE>>"
    )


def stub_label(far_node, far_port_label, sheet_title):
    """Off-sheet connector: the far end of a link that crosses a sheet
    boundary. Carries the far device AND port name so the reader knows
    exactly where it lands, plus which sheet to go look at."""
    port_line = (
        f'<BR/><FONT POINT-SIZE="9" COLOR="{PORT_FG}">{esc(far_port_label)}</FONT>'
        if far_port_label else ""
    )
    return (
        f'<<TABLE BORDER="0" CELLBORDER="1" CELLSPACING="0" CELLPADDING="7" '
        f'COLOR="#4a556688"><TR><TD BGCOLOR="#1a1f28" ALIGN="CENTER">'
        f'<FONT POINT-SIZE="10.5" COLOR="#c3ccd9">{esc(far_node["label"])}</FONT>'
        f'{port_line}'
        f'<BR/><FONT POINT-SIZE="8.5" COLOR="#7c8798">&#8594; see &#8220;{esc(sheet_title)}&#8221;</FONT>'
        f'</TD></TR></TABLE>>'
    )


def build_dot(data, rankdir="LR", splines="spline", diagram_id=None):
    groups = {g["id"]: g for g in data.get("groups", [])}
    links = data["links"]
    nodes_by_id = {n["id"]: n for n in data["nodes"]}
    sheets = {d["id"]: d for d in data.get("diagrams", [])}

    # Which sheet does each node live on? (None = every node, single-sheet mode)
    node_sheet = {}
    for sheet in sheets.values():
        for gid in sheet.get("groups", []):
            for n in data["nodes"]:
                if n.get("group") == gid:
                    node_sheet[n["id"]] = sheet["id"]

    if diagram_id:
        included_groups = set(sheets[diagram_id].get("groups", []))
        groups = {gid: g for gid, g in groups.items() if gid in included_groups}
        data = dict(data, nodes=[n for n in data["nodes"]
                                 if n.get("group") in included_groups])

    def on_sheet(node_id):
        return diagram_id is None or node_sheet.get(node_id) == diagram_id

    def split_ref(ref):
        return (ref.split(".", 1) + [None])[:2]

    def port_label(node_id, port_id):
        node = nodes_by_id.get(node_id) or {}
        for p in node.get("ports") or []:
            if p["id"] == port_id:
                return p["label"]
        return None

    # Partition links: kept whole, crossing the boundary, or off-sheet entirely.
    # Port in/out classification deliberately still uses ALL links — a port
    # whose only connection leaves the sheet must still be classified from
    # that connection, or it lands on the wrong face of its node.
    all_links = links
    kept, crossing = [], []
    for link in links:
        src_node, _ = split_ref(link["from"])
        dst_node, _ = split_ref(link["to"])
        src_in, dst_in = on_sheet(src_node), on_sheet(dst_node)
        if src_in and dst_in:
            kept.append(link)
        elif src_in or dst_in:
            crossing.append(link)
    links = kept

    lines = [
        "digraph signal_chain {",
        f"  rankdir={rankdir};",
        f'  bgcolor="{BG}";',
        f"  splines={splines};",
        "  nodesep=0.45;",
        "  ranksep=0.85;",
        "  newrank=true;",
        '  fontname="Helvetica";',
        '  node [shape=plaintext, fontname="Helvetica"];',
        '  edge [fontname="Helvetica", fontsize=9, arrowsize=0.7, penwidth=1.3];',
    ]

    by_group = {}
    for n in data["nodes"]:
        by_group.setdefault(n.get("group"), []).append(n)

    for gid, group in groups.items():
        muted = gid == "maintenance"
        lines.append(f"  subgraph cluster_{gid} {{")
        lines.append(
            f'    label="  {esc(group["label"])}  "; fontsize=11.5; labeljust="c"; '
            f'fontcolor="{"#6e7787" if muted else "#93a1b5"}"; '
            f'color="{"#3a414d" if muted else "#2c3440"}"; '
            f'style="{"rounded,dashed" if muted else "rounded"}"; margin=24;'
        )
        for n in by_group.get(gid, []):
            lines.append(
                f'    {n["id"]} '
                f"[label={node_html_label(n, all_links, horizontal=rankdir in ('LR', 'RL'))}];"
            )
        lines.append("  }")

    for link in links:
        kind = link.get("kind")
        color = KIND_COLOR.get(kind, "#8b949e")
        unverified = link.get("status") == "needs-verification"
        attrs = [
            f'color="{color}{"99" if unverified else ""}"',
            f'fontcolor="{color}{"cc" if unverified else ""}"',
            f'dir={"both" if link.get("direction") == "two-way" else "forward"}',
            f'style={"dashed" if unverified else "solid"}',
        ]
        label = (link.get("label") or "").strip()
        if label:
            attrs.append(f'label=" {esc(label)} "')
        if link.get("constraint") is False:
            attrs.append("constraint=false")
        lines.append(
            f'  {link["from"].replace(".", ":", 1)} -> {link["to"].replace(".", ":", 1)} '
            f'[{", ".join(attrs)}];'
        )

    # Off-sheet connectors for links that leave this sheet. One stub per far
    # endpoint (node+port), so several links to the same far port share a
    # single connector instead of stacking duplicates.
    emitted_stubs = set()
    for link in crossing:
        src_node, src_port = split_ref(link["from"])
        dst_node, dst_port = split_ref(link["to"])
        src_in = on_sheet(src_node)
        far_node_id, far_port_id = (dst_node, dst_port) if src_in else (src_node, src_port)
        far_node = nodes_by_id[far_node_id]
        far_sheet = sheets.get(node_sheet.get(far_node_id), {})
        stub_id = f"__stub_{far_node_id}_{far_port_id or 'node'}"

        if stub_id not in emitted_stubs:
            emitted_stubs.add(stub_id)
            lines.append(
                f"  {stub_id} [label="
                f"{stub_label(far_node, port_label(far_node_id, far_port_id), far_sheet.get('title', '?'))}];"
            )

        kind = link.get("kind")
        color = KIND_COLOR.get(kind, "#8b949e")
        unverified = link.get("status") == "needs-verification"
        attrs = [
            f'color="{color}{"99" if unverified else ""}"',
            f'fontcolor="{color}{"cc" if unverified else ""}"',
            f'dir={"both" if link.get("direction") == "two-way" else "forward"}',
            f'style={"dashed" if unverified else "solid"}',
        ]
        label = (link.get("label") or "").strip()
        if label:
            attrs.append(f'label=" {esc(label)} "')
        near = (link["from"] if src_in else link["to"]).replace(".", ":", 1)
        endpoints = f"{near} -> {stub_id}" if src_in else f"{stub_id} -> {near}"
        lines.append(f'  {endpoints} [{", ".join(attrs)}];')

    legend_links = links + crossing
    kinds_used = [k for k in KIND_COLOR if any(l.get("kind") == k for l in legend_links)]
    has_unverified = any(l.get("status") == "needs-verification" for l in legend_links)
    lines.append("  subgraph cluster_legend {")
    lines.append('    label=""; color="#2c3440"; style="rounded"; margin=10;')
    lines.append(f"    __legend [label={legend_label(kinds_used, has_unverified)}];")
    lines.append("  }")

    lines.append("}")
    return "\n".join(lines)


def _load(project_dir: Path) -> dict:
    path = project_dir / SIGNAL_CHAIN_PATH
    if not path.is_file():
        raise SignalChainError(f"{SIGNAL_CHAIN_PATH} not found under {project_dir}")
    try:
        data = yaml.safe_load(path.read_text()) or {}
    except yaml.YAMLError as exc:
        # Surfaced to the operator as-is: after editing the YAML on the Docs
        # page, "line 47: mapping values are not allowed here" is the single
        # most useful thing we can tell them.
        raise SignalChainError(f"{SIGNAL_CHAIN_PATH} is not valid YAML — {exc}") from exc
    if not data.get("nodes"):
        raise SignalChainError(f"{SIGNAL_CHAIN_PATH} has no nodes")
    problems = validate(data)
    if problems:
        shown = "\n".join(f"  · {p}" for p in problems[:12])
        more = f"\n  … and {len(problems) - 12} more" if len(problems) > 12 else ""
        raise SignalChainError(f"{SIGNAL_CHAIN_PATH} has problems:\n{shown}{more}")
    return data


NODE_KEYS = {"id", "label", "group", "ports"}
PORT_KEYS = {"id", "label", "side"}
LINK_KEYS = {"from", "to", "direction", "kind", "label", "status", "constraint"}


def validate(data: dict) -> list[str]:
    """Structural problems a hand-edit can introduce, as human-readable
    messages. Worth doing because Graphviz fails *silently* on most of them:
    a typo'd link ref like `presonus.man_out` doesn't error, it invents a
    blank node and draws an edge to it, so the diagram looks plausible and is
    wrong. Unknown-key checks also catch the YAML flow-mapping trap — an
    unquoted comma in `{id: in, label: In (2 ch, mono each)}` silently splits
    the value and leaves a junk key behind."""
    problems = []
    nodes = data.get("nodes") or []
    node_ids = {n.get("id") for n in nodes}
    group_ids = {g.get("id") for g in (data.get("groups") or [])}

    ports_by_node = {}
    for n in nodes:
        nid = n.get("id")
        if not nid:
            problems.append(f"node without an id: {n!r}")
            continue
        for key in set(n) - NODE_KEYS:
            problems.append(f"node {nid!r}: unexpected key {key!r} (quote values containing a comma)")
        if n.get("group") and n["group"] not in group_ids:
            problems.append(f"node {nid!r}: unknown group {n['group']!r}")
        ports_by_node[nid] = set()
        for p in n.get("ports") or []:
            for key in set(p) - PORT_KEYS:
                problems.append(f"node {nid!r} port {p.get('id')!r}: unexpected key {key!r} "
                                f"(quote values containing a comma)")
            if p.get("side") and p["side"] not in ("in", "out", "both"):
                problems.append(f"node {nid!r} port {p.get('id')!r}: side must be in/out/both")
            ports_by_node[nid].add(p.get("id"))

    for sheet in data.get("diagrams") or []:
        for gid in sheet.get("groups") or []:
            if gid not in group_ids:
                problems.append(f"diagram {sheet.get('id')!r}: unknown group {gid!r}")

    for i, link in enumerate(data.get("links") or []):
        for key in set(link) - LINK_KEYS:
            problems.append(f"link #{i + 1}: unexpected key {key!r} (quote values containing a comma)")
        if link.get("direction") not in (None, "one-way", "two-way"):
            problems.append(f"link #{i + 1}: direction must be one-way or two-way")
        if link.get("status") not in (None, "confirmed", "needs-verification"):
            problems.append(f"link #{i + 1}: status must be confirmed or needs-verification")
        for end in ("from", "to"):
            ref = link.get(end)
            if not ref:
                problems.append(f"link #{i + 1}: missing {end!r}")
                continue
            node_id, _, port_id = str(ref).partition(".")
            if node_id not in node_ids:
                problems.append(f"link #{i + 1}: {end} references unknown node {node_id!r}")
            elif port_id and port_id not in ports_by_node.get(node_id, set()):
                problems.append(
                    f"link #{i + 1}: {end} references unknown port {port_id!r} on {node_id!r}"
                )
    return problems


def list_sheets(*, project_dir: Path) -> list[dict]:
    """The sheets this file defines, or a single implicit 'all' sheet."""
    data = _load(project_dir)
    sheets = data.get("diagrams") or []
    if not sheets:
        return [{"id": "all", "title": "Signal chain"}]
    return [{"id": s["id"], "title": s.get("title", s["id"])} for s in sheets]


def render_svg(*, project_dir: Path, sheet_id: str | None = None,
               rankdir: str = "TB") -> str:
    data = _load(project_dir)
    known = {s["id"] for s in (data.get("diagrams") or [])}
    if sheet_id in ("all", "", None):
        sheet_id = None
    elif sheet_id not in known:
        raise SignalChainError(f"no such sheet {sheet_id!r} (have: {sorted(known)})")

    dot_src = build_dot(data, rankdir=rankdir, diagram_id=sheet_id)
    try:
        result = subprocess.run(
            ["dot", "-Tsvg"], input=dot_src, capture_output=True,
            text=True, timeout=RENDER_TIMEOUT_SEC,
        )
    except FileNotFoundError as exc:
        raise SignalChainError(
            "graphviz is not installed — `sudo apt install graphviz`"
        ) from exc
    except subprocess.TimeoutExpired as exc:
        raise SignalChainError("graphviz timed out rendering the diagram") from exc
    if result.returncode != 0:
        raise SignalChainError(f"graphviz failed: {result.stderr.strip()}")
    return result.stdout
