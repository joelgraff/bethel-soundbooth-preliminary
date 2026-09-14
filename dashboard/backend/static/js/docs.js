// Reference Docs page — view/edit the allowlisted docs in app/docs_editor.py
// (currently: Equipment & Connections, Mixer Channel Map). Renders markdown
// to HTML for reading; Edit swaps to a raw-markdown textarea. Save writes
// straight to the file in the repo's working tree (see docs.html's footnote)
// and is guarded against clobbering a newer version of the file with the
// expected_mtime check in docs_editor.write_doc.

document.getElementById("back-link").innerHTML = `${ICONS.chevronLeft()} Back to Dashboard`;
document.getElementById("docs-icon").innerHTML = ICONS.fileText(24);

let docsList = [];
let activeDocId = null;
let activeDoc = null; // last-loaded {id, title, path, exists, content, mtime}
let editing = false;

async function loadDocsList() {
  let data;
  try {
    data = await api.docsList();
  } catch (err) {
    document.getElementById("doc-title").textContent = "Could not load doc list";
    return;
  }
  docsList = data.docs;
  const params = new URLSearchParams(window.location.search);
  const requested = params.get("doc");
  activeDocId = (requested && docsList.some((d) => d.id === requested))
    ? requested
    : (docsList[0] && docsList[0].id);
  renderTabs();
  if (activeDocId) await loadDoc(activeDocId);
}

function renderTabs() {
  const el = document.getElementById("doc-tabs");
  el.innerHTML = docsList.map((d) => `
    <button class="doc-tab ${d.id === activeDocId ? "active" : ""}" data-doc-id="${d.id}">
      ${escapeHtml(d.title)}
      ${d.exists ? "" : '<span class="doc-tab-badge">not created yet</span>'}
    </button>`).join("");
  el.querySelectorAll("[data-doc-id]").forEach((btn) => {
    btn.addEventListener("click", () => {
      if (editing) {
        showConfirmModal({
          title: "Discard unsaved changes?",
          message: "Switching docs now will lose your edits.",
          confirmLabel: "Discard",
          onConfirm: async () => { setEditing(false); await switchDoc(btn.dataset.docId); },
        });
        return;
      }
      switchDoc(btn.dataset.docId);
    });
  });
}

async function switchDoc(id) {
  activeDocId = id;
  const params = new URLSearchParams(window.location.search);
  params.set("doc", id);
  history.replaceState(null, "", `${window.location.pathname}?${params}`);
  renderTabs();
  await loadDoc(id);
}

async function loadDoc(id) {
  document.getElementById("doc-title").textContent = "Loading…";
  document.getElementById("doc-conflict-warn").style.display = "none";
  let data;
  try {
    data = await api.docsGet(id);
  } catch (err) {
    document.getElementById("doc-title").textContent = "Could not load";
    document.getElementById("doc-view").innerHTML = `<p style="color:var(--fail);">${escapeHtml(err.message)}</p>`;
    return;
  }
  activeDoc = data;
  document.getElementById("doc-title").textContent = data.title;
  document.getElementById("doc-path").textContent = data.path;
  renderView();
  renderActions();
}

function renderView() {
  const view = document.getElementById("doc-view");
  if (!activeDoc.exists) {
    view.innerHTML = `
      <div class="doc-empty">
        <div class="doc-empty-title">Not created yet</div>
        <div>${escapeHtml(activeDoc.path)} doesn't exist in the repo yet. Click Edit to start writing it — saving will create it.</div>
      </div>`;
  } else if (activeDoc.kind === "signal-chain") {
    renderSignalChain(view);
  } else {
    view.innerHTML = renderMarkdown(activeDoc.content);
  }
  view.style.display = "";
  document.getElementById("doc-edit").style.display = "none";
}

// The signal-chain doc is YAML, not prose — view mode shows the rendered
// diagram sheets (Graphviz -> SVG, server side) rather than the source, which
// is what Edit is for. Each sheet is fetched as its own <img> so a failure in
// one doesn't blank the others.
async function renderSignalChain(view) {
  view.innerHTML = `<div class="doc-empty">Rendering diagram…</div>`;
  let sheets;
  try {
    sheets = (await api.signalChainSheets()).sheets;
  } catch (err) {
    view.innerHTML = `
      <div class="sched-warn" style="white-space:pre-wrap;">${escapeHtml(err.message)}</div>
      <div style="margin-top:10px; font-size:12.5px; color:var(--text-muted);">
        Click Edit to fix the YAML.
      </div>`;
    return;
  }
  const bust = activeDoc.mtime || Date.now();
  view.innerHTML = sheets.map((s) => `
    <div class="sigchain-sheet">
      <div class="sigchain-sheet-head">
        <span class="section-title">${escapeHtml(s.title)}</span>
        <a class="btn btn-ghost btn-sm" href="/api/signal-chain/${encodeURIComponent(s.id)}/svg"
           target="_blank" rel="noopener">Open full size</a>
      </div>
      <div class="sigchain-frame">
        <img class="sigchain-img" alt="${escapeHtml(s.title)} signal chain"
             src="/api/signal-chain/${encodeURIComponent(s.id)}/svg?v=${bust}">
      </div>
    </div>`).join("");
}

function renderActions() {
  const el = document.getElementById("doc-actions");
  if (editing) {
    el.innerHTML = `
      <button class="btn btn-ghost btn-sm" id="doc-cancel-btn">Cancel</button>
      <button class="btn btn-primary btn-sm" id="doc-save-btn">Save</button>`;
    document.getElementById("doc-cancel-btn").addEventListener("click", () => {
      if (document.getElementById("doc-edit").value !== (activeDoc.content || "")) {
        showConfirmModal({
          title: "Discard unsaved changes?",
          message: "Your edits to this doc will be lost.",
          confirmLabel: "Discard",
          onConfirm: () => setEditing(false),
        });
        return;
      }
      setEditing(false);
    });
    document.getElementById("doc-save-btn").addEventListener("click", saveDoc);
  } else {
    el.innerHTML = `<button class="btn btn-ghost btn-sm" id="doc-edit-btn">Edit</button>`;
    document.getElementById("doc-edit-btn").addEventListener("click", () => setEditing(true));
  }
}

function setEditing(on) {
  editing = on;
  const view = document.getElementById("doc-view");
  const textarea = document.getElementById("doc-edit");
  if (on) {
    textarea.value = activeDoc.content || "";
    view.style.display = "none";
    textarea.style.display = "";
    textarea.focus();
  } else {
    document.getElementById("doc-conflict-warn").style.display = "none";
    renderView();
  }
  renderActions();
}

async function saveDoc() {
  const saveBtn = document.getElementById("doc-save-btn");
  const content = document.getElementById("doc-edit").value;
  saveBtn.disabled = true;
  saveBtn.textContent = "Saving…";
  try {
    const result = await api.docsSave(activeDocId, content, activeDoc.mtime);
    activeDoc = { ...activeDoc, exists: true, content, mtime: result.mtime };
    editing = false;
    renderView();
    renderActions();
    showToast(`Saved ${activeDoc.path}`);
    await loadDocsList(); // refresh "not created yet" badges without losing the current tab
  } catch (err) {
    if (err.status === 409) {
      const warn = document.getElementById("doc-conflict-warn");
      warn.textContent = err.message;
      warn.style.display = "";
    } else {
      showToast(`Failed to save: ${err.message}`);
    }
  } finally {
    saveBtn.disabled = false;
    saveBtn.textContent = "Save";
  }
}

(async function init() {
  await bootstrapLocalToken();
  await loadDocsList();
})();
