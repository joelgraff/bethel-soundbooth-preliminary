// Cockpit widget: the AI agent chat on its own, for a narrow pinned column
// (docs/dp1-desktop-cockpit-plan.md). The chat client itself lives in
// agent-chat.js, shared with the main dashboard; this just boots it.
(async function init() {
  await bootstrapLocalToken();
  connectAgentChat();
})();
