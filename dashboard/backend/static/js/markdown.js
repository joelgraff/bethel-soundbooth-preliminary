// Minimal, dependency-free markdown -> HTML renderer for the Docs page.
// Deliberately not a full CommonMark implementation — covers exactly what
// this project's docs actually use (headers, tables, bold/inline code,
// fenced code blocks, ordered/unordered lists with wrapped continuation
// lines, horizontal rules, blockquotes, links) rather than pulling in a
// library from an external CDN, which this booth tool avoids so it keeps
// working with no internet connection.

function mdInline(text) {
  let s = escapeHtml(text);
  // Inline code first so its contents are immune to the bold/link rules below.
  s = s.replace(/`([^`]+)`/g, (_, code) => `<code>${code}</code>`);
  s = s.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
  s = s.replace(/\[([^\]]+)\]\(([^)]+)\)/g, (_, label, href) => {
    const safeHref = /^(https?:|mailto:|#)/i.test(href) ? href : "#";
    return `<a href="${escapeHtml(safeHref)}" target="_blank" rel="noopener">${label}</a>`;
  });
  return s;
}

function splitTableRow(line) {
  let s = line.trim();
  if (s.startsWith("|")) s = s.slice(1);
  if (s.endsWith("|")) s = s.slice(0, -1);
  return s.split("|").map((c) => c.trim());
}

const LIST_ITEM_RE = /^(\s*)([-*]|\d+\.)\s+(.*)$/;
const TABLE_SEP_RE = /^\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$/;

function renderMarkdown(md) {
  const lines = (md || "").replace(/\r\n/g, "\n").split("\n");
  const out = [];
  let i = 0;

  while (i < lines.length) {
    const line = lines[i];

    // Fenced code block — passed through verbatim/escaped, no inline parsing.
    if (/^```/.test(line)) {
      let j = i + 1;
      const codeLines = [];
      while (j < lines.length && !/^```/.test(lines[j])) {
        codeLines.push(lines[j]);
        j++;
      }
      out.push(`<pre><code>${escapeHtml(codeLines.join("\n"))}</code></pre>`);
      i = j + 1; // skip the closing fence too
      continue;
    }

    if (line.trim() === "") { i++; continue; }

    if (/^-{3,}\s*$/.test(line)) { out.push("<hr>"); i++; continue; }

    const h = /^(#{1,6})\s+(.*)$/.exec(line);
    if (h) {
      const level = h[1].length;
      out.push(`<h${level}>${mdInline(h[2])}</h${level}>`);
      i++;
      continue;
    }

    if (/^>\s?/.test(line)) {
      const qLines = [];
      let j = i;
      while (j < lines.length && /^>\s?/.test(lines[j])) {
        qLines.push(lines[j].replace(/^>\s?/, ""));
        j++;
      }
      out.push(`<blockquote>${mdInline(qLines.join(" "))}</blockquote>`);
      i = j;
      continue;
    }

    // Table: a "|"-led row immediately followed by a "|---|---|"-style separator.
    if (/^\s*\|/.test(line) && i + 1 < lines.length && TABLE_SEP_RE.test(lines[i + 1])) {
      const headerCells = splitTableRow(line);
      let j = i + 2;
      const rows = [];
      while (j < lines.length && /^\s*\|/.test(lines[j])) {
        rows.push(splitTableRow(lines[j]));
        j++;
      }
      let html = "<table><thead><tr>" +
        headerCells.map((c) => `<th>${mdInline(c)}</th>`).join("") +
        "</tr></thead><tbody>" +
        rows.map((r) => "<tr>" + r.map((c) => `<td>${mdInline(c)}</td>`).join("") + "</tr>").join("") +
        "</tbody></table>";
      out.push(html);
      i = j;
      continue;
    }

    // Ordered/unordered list, with indented continuation lines folded into
    // the item they follow (this project's docs wrap long list items).
    if (LIST_ITEM_RE.test(line)) {
      const isOrdered = /^\s*\d+\./.test(line);
      const tag = isOrdered ? "ol" : "ul";
      const items = [];
      let j = i;
      while (j < lines.length) {
        const m = LIST_ITEM_RE.exec(lines[j]);
        if (!m) break;
        items.push(m[3]);
        j++;
        while (j < lines.length && /^\s{2,}\S/.test(lines[j]) && !LIST_ITEM_RE.test(lines[j])) {
          items[items.length - 1] += " " + lines[j].trim();
          j++;
        }
      }
      out.push(`<${tag}>` + items.map((it) => `<li>${mdInline(it)}</li>`).join("") + `</${tag}>`);
      i = j;
      continue;
    }

    // Paragraph: merge consecutive plain lines until a blank line or the
    // start of another block type, so wrapped prose renders as one <p>.
    {
      const buf = [line];
      let j = i + 1;
      while (
        j < lines.length && lines[j].trim() !== "" &&
        !/^```/.test(lines[j]) && !/^#{1,6}\s+/.test(lines[j]) &&
        !/^>\s?/.test(lines[j]) && !/^-{3,}\s*$/.test(lines[j]) &&
        !LIST_ITEM_RE.test(lines[j]) && !/^\s*\|/.test(lines[j])
      ) {
        buf.push(lines[j]);
        j++;
      }
      out.push(`<p>${mdInline(buf.join(" "))}</p>`);
      i = j;
    }
  }

  return out.join("\n");
}
