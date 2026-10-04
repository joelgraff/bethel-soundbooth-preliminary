#!/usr/bin/env node
// Behaviour test for backend/static/js/widget-camera.js: press-and-hold driving.
// Runs the real source against a tiny DOM/api stub (no browser). exit 0 = pass.
// The point: a camera must never be left driving. Covers resend-while-held,
// stop on release / pointercancel / lost capture / window blur / hidden tab,
// stop after a failed drive, and that disabled buttons don't drive.
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const src = fs.readFileSync(path.join(__dirname, "../backend/static/js/widget-camera.js"), "utf8");
let failed = 0;
const check = (label, cond) => { console.log((cond ? "  ok   - " : "  FAIL - ") + label); if (!cond) failed++; };

async function makeEnv({ failDrive = false } = {}) {
  const calls = [];
  const timers = new Map();
  let nextTimer = 1;
  const listeners = {};
  const mkEl = () => {
    const el = {
      disabled: false, value: "8", dataset: {}, innerHTML: "", textContent: "", className: "", classList: {
        _s: new Set(), add(c) { this._s.add(c); }, remove(c) { this._s.delete(c); }, has(c) { return this._s.has(c); },
      }, _l: {},
      addEventListener(t, f) { (this._l[t] = this._l[t] || []).push(f); },
      setPointerCapture() {}, querySelectorAll() { return []; },
    };
    return el;
  };
  const els = {};
  const getEl = (id) => (els[id] = els[id] || mkEl());
  const held = [];
  const doc = {
    getElementById: getEl,
    querySelectorAll: (sel) => (sel === ".ptz-btn.held" ? held : []),
    addEventListener(t, f) { listeners["doc:" + t] = f; },
    hidden: false,
  };
  const api = {
    ptzMove: async (d, s) => { calls.push(["move", d, s]); if (failDrive && d !== "stop") throw new Error("boom"); return {}; },
    ptzZoom: async (d) => { calls.push(["zoom", d]); if (failDrive && d !== "stop") throw new Error("boom"); return {}; },
    ptzStatus: async () => ({ reachable: true, power: "on", presets: [] }),
    ptzHome: async () => ({}),
  };
  const ctx = {
    document: doc, api, escapeHtml: (s) => s, showToast: () => {}, showConfirmModal: () => {},
    bootstrapLocalToken: async () => {}, localStorage: { getItem: () => null, setItem() {} },
    window: { addEventListener(t, f) { listeners["win:" + t] = f; } },
    setInterval: (f, ms) => { const id = nextTimer++; timers.set(id, { f, ms }); return id; },
    clearInterval: (id) => timers.delete(id),
    parseInt, console,
  };
  vm.createContext(ctx);
  vm.runInContext(src.replace("const HOLD_RESEND_MS", "var HOLD_RESEND_MS"), ctx);
  for (let i = 0; i < 4; i++) await new Promise((r) => setImmediate(r)); // let init() finish
  return { ctx, calls, timers, listeners, mkEl, held, base: timers.size };
}

const tick = () => new Promise((r) => setImmediate(r));
const fire = (btn, type) => (btn._l[type] || []).forEach((f) => f({ pointerId: 1 }));
const tickAll = (timers) => timers.forEach((t) => t.f());

(async () => {
  // press -> immediate drive + repeating timer; release -> timer cleared + stop
  let e = await makeEnv();
  let btn = e.mkEl(); btn.dataset = { dir: "left" };
  e.ctx.wireHoldButton(btn, "move", "left");
  fire(btn, "pointerdown"); await tick();
  check("press drives immediately at the slider speed", JSON.stringify(e.calls) === '[["move","left",8]]');
  check("a resend timer is running while held", e.timers.size === e.base + 1);
  tickAll(e.timers); await tick();
  check("held button re-sends the drive command", e.calls.length === 2 && e.calls[1][1] === "left");
  fire(btn, "pointerup"); await tick();
  check("release clears the timer", e.timers.size === e.base);
  check("release sends a stop", e.calls[e.calls.length - 1][0] === "move" && e.calls[e.calls.length - 1][1] === "stop");

  // each way of losing the pointer must stop
  for (const ev of ["pointercancel", "lostpointercapture"]) {
    e = await makeEnv(); btn = e.mkEl(); e.ctx.wireHoldButton(btn, "move", "up");
    fire(btn, "pointerdown"); await tick(); fire(btn, ev); await tick();
    check(`${ev} stops`, e.timers.size === e.base && e.calls[e.calls.length - 1][1] === "stop");
  }

  // zoom holds stop with a zoom stop, not a pan/tilt stop
  e = await makeEnv(); btn = e.mkEl(); e.ctx.wireHoldButton(btn, "zoom", "in");
  fire(btn, "pointerdown"); await tick(); fire(btn, "pointerup"); await tick();
  check("zoom release sends a ZOOM stop", e.calls[e.calls.length - 1][0] === "zoom" && e.calls[e.calls.length - 1][1] === "stop");

  // disabled buttons never drive
  e = await makeEnv(); btn = e.mkEl(); btn.disabled = true; e.ctx.wireHoldButton(btn, "move", "down");
  fire(btn, "pointerdown"); await tick();
  check("disabled button does not drive", e.calls.length === 0 && e.timers.size === e.base);

  // a failed drive must stop the hold loop (no endless failing resends)
  e = await makeEnv({ failDrive: true }); btn = e.mkEl(); e.ctx.wireHoldButton(btn, "move", "right");
  fire(btn, "pointerdown"); await tick(); await tick();
  check("failed drive ends the hold loop", e.timers.size === e.base);

  // window blur / hidden tab while held
  e = await makeEnv(); btn = e.mkEl(); e.ctx.wireHoldButton(btn, "move", "left");
  fire(btn, "pointerdown"); await tick();
  e.ctx.stopHold(true); await tick();
  check("stopHold(true) (used by blur/hidden) stops quietly", e.timers.size === e.base && e.calls[e.calls.length - 1][1] === "stop");

  // blur/visibility handlers are actually registered by init
  e = await makeEnv();
  await tick(); await tick();
  check("init registers window blur handler", typeof e.listeners["win:blur"] === "function");
  check("init registers visibilitychange handler", typeof e.listeners["doc:visibilitychange"] === "function");

  console.log(failed ? `\n=== ${failed} failed ===` : "\n=== all passed ===");
  process.exit(failed ? 1 : 0);
})();
