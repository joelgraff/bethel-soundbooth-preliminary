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

# Tint for the device-name cell, so a node still tells you what kind of thing
# it is when you're looking at it in isolation. Keyed by SUBGROUP first: now
# that a group is a component sheet rather than a physical zone, the group id
# says "this is on the PC's sheet", which is not information the box needs to
# repeat. The subgroup is what carries meaning — speakers, screens, monitors.
SUBGROUP_TINT = {
    "house": "#2b4a3c",      # amps and speakers
    "screens": "#36304a",    # displays
    "monitors": "#2b4a3c",   # stage personal monitors
    "dist": "#2f3a4d",       # HDMI distribution
    "sources": "#2b3a55",    # mics, DI, drums
    "avb": "#2f3a4d",        # switches and stageboxes
    "cam": "#2b3a55",
}
GROUP_TINT = {
    "stage": "#2b3a55",
    "pc": "#2f3a4d",
    "atem": "#2f3a4d",
    "mixer": "#2f3a4d",
}
DEFAULT_TINT = "#2f3a4d"


def node_tint(node):
    if node.get("subgroup") in SUBGROUP_TINT:
        return SUBGROUP_TINT[node["subgroup"]]
    return GROUP_TINT.get(node.get("group"), DEFAULT_TINT)

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
    a source -> out, each of them somewhere -> both. This is what puts inputs
    on the left and outputs on the right so edges land facing the direction
    they arrive from instead of arcing around the node body.

    DIRECTION IS DELIBERATELY IGNORED HERE. `two-way` decides where arrowheads
    are drawn, not which face a port lives on. Counting a two-way link as
    using its port in both roles made every AVB port on the stage sheet
    'both', which pushed all of them onto the input face — so every outgoing
    edge left from the top of the box and looped back around it. Links are
    written in flow order (console -> switch -> stagebox), so the written role
    is the right signal for placement even when audio travels both ways."""
    port_ids = {p["id"] for p in (node.get("ports") or [])}
    usage = {pid: set() for pid in port_ids}
    for link in links:
        for role, ref in (("from", link["from"]), ("to", link["to"])):
            if "." not in ref:
                continue
            node_id, port_id = ref.split(".", 1)
            if node_id == node["id"] and port_id in usage:
                usage[port_id].add(role)

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


def node_html_label(node, links, horizontal=True, visible_ports=None):
    """Port placement follows rankdir. In LR the graph flows left-to-right, so
    inputs belong in a left column and outputs in a right one. In TB it flows
    top-to-bottom, so the same split has to become a top row and a bottom row
    — otherwise every edge arrives on the wrong face of the box and loops
    around it, which is exactly the arcing this layout is meant to avoid.

    visible_ports limits which ports are DRAWN (not how they are classified —
    a port's face is a property of the equipment, so it stays stable across
    sheets). On a single-domain sheet the rest are noise: the Booth PC's
    analog line-out means nothing on the video sheet, and drawing it invites
    the reader to hunt for a cable that was deliberately left out."""
    tint = node_tint(node)
    name_cell_inner = (
        f'<FONT POINT-SIZE="12.5" COLOR="{NAME_FG}"><B>{esc(node["label"])}</B></FONT>'
    )
    ports = node.get("ports") or []
    if visible_ports is not None:
        ports = [p for p in ports if p["id"] in visible_ports]
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
    """Off-sheet connector: the far end of a link that leaves this sheet.

    Reads as a destination — "To ATEM Mini Extreme / HDMI in — Camera 3" —
    because on component sheets that is the whole point: every cable that
    goes somewhere else terminates in a label telling you where, and you go
    to that component's own sheet to pick it up.

    The "see <sheet>" line is dropped when the sheet is named after the
    device, which is the normal case now that a sheet IS a component. Saying
    'To ATEM Mini Extreme ... see "ATEM Mini Extreme"' is just noise."""
    port_line = (
        f'<BR/><FONT POINT-SIZE="9" COLOR="{PORT_FG}">{esc(far_port_label)}</FONT>'
        if far_port_label else ""
    )
    name = far_node["label"]
    see_line = ""
    if sheet_title and sheet_title.lower() not in name.lower():
        see_line = (
            f'<BR/><FONT POINT-SIZE="8.5" COLOR="#7c8798">'
            f'see &#8220;{esc(sheet_title)}&#8221;</FONT>'
        )
    return (
        f'<<TABLE BORDER="0" CELLBORDER="1" CELLSPACING="0" CELLPADDING="7" '
        f'COLOR="#4a556688"><TR><TD BGCOLOR="#1a1f28" ALIGN="CENTER">'
        f'<FONT POINT-SIZE="8.5" COLOR="#7c8798">TO</FONT> '
        f'<FONT POINT-SIZE="10.5" COLOR="#c3ccd9">{esc(name)}</FONT>'
        f'{port_line}{see_line}'
        f'</TD></TR></TABLE>>'
    )


def build_dot(data, rankdir="LR", splines="polyline", diagram_id=None):
    groups = {g["id"]: g for g in data.get("groups", [])}
    links = data["links"]
    nodes_by_id = {n["id"]: n for n in data["nodes"]}
    sheets = {d["id"]: d for d in data.get("diagrams", [])}

    # Which sheet does each node live on? (None = every node, single-sheet mode)
    def split_ref(ref):
        return (ref.split(".", 1) + [None])[:2]

    all_links = links

    # Which nodes does a sheet show? Its groups, narrowed to the nodes some
    # link of an allowed KIND actually touches.
    #
    # The kind filter is what lets the three booth sheets share one set of
    # groups without becoming three copies of the same drawing. It exists
    # because the Booth PC carries 11 links (6 video, 2 audio, 3 control) and
    # dot has exactly one flow direction to spend on them — rankdir inside a
    # cluster is silently ignored, so 11 links onto two faces of one box is
    # not something layout tuning can fix. Split by domain the same hub is 6,
    # 2 and 3, and each sheet straightens into a line.
    def sheet_members(sheet):
        gids = set(sheet.get("groups") or [])
        ids = {n["id"] for n in data["nodes"] if n.get("group") in gids}
        kinds = sheet.get("kinds")
        if kinds:
            touched = set()
            for link in all_links:
                if link.get("kind") in kinds:
                    touched.add(split_ref(link["from"])[0])
                    touched.add(split_ref(link["to"])[0])
            ids &= touched
        return ids

    members_by_sheet = {sid: sheet_members(s) for sid, s in sheets.items()}
    this_sheet = sheets.get(diagram_id) or {}
    this_kinds = this_sheet.get("kinds")
    on_ids = members_by_sheet.get(diagram_id, set())

    if diagram_id:
        included_groups = set(this_sheet.get("groups", []))
        groups = {gid: g for gid, g in groups.items() if gid in included_groups}
        data = dict(data, nodes=[n for n in data["nodes"] if n["id"] in on_ids])

    def on_sheet(node_id):
        return diagram_id is None or node_id in on_ids

    def other_sheet_for(node_id, kind):
        """The sheet a stub should point at: one that shows this node AND
        this kind of link. With several booth sheets over the same groups,
        'whichever sheet holds the node' is no longer a unique answer, and
        naming a sheet that filters this kind out would send the reader to a
        drawing where the link simply is not."""
        for sid, sheet in sheets.items():
            if sid == diagram_id or node_id not in members_by_sheet[sid]:
                continue
            kinds = sheet.get("kinds")
            if kinds is None or kind in kinds:
                return sheet
        return {}

    def port_label(node_id, port_id):
        node = nodes_by_id.get(node_id) or {}
        for p in node.get("ports") or []:
            if p["id"] == port_id:
                return p["label"]
        return None

    # Partition links: kept whole, crossing the boundary, or off-sheet entirely.
    # Out-of-kind links are DROPPED, not stubbed — a stub means "this carries
    # on elsewhere", and hanging one off every video port of the PC on the
    # audio sheet reintroduced exactly the hub this split exists to break up.
    # Port in/out classification deliberately still uses ALL links — a port
    # whose only connection leaves the sheet must still be classified from
    # that connection, or it lands on the wrong face of its node.
    kept, crossing = [], []
    for link in links:
        if this_kinds and link.get("kind") not in this_kinds:
            continue
        src_node, _ = split_ref(link["from"])
        dst_node, _ = split_ref(link["to"])
        src_in, dst_in = on_sheet(src_node), on_sheet(dst_node)
        if src_in and dst_in:
            kept.append(link)
        elif src_in or dst_in:
            crossing.append(link)
    links = kept

    # Ports to draw: only those this sheet's own links land on.
    visible_ports = {}
    for link in kept + crossing:
        for ref in (link["from"], link["to"]):
            nid, pid = split_ref(ref)
            if pid:
                visible_ports.setdefault(nid, set()).add(pid)

    lines = [
        "digraph signal_chain {",
        f"  rankdir={rankdir};",
        f'  bgcolor="{BG}";',
        # polyline, not spline: straight segments with clean bends. Splines
        # turned every long link into a swooping curve and — because dot puts
        # an edge label at the curve's midpoint — left the labels floating in
        # mid-canvas, detached from the line they belonged to. ortho is
        # tidier still but routes lines straight THROUGH node boxes, which on
        # a wiring diagram reads as a connection that isn't there.
        f"  splines={splines};",
        # Loose enough that the band of links between the console, the ATEM
        # and the PC has room to fan out and keep its labels on one line.
        "  nodesep=0.6;",
        "  ranksep=1.1;",
        "  newrank=true;",
        '  fontname="Helvetica";',
        '  node [shape=plaintext, fontname="Helvetica"];',
        '  edge [fontname="Helvetica", fontsize=9, arrowsize=0.7, penwidth=1.3];',
    ]

    by_group = {}
    for n in data["nodes"]:
        by_group.setdefault(n.get("group"), []).append(n)

    # Work out the off-sheet connectors BEFORE drawing the clusters, because
    # each one has to be declared INSIDE the cluster holding the node it
    # attaches to. A stub declared at top level belongs to no cluster, and
    # dot then banishes it to the canvas margin — which is what produced the
    # single longest edge on both sheets (the console stub sat far right while
    # the switch it feeds sat centre-left). Declared in the right cluster it
    # lands next to its neighbour and the edge becomes a short stub again.
    # One connector per far endpoint (node+port), so several links to the same
    # far port share a connector instead of stacking duplicates.
    stub_decls, stub_edges, seen_stubs = {}, [], set()
    for link in crossing:
        src_node, src_port = split_ref(link["from"])
        dst_node, dst_port = split_ref(link["to"])
        src_in = on_sheet(src_node)
        near_node_id = src_node if src_in else dst_node
        far_node_id, far_port_id = (
            (dst_node, dst_port) if src_in else (src_node, src_port)
        )
        far_sheet = other_sheet_for(far_node_id, link.get("kind"))
        stub_id = f"__stub_{far_node_id}_{far_port_id or 'node'}"

        if stub_id not in seen_stubs:
            seen_stubs.add(stub_id)
            near_group = nodes_by_id[near_node_id].get("group")
            stub_decls.setdefault(near_group, []).append(
                f"    {stub_id} [label="
                f"{stub_label(nodes_by_id[far_node_id], port_label(far_node_id, far_port_id), far_sheet.get('title', '?'))}];"
            )

        near = (link["from"] if src_in else link["to"]).replace(".", ":", 1)
        stub_edges.append(
            (link, f"{near} -> {stub_id}" if src_in else f"{stub_id} -> {near}")
        )

    def node_decl(n, indent):
        label = node_html_label(
            n,
            all_links,
            horizontal=rankdir in ("LR", "RL"),
            visible_ports=visible_ports.get(n["id"]),
        )
        return f'{indent}{n["id"]} [label={label}];'

    sheet_title = (sheets.get(diagram_id) or {}).get("title")

    for gid, group in groups.items():
        muted = gid == "maintenance"
        members = by_group.get(gid, [])

        # A group box whose label just repeats the sheet title, on a sheet
        # that is only that group, is pure packaging — the page already says
        # "Stage" above the drawing. Dropping it matters because the wasted
        # frame is not just ink: nesting the real subgroup boxes one level
        # deeper measurably loosens dot's packing (stage went from 436 to 383
        # sq in on this alone). Only skipped when the subgroups can carry the
        # labelling themselves.
        redundant = (
            len(groups) == 1
            and group.get("subgroups")
            and group.get("label") == sheet_title
        )
        indent = "  " if redundant else "    "
        if not redundant:
            lines.append(f"  subgraph cluster_{gid} {{")
            lines.append(
                f'    label="  {esc(group["label"])}  "; fontsize=11.5; labeljust="c"; '
                f'fontcolor="{"#6e7787" if muted else "#93a1b5"}"; '
                f'color="{"#3a414d" if muted else "#2c3440"}"; '
                f'style="{"rounded,dashed" if muted else "rounded"}"; margin=24;'
            )

        # Subgroups become nested clusters, which is the only thing dot
        # honours as "keep these together": rank alone will not do it, because
        # rank follows signal-flow depth and that interleaves kinds — the
        # EarMixes ended up sitting between the stageboxes and the switches
        # purely because they are the same number of hops from the console.
        # Grouping by role separates the monitors (endpoints) from the AVB
        # infrastructure (pass-through) regardless of depth.
        for sub in group.get("subgroups") or []:
            in_sub = [n for n in members if n.get("subgroup") == sub["id"]]
            if not in_sub:
                continue
            lines.append(f"{indent}subgraph cluster_{gid}_{sub['id']} {{")
            lines.append(
                f'{indent}  label="  {esc(sub["label"])}  "; fontsize=10; '
                f'labeljust="l"; fontcolor="#7f8a9b"; color="#242c38"; '
                f'style="rounded"; margin=14;'
            )
            for n in in_sub:
                lines.append(node_decl(n, indent + "  "))
            lines.append(f"{indent}}}")

        for n in members:
            if not n.get("subgroup"):
                lines.append(node_decl(n, indent))
        lines.extend(
            d.replace("    ", indent, 1) for d in stub_decls.get(gid, [])
        )
        if not redundant:
            lines.append("  }")

    def edge_attrs(link):
        color = KIND_COLOR.get(link.get("kind"), "#8b949e")
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
        return ", ".join(attrs)

    for link in links:
        endpoints = (
            f'{link["from"].replace(".", ":", 1)} -> {link["to"].replace(".", ":", 1)}'
        )
        lines.append(f"  {endpoints} [{edge_attrs(link)}];")

    for link, endpoints in stub_edges:
        lines.append(f"  {endpoints} [{edge_attrs(link)}];")

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


NODE_KEYS = {"id", "label", "group", "subgroup", "ports"}
PORT_KEYS = {"id", "label", "side"}
LINK_KEYS = {"from", "to", "direction", "kind", "label", "status", "constraint"}
GROUP_KEYS = {"id", "label", "subgroups"}
SUBGROUP_KEYS = {"id", "label"}
DIAGRAM_KEYS = {"id", "title", "groups", "rankdir", "kinds"}


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
    groups = data.get("groups") or []
    group_ids = {g.get("id") for g in groups}

    # Subgroups are scoped to their parent group, so the same short name
    # ("monitors", "sources") can be reused across sheets without colliding.
    subgroups_by_group = {}
    for g in groups:
        for key in set(g) - GROUP_KEYS:
            problems.append(
                f"group {g.get('id')!r}: unexpected key {key!r} "
                f"(quote values containing a comma)"
            )
        subgroups_by_group[g.get("id")] = set()
        for sg in g.get("subgroups") or []:
            for key in set(sg) - SUBGROUP_KEYS:
                problems.append(
                    f"group {g.get('id')!r} subgroup {sg.get('id')!r}: "
                    f"unexpected key {key!r} (quote values containing a comma)"
                )
            subgroups_by_group[g.get("id")].add(sg.get("id"))

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
        if n.get("subgroup"):
            known = subgroups_by_group.get(n.get("group"), set())
            if n["subgroup"] not in known:
                problems.append(
                    f"node {nid!r}: unknown subgroup {n['subgroup']!r} "
                    f"for group {n.get('group')!r}"
                )
        ports_by_node[nid] = set()
        for p in n.get("ports") or []:
            for key in set(p) - PORT_KEYS:
                problems.append(f"node {nid!r} port {p.get('id')!r}: unexpected key {key!r} "
                                f"(quote values containing a comma)")
            if p.get("side") and p["side"] not in ("in", "out", "both"):
                problems.append(f"node {nid!r} port {p.get('id')!r}: side must be in/out/both")
            ports_by_node[nid].add(p.get("id"))

    for sheet in data.get("diagrams") or []:
        for key in set(sheet) - DIAGRAM_KEYS:
            problems.append(
                f"diagram {sheet.get('id')!r}: unexpected key {key!r} "
                f"(quote values containing a comma)"
            )
        if sheet.get("rankdir") not in (None, "TB", "LR"):
            problems.append(
                f"diagram {sheet.get('id')!r}: rankdir must be TB or LR"
            )
        for kind in sheet.get("kinds") or []:
            if kind not in KIND_COLOR:
                problems.append(
                    f"diagram {sheet.get('id')!r}: unknown kind {kind!r} "
                    f"(have: {sorted(KIND_COLOR)})"
                )
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
               rankdir: str | None = None) -> str:
    """rankdir=None means "whatever this sheet asks for". Sheets differ:
    the stage sheet lays out its source -> infrastructure -> monitors chain
    far better left-to-right, while the booth sheet's video spine wants
    top-to-bottom. An explicit rankdir argument still overrides, so the UI
    toggle keeps working."""
    data = _load(project_dir)
    sheets = {s["id"]: s for s in (data.get("diagrams") or [])}
    if sheet_id in ("all", "", None):
        sheet_id = None
    elif sheet_id not in sheets:
        raise SignalChainError(
            f"no such sheet {sheet_id!r} (have: {sorted(sheets)})"
        )

    if rankdir is None:
        rankdir = (sheets.get(sheet_id) or {}).get("rankdir") or "TB"

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
