# PreSonus USB reset helper — test checklist

Run these **in order, before power-cycling the board**. The point of testing
while the board is still wedged is that a wedge is exactly the condition the
helper exists to clear — once you power-cycle, that test case is gone.

Steps 1–3 change nothing and need no privileges. Step 4 is the first one that
installs anything. Step 6 is the first one that touches the board.

---

### 1. Confirm the board is still in the wedged state

```bash
~/bin/presonus-loopback-check.py --verbose      # expect exit 3, capture fails
amixer -c 3 controls >/dev/null && echo "amixer says OK"
```

Expected: the loopback check fails, **and** amixer says OK. That contradiction
is the failure mode. If the loopback check passes, the board recovered on its
own and you are testing something else — note it and skip to step 6.

### 2. Probe, unprivileged, no action

```bash
audio-routing/scripts/presonus-usb-reset --probe
```

Expected: `device is present but NOT responding — a reset is what this would
clear`, exit 0. It should **not** need sudo, and must not change anything.

Verified 2026-09-05 05:50 against the live wedged device: correct verdict,
matching `arecord` ground truth, while `amixer` reported healthy.

### 3. Confirm the helper refuses everything it should

```bash
audio-routing/scripts/presonus-usb-reset                    # exit 3, needs root
audio-routing/scripts/presonus-usb-reset --wipe-everything  # exit 3, unknown arg
audio-routing/scripts/presonus-usb-reset --probe extra      # exit 3, too many args
~/bin/presonus-recover.sh --dry-run                         # exit 3, not installed
```

All four must refuse. If any of them *acts*, stop and do not install.

### 4. Install (the only step needing your password)

```bash
sudo audio-routing/scripts/install-usb-reset-helper.sh
```

The installer syntax-checks the sudoers fragment in a temp file **before**
moving it into `/etc/sudoers.d/`, and removes it again if full validation
fails afterward. A malformed file there locks everyone out of sudo, so it is
deliberately fail-closed.

Then confirm the grant is exactly as narrow as intended:

```bash
sudo -n -l | grep presonus        # should list ONLY the two exact vectors
stat -c '%U %G %a' /usr/local/sbin/presonus-usb-reset   # must be: root root 755
```

If that file is ever writable by `soundbooth`, the grant becomes a root
escalation. `presonus-recover.sh` re-checks this at runtime and refuses.

### 5. Dry run

```bash
~/bin/presonus-recover.sh --dry-run
```

Expected: prints the five-step plan and a probe result, changes nothing,
exit 0.

### 6. The real test — still before power-cycling

```bash
~/bin/presonus-recover.sh
```

It will stop the bridge, reset the USB device, wait for the card, restart the
bridge, and verify with the loopback check.

Three possible outcomes, all informative:

| Result | Meaning |
|---|---|
| `RECOVERED — loopback confirmed` | **The wedge is remotely recoverable.** This is the big one: it means last night's 4-hour outage would have self-healed. |
| `FAILED ... needs a physical power-cycle` | The reset is not sufficient for this failure mode. Still worth keeping for the disconnect-style failures, but the contingency stays "someone must be present." |
| `board is not attached at all` | Board is powered off — not a valid test. |

Have Spotify playing before this step, or the loopback check returns
inconclusive (exit 2) and verifies nothing.

### 7. Confirm the watchdog picks up the escalation

```bash
systemctl --user restart presonus-usb-watch.service
journalctl --user -u presonus-usb-watch.service -n 3 --no-pager
```

Expected: `USB reset escalation ARMED: after 6 consecutive bad polls, max 3/h`.

Before installation it correctly reports NOT available — verified 05:52.

### 8. Then power-cycle the board and re-verify

```bash
~/bin/presonus-loopback-check.py --verbose
```

Do not trust the board's meters or `amixer` for this. Both have read healthy
during a real failure.

---

## Rate limits

Resets are capped at **3/hour** with a **5-minute** minimum gap — much tighter
than the bridge-restart cap of 10/hour, because a reset is disruptive and
hammering a marginal USB link is the pattern that made things worse before.
Manual runs of `presonus-recover.sh` count against the same budget, since the
device does not care who initiated the reset.

Override for testing: `PRESONUS_WATCH_RESET_MIN_GAP_SEC`,
`PRESONUS_WATCH_MAX_RESETS_PER_HOUR`, `PRESONUS_WATCH_RESET_AFTER`.

## Safety properties worth preserving

- The helper takes **no argument that selects a device** — vid:pid is hardcoded.
  It refuses to act if more than one matching device is attached.
- The sudoers grant enumerates two exact argument vectors, no wildcards.
- `presonus-recover.sh` refuses to reset while a recording holds the capture
  device (override with `--force`, which sacrifices the recording).
- Liveness is tested by opening a PCM stream, **never** by reading mixer
  controls. `amixer` is served from the driver's cache, generates no bus
  traffic, and returns healthy against a fully wedged device.
