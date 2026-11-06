---
name: terminal-mac
description: Operate a separate virtual Mac (macOS VM) with screenshots, clicks, typing and shortcuts, without touching the user's own desktop. Use when a task needs a real macOS GUI — testing a Mac app, using a website or desktop app, or any computer-use task the user wants sandboxed.
---

# terminal-mac

`terminal-mac` runs a real macOS guest on Apple silicon. A helper inside the guest captures its screen and posts input, so everything you do happens in the VM. It never controls the user's own desktop.

## Prefer the MCP tools

If tools named `screenshot`, `click`, `type`, `key` and so on from the `terminal-mac` MCP server are available, use them:

1. `status`: the VM is running and both guest permissions are `true`.
2. `screenshot`: every x/y you pass to other tools is a pixel in this image (top-left origin).
3. Act with `click` (`clicks: 2` double-clicks, `button: "right"`), `move`, `drag`, `scroll` (negative `dy` scrolls down), `type` (literal text) or `key` (`return`, `tab`, `escape`, `cmd+space`, `cmd+c`, `cmd+shift+4`…).
4. Look again: pass `screenshot: true` to an action, or call `screenshot`, before deciding the next step.

Opening an app: `key cmd+space`, `type "Safari"`, `key return`. Prefer keyboard shortcuts over hunting for small targets.

## Without MCP: the CLI

Every command prints JSON and exits nonzero on failure. `NAME` defaults to `default`.

```bash
terminal-mac status NAME                     # stopped → terminal-mac start NAME
terminal-mac action NAME status
terminal-mac action NAME screenshot --output /tmp/guest.png   # then view the PNG
terminal-mac action NAME click X Y [--double] [--button right]
terminal-mac action NAME move X Y
terminal-mac action NAME drag X Y X2 Y2
terminal-mac action NAME type 'literal text'
terminal-mac action NAME key cmd+space
terminal-mac action NAME scroll --dy -300 --x X --y Y
```

Text is sent as Unicode keyboard events, not through the clipboard. No shell-execution action exists.

## Optional task tracing

When `trace_begin` and `chain_begin` are discoverable, prefer grouping a substantial
task into a trace and its meaningful multi-step behaviors into chains. Tracing is
optional: if these tools are missing or return `enabled: false`, continue with the
existing desktop tools. Do not install software or change telemetry settings just
to make tracing available.

- `trace_begin`: pass a concise `goal` and optional opaque conversation `session`.
- `chain_begin`: pass the task/parent-chain `context`, the step's `goal`, and a short
  `reason`, such as "Open Safari to inspect the official API documentation."
- Copy the returned context unchanged into the chain's desktop tools, including
  verification screenshots. Set `actor: "ai"` and optionally a brief action reason.
  A reason is an audit explanation, not private chain-of-thought; omit secrets.
- `chain_end`, then `trace_end`: pass `context`, `outcome` (`success`, `failed`, or
  `cancelled`), and a brief observed result in `summary`. "Done" only acknowledges
  input execution; verify the screen before reporting business success.

Context IDs come from the program, never from the model. Do not reuse a context
for unrelated work or attach to whichever chain happens to be active. If a context
is unavailable, ordinary actions still work as independent traces. On interruption,
close only the contexts you own when possible; otherwise describe the unfinished
work without inventing completion. Open child chains or attached human branches
must finish before their parent can close.

The CLI has equivalent commands on upgraded binaries:

```sh
terminal-mac trace begin --goal 'Inspect API documentation' --session opaque-session
terminal-mac chain begin --context TASK_HANDLE --goal 'Open browser' --reason 'Read the official documentation'
terminal-mac action NAME key cmd+space --context CHAIN_HANDLE --actor ai --reason 'Open Spotlight'
terminal-mac chain end --context CHAIN_HANDLE --outcome success --summary 'Browser opened and verified'
terminal-mac trace end --context TASK_HANDLE --outcome success --summary 'Documentation inspected'
```

CLI `trace status` reports availability; old binaries may not recognize it. Default
action responses remain unchanged, with optional `--trace-envelope` correlation.
Telemetry credentials stay local to terminal-mac. This skill cannot capture the
external model API's token usage or create real generation observations.

Manual Viewer tracing is opt-in through `view --trace-manual [--context HANDLE]`.
The person using the Viewer controls capture pause with Ctrl+P and explicit task
attachment with Ctrl+T. It does not capture native VM-window or host-wide input.
Do not enable manual capture on someone's behalf or request content-mode recording
of passwords, login challenges, payment details, or other sensitive interactions.

## When to stop and ask the user

- The guest is at its login screen, or the helper is not running (tools report "no logged-in session"): ask the user to sign in, for example `terminal-mac view NAME` then Ctrl+O. Automatic login in the guest avoids this on later boots.
- A macOS permission prompt, password, two-factor code or payment appears in the guest.
- The VM does not exist: `terminal-mac up NAME` downloads macOS from Apple (several GB) and needs the user for first-time setup.

## Safety

- Do not run `terminal-mac guest` on the host, and never fall back to host screenshots or host input tools.
- Apps, files and accounts inside the VM are separate from the user's Mac. Do not move secrets into it unless the user asks.
- `stop` requests shutdown; `stop --force` can lose guest work, so use it only when a normal shutdown cannot complete.
