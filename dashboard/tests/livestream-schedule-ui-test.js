#!/usr/bin/env node
// Tests the Livestream Schedule panel's frontend logic against the REAL source.
//
// Run: node dashboard/tests/livestream-schedule-ui-test.js     (exit 0 = pass)
//
// Why this exists: the panel decides, from server state alone, whether the
// day/time controls are safe to show. Get that wrong and the UI silently
// rewrites a schedule someone set deliberately from the CLI. That branch is
// worth a test, and it cannot be checked by eye on a screenshot.
//
// This machine has no usable headless browser (no Chrome; Vivaldi strips
// headless support; Firefox --screenshot produces no file), so rather than skip
// frontend verification entirely, the schedule block is sliced out of
// dashboard.js and evaluated against a DOM stub. It reads the real file on every
// run, so it cannot drift from the shipped code the way a copied fixture would.
// It does NOT check appearance/CSS — only behaviour.

const fs = require("fs");
const path = require("path");

const DASHBOARD_JS = path.join(__dirname, "..", "backend", "static", "js", "dashboard.js");
const START_MARKER = "// ---------- livestream schedule ----------";
const END_MARKER = "// ---------- init ----------";

function extractScheduleBlock() {
  const src = fs.readFileSync(DASHBOARD_JS, "utf8");
  const start = src.indexOf(START_MARKER);
  const end = src.indexOf(END_MARKER);
  if (start === -1 || end === -1 || end <= start) {
    throw new Error(
      `could not locate the schedule block in ${DASHBOARD_JS} — ` +
        "if those section comments were renamed, update START_MARKER/END_MARKER here."
    );
  }
  return src.slice(start, end);
}

// --- DOM stub: just enough for the branches refreshSchedule() actually takes ---
const els = {};
function mkEl(id) {
  return {
    id,
    _text: "",
    className: "",
    style: { display: "" },
    value: "",
    dataset: {},
    innerHTML: "",
    children: [],
    set textContent(v) { this._text = String(v); },
    get textContent() { return this._text; },
    classList: {
      _s: new Set(),
      toggle(c, on) { on ? this._s.add(c) : this._s.delete(c); },
      contains(c) { return this._s.has(c); },
    },
    appendChild(c) { this.children.push(c); },
    addEventListener() {},
  };
}
global.document = {
  getElementById: (id) => els[id] || (els[id] = mkEl(id)),
  createElement: () => mkEl("dyn"),
  activeElement: null,
};

let scheduleResponse = null;
global.api = { scheduleGet: async () => scheduleResponse };
global.showToast = () => {};
global.showConfirmModal = () => {};

// eslint-disable-next-line no-eval
eval(extractScheduleBlock());

let fails = 0;
const eq = (d, got, want) => {
  if (got === want) console.log("  ok   -", d);
  else {
    console.log("  FAIL -", d, "\n         got:", JSON.stringify(got), "\n        want:", JSON.stringify(want));
    fails++;
  }
};
const has = (d, hay, needle) => {
  if (String(hay).includes(needle)) console.log("  ok   -", d);
  else {
    console.log("  FAIL -", d, "\n         got:", JSON.stringify(hay));
    fails++;
  }
};
const deep = (d, got, want) => eq(d, JSON.stringify(got), JSON.stringify(want));

const ARMED_SIMPLE = {
  installed: true, armed: true, unit_file_state: "enabled", active_state: "active",
  schedule: ["Sun *-*-* 09:23:00"], schedule_text: "Sun *-*-* 09:23:00",
  next_run: "Sun 2026-09-20 09:23:00 CDT", last_run: "", stream_active: false,
  relay_boot_enabled: false,
};

(async () => {
  // ---- pure spec parsing / building -------------------------------------
  // Inputs are the exact forms systemd's TimersCalendar reports.
  console.log("=== parseSimpleSpec / buildSpec ===");
  deep("Sunday only", parseSimpleSpec("Sun *-*-* 09:23:00"), { days: ["Sun"], time: "09:23" });
  deep("two days", parseSimpleSpec("Wed,Sun *-*-* 18:30:00"), { days: ["Wed", "Sun"], time: "18:30" });
  deep("daily (no day part)", parseSimpleSpec("*-*-* 09:23:00"),
    { days: ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"], time: "09:23" });
  // Anything the day+time controls cannot represent must be refused, so the UI
  // falls back to read-only instead of mangling it.
  eq("non-zero seconds -> null", parseSimpleSpec("Sun *-*-* 09:23:30"), null);
  eq("two times -> null", parseSimpleSpec("Sun *-*-* 09:23:00,17:00:00"), null);
  eq("specific date -> null", parseSimpleSpec("2026-09-20 09:23:00"), null);
  eq("monthly -> null", parseSimpleSpec("Sun *-*-01 09:23:00"), null);
  eq("junk -> null", parseSimpleSpec("hourly"), null);
  eq("empty -> null", parseSimpleSpec(""), null);
  eq("build one day", buildSpec(["Sun"], "09:23"), "Sun 09:23");
  eq("build reorders to week order", buildSpec(["Wed", "Sun"], "18:30"), "Sun,Wed 18:30");
  eq("build all 7 -> bare time (daily)",
    buildSpec(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"], "09:23"), "09:23");

  // ---- refreshSchedule() rendering branches -----------------------------
  console.log("=== armed, simple weekly spec ===");
  scheduleResponse = { ...ARMED_SIMPLE };
  await refreshSchedule();
  eq("pill text", els["sched-pill"].textContent, "armed");
  eq("pill class", els["sched-pill"].className, "pill pill-good");
  has("next run shown", els["sched-next"].textContent, "Sun 2026-09-20 09:23:00 CDT");
  eq("editor visible", els["sched-editor"].style.display, "");
  eq("advanced hidden", els["sched-advanced"].style.display, "none");
  eq("time populated", els["sched-time"].value, "09:23");
  eq("warn hidden", els["sched-warn"].style.display, "none");
  eq("arm button says Disarm", els["sched-arm-btn"].textContent, "Disarm");

  console.log("=== streaming right now ===");
  scheduleResponse = { ...ARMED_SIMPLE, stream_active: true };
  await refreshSchedule();
  has("streaming now suffix", els["sched-next"].textContent, "streaming now");

  console.log("=== disarmed ===");
  scheduleResponse = { ...ARMED_SIMPLE, armed: false, unit_file_state: "disabled",
    active_state: "inactive", next_run: "" };
  await refreshSchedule();
  eq("pill text", els["sched-pill"].textContent, "disarmed");
  eq("pill class", els["sched-pill"].className, "pill pill-warn");
  has("explains manual only", els["sched-next"].textContent, "only start manually");
  eq("arm button says Arm", els["sched-arm-btn"].textContent, "Arm");

  console.log("=== relay boot-enabled (regression guard) ===");
  scheduleResponse = { ...ARMED_SIMPLE, relay_boot_enabled: true };
  await refreshSchedule();
  eq("warn visible", els["sched-warn"].style.display, "");
  has("warn mentions boot", els["sched-warn"].textContent, "every boot will go live");

  console.log("=== complex spec -> read-only, never editable ===");
  scheduleResponse = { ...ARMED_SIMPLE,
    schedule: ["Sun *-*-* 09:23:00,17:00:00"], schedule_text: "Sun *-*-* 09:23:00,17:00:00" };
  await refreshSchedule();
  eq("editor hidden", els["sched-editor"].style.display, "none");
  eq("advanced visible", els["sched-advanced"].style.display, "");
  has("raw spec shown", els["sched-advanced-spec"].textContent, "09:23:00,17:00:00");
  eq("advanced arm button labelled", els["sched-arm-btn-adv"].textContent, "Disarm");

  console.log("=== timer not installed ===");
  scheduleResponse = { installed: false, armed: false, unit_file_state: "unknown",
    active_state: "unknown", schedule: [], schedule_text: "", next_run: "", last_run: "",
    stream_active: false, relay_boot_enabled: false };
  await refreshSchedule();
  eq("pill neutral", els["sched-pill"].className, "pill pill-neutral");
  eq("editor hidden", els["sched-editor"].style.display, "none");
  eq("advanced hidden", els["sched-advanced"].style.display, "none");
  has("explains not installed", els["sched-next"].textContent, "not installed");

  console.log(fails === 0 ? "\nALL PASS" : `\n${fails} FAILED`);
  process.exit(fails ? 1 : 0);
})();
