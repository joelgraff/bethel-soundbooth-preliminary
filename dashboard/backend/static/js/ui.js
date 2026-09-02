// Small shared UI helpers: confirm modal + toast. Used by dashboard.js and
// service.js so the confirm-token flow looks and behaves the same everywhere
// a destructive action can be triggered.

function showConfirmModal({ title, message, confirmLabel = "Confirm", onConfirm, onCancel }) {
  const root = document.getElementById("modal-root");
  root.innerHTML = `
    <div class="modal-backdrop" id="modal-backdrop">
      <div class="modal">
        <h3>${escapeHtml(title)}</h3>
        <p>${escapeHtml(message)}</p>
        <div class="row">
          <button class="btn btn-ghost" id="modal-cancel">Cancel</button>
          <button class="btn btn-warn" id="modal-confirm">${escapeHtml(confirmLabel)}</button>
        </div>
      </div>
    </div>`;
  const close = () => { root.innerHTML = ""; };
  document.getElementById("modal-cancel").addEventListener("click", () => { close(); onCancel && onCancel(); });
  document.getElementById("modal-backdrop").addEventListener("click", (e) => {
    if (e.target.id === "modal-backdrop") { close(); onCancel && onCancel(); }
  });
  document.getElementById("modal-confirm").addEventListener("click", () => { close(); onConfirm(); });
}

let toastTimer = null;
function showToast(text) {
  const root = document.getElementById("toast-root");
  root.innerHTML = `<div class="toast">${escapeHtml(text)}</div>`;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { root.innerHTML = ""; }, 3500);
}
