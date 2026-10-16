# KUMA, draft plan v2

Status: DRAFT, updated with your answers. Remaining questions are at the bottom.

## What KUMA is

A macOS menu bar app that watches every AI coding session on your Mac (22-25 at a time across Claude Code, OpenCode, Cursor, Codex and others, in iTerm2, Terminal, Ghostty and Orca), keeps a live dashboard, and tells you out loud what each one did and what it needs from you, most urgent first. Every session can be tuned on its own.

## Decided

| Topic | Decision |
| --- | --- |
| Stack | Electron (pending your confirmation of the tradeoffs below) |
| Summaries | Always the same tool the session runs: Claude Code summarizes Claude Code sessions, OpenCode summarizes OpenCode sessions, and so on |
| Heard | Removed, KUMA replaces it |
| Modes | Enabled, Disabled, Do Not Disturb (DND speaks only high priority) |
| Dashboard | Both: a dropdown from the menu bar icon and a full window |
| Orca | Supported. KUMA listens to the agents, not the terminal, so sessions inside Orca work like any other |
| Per session control | Mute and custom behavior for each session |
| Parallel briefings | Stacked, read one after another, never overlapping |
| Paw bubble | Shown at the bottom of the screen while Kuma speaks; click or a key cancels |
| Bring to front | Dropped for now |
| Dictation | Dropped, you use another app |
| VS Code and Cursor terminals | Dropped |

## Stack: Electron

Without dictation and window focusing, the big reasons for Swift are gone, so Electron is a good fit:

- **For:** you work in JS/TS every day; the dashboard and the paw bubble are just web UI; menu bar (Tray), transparent always-on-top overlay windows, launch at login and a local socket server are all built in.
- **Against:** a bigger app (about 150-250 MB) and more memory than native. Fine for a tool you run all day on a dev machine.
- **Voice in Electron:** Kokoro runs in Node through `kokoro-js` (ONNX), loaded once in the background. If quality or speed disappoints, fall back to the Python Kokoro already on your Mac, run as a helper process.
- Orca itself is an Electron app doing similar work, which is a good sign.

## How it works

```
Claude Code ── hooks ──┐
Codex ──────── hooks ──┤
Cursor CLI ─── hooks ──┼─> kuma-hook (tiny CLI) ─> local socket ─> KUMA (Electron main process)
OpenCode ──── plugin ──┘                                          ├─ session store
                                                                  ├─ summarizer (same tool as the session)
                                                                  ├─ briefing stack ─> voice ─> paw bubble
                                                                  └─ tray dropdown, dashboard window
```

- `kuma-hook` sends each event and exits at once. If KUMA is not running it does nothing.
- At startup KUMA also reads Claude Code's live session list and OpenCode's database, so sessions already running appear immediately.
- Summary calls are tagged so they never trigger KUMA's hooks or appear as sessions.

## Sessions

Each session shows: name, project, tool, model, terminal (iTerm2, Terminal, Ghostty, Orca), status, time in status, latest summary.

| Status | Default priority |
| --- | --- |
| Needs approval | high |
| Asking you a question | high |
| Error | high |
| Done, waiting for you | normal |
| Working | not spoken |
| Ended | not spoken |

The summarizer can raise or lower priority based on content ("tests failing, deploy blocked" becomes high).

## Per session behavior

From the dashboard, each session can be set to:

- Mute, or only speak high priority
- Verbosity: one line, or short summary
- Voice or personality override
- Which events to speak (finished, approvals, questions, errors, subagents)

Settings can be saved per project, so a new session in the same project inherits them (see question 2).

## Briefing stack and paw bubble

- Every briefing goes on one stack; Kuma reads them one after another.
- High priority briefings jump ahead of normal ones but never cut off a sentence in progress.
- If the same session sends several updates while waiting, they merge into one.
- While speaking, a small paw bubble appears at the bottom of the screen showing the project name and the line being spoken, plus "+3 more" when others are waiting.
- Click the bubble to stop the current briefing (see question 3 for the key).

## Modes and settings

- Enabled, Disabled, DND (only high priority is spoken; everything still shows in the dashboard)
- Voice, speed, personality presets plus custom ones
- Which tools to watch, whether subagents count
- Launch at login
- Install or remove the hooks for each tool from the app

## Phases

1. **Foundation:** Electron tray app, kuma-hook, Claude Code, summaries via Claude, Kokoro voice, briefing stack, paw bubble, modes. Remove Heard.
2. **All tools:** OpenCode, Cursor CLI, Codex, startup discovery.
3. **Dashboard and control:** full window, per session and per project behavior, personalities, settings.

## Open questions

1. Electron confirmed, given the tradeoffs above?
2. Per session settings: should they also stick to the project for future sessions, or only last for that one session?
3. Cancel key: Esc is risky as a global shortcut because KUMA would grab it from every app while speaking, and Esc is how you interrupt Claude Code. Use a combo like ⌥Esc instead? And does cancel stop only the current briefing, or clear the whole stack?
4. For the same tool rule: which model should each tool use for summaries? Suggested: Claude Code uses Haiku, OpenCode uses its configured small model, Cursor uses its default.
