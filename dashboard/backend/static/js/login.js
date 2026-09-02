(async function init() {
  // Already logged in? Skip straight to the dashboard.
  try {
    const { authenticated } = await api.session();
    if (authenticated) {
      window.location.href = "/index.html";
      return;
    }
  } catch (_) {
    // /api/session itself never redirects (see api.js) — ignore and show the form.
  }
})();

const form = document.getElementById("login-form");
const pinInput = document.getElementById("pin-input");
const errorEl = document.getElementById("login-error");
const btn = document.getElementById("login-btn");

form.addEventListener("submit", async (e) => {
  e.preventDefault();
  errorEl.textContent = "";
  btn.disabled = true;
  try {
    await api.login(pinInput.value);
    window.location.href = "/index.html";
  } catch (err) {
    errorEl.textContent = "Incorrect PIN";
    pinInput.value = "";
    pinInput.focus();
  } finally {
    btn.disabled = false;
  }
});
