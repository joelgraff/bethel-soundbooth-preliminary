# Multi-session workflow

## Goal

Run **many agent sessions** (diagnostics, troubleshooting, features) while every session shares the **same picture of the system**.

Chat history is **per session**. Shared knowledge is **files on disk**.

## Source of truth (priority)

| Priority | File | Role |
|----------|------|------|
| 1 | `SYSTEM-STATE.md` | How the system is built and how it must behave |
| 2 | `STATUS.md` | What’s done / next across initiatives |
| 3 | `portal/content/*` | Volunteer-facing summaries (must match 1) |
| 4 | `docs/*` | Investigation notes, recovery, designs |

## Starting a focused session

From `/home/soundbooth` or `~/soundbooth-project`, start your AI CLI session in this directory.

First user message examples:

**Diagnostics toolkit**

> Focus: build a diagnostics toolkit for the soundbooth.  
> Read SYSTEM-STATE.md and STATUS.md first. Add check scripts under soundbooth-project/… that verify audio routing, displays/VLC/DP-4, ATEM /dev/video0, and key user services. Update STATUS when done.

**Troubleshooting**

> Focus: troubleshoot [symptom].  
> Read SYSTEM-STATE.md first; do not contradict established routing/display policy unless we discover a real change—then update SYSTEM-STATE.

**Feature**

> Focus: implement [feature].  
> Read SYSTEM-STATE + STATUS. Put code under soundbooth-project/; update both docs if architecture or progress changes.

## Ending a session (handoff)

1. Update **`STATUS.md`** (checkboxes + “Next recommended”).  
2. If hardware/routing/services/display map changed → update **`SYSTEM-STATE.md`**.  
3. Optional: `~/bin/soundbooth-backup-configs.sh` after config edits.
