# Multi-session workflow

## Goal

Run **many Grok sessions** (diagnostics, troubleshooting, features) while every session shares the **same picture of the system**.

Chat history is **per session**. Shared knowledge is **files on disk** (and optional Grok memory).

## Source of truth (priority)

| Priority | File | Role |
|----------|------|------|
| 1 | `SYSTEM-STATE.md` | How the system is built and how it must behave |
| 2 | `STATUS.md` | What’s done / next across initiatives |
| 3 | `portal/content/*` | Volunteer-facing summaries (must match 1) |
| 4 | `docs/*` | Investigation notes, recovery, designs |
| 5 | Grok memory (`/flush`, MEMORY.md) | Soft recall if enabled |

## Starting a focused session

From `/home/soundbooth` or `~/soundbooth-project`:

```bash
grok
```

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

Grok also loads `AGENTS.md` / `~/.grok/rules/soundbooth.md` automatically so it is reminded to open those files.

## Ending a session (handoff)

1. Update **`STATUS.md`** (checkboxes + “Next recommended”).  
2. If hardware/routing/services/display map changed → update **`SYSTEM-STATE.md`**.  
3. Optional: `/flush` (with memory on) for a searchable summary.  
4. Optional: `~/bin/soundbooth-backup-configs.sh` after config edits.

## Optional: Grok memory

```toml
# ~/.grok/config.toml
[memory]
enabled = true
```

Memory is **supplementary**. Files above remain authoritative so a cold session without memory still works.

## Optional: skills

A skill under `~/.grok/skills/soundbooth/` can force “always read SYSTEM-STATE” for `/soundbooth` style invocations. Project rules already cover normal sessions started in this home directory.
