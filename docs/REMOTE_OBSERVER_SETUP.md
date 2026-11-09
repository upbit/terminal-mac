# Remote Observer: Computer-side Setup

Current boundary: client P0-P3 and local P4 preparation are implemented, including
Hub full/delta/ACK, ready barriers and capture cleanup. Local synthetic joint
verification passed; real service/Guest/mobile acceptance is not performed.
`relayVersion=1`, `tmobVersion=1`; fields and limits follow the shared protocol in
`../../specs/REMOTE_OBSERVER_PROTOCOL_V1.md`.

## Dependencies

- macOS 14+ on Apple silicon, an existing VM (it may be stopped).
- Google Chrome in `/Applications` or `~/Applications`.
- Python 3.11+ with `playwright==1.59.0` and `keyring==25.7.0`.
- macOS login Keychain access. No plaintext credential fallback.

Install the packages explicitly in a dedicated environment, for example:

```sh
python3 -m venv "$HOME/Library/Application Support/terminal-mac/auth-venv"
"$HOME/Library/Application Support/terminal-mac/auth-venv/bin/python" -m pip install \
  -r Sources/TerminalMac/Auth/requirements.txt
export TERMINAL_MAC_PYTHON="$HOME/Library/Application Support/terminal-mac/auth-venv/bin/python"
```

The helper uses the installed Chrome (`channel="chrome"`), not a downloaded
Playwright browser. There is no automatic pip/browser installation.
`TERMINAL_MAC_PYTHON` must be an absolute executable path; without it, the CLI
uses `python3` from PATH. Python and package versions are checked by the helper.

For a packaged Host, helper and requirements are located at:

```text
TerminalMac.app/Contents/Resources/terminal-mac_TerminalMac.bundle/Auth/
```

Development builds use the equivalent SwiftPM resource bundle beside the binary.
The build script copies this bundle only into Host, not into Guest. The helper is
not run or imported from a neighboring server checkout. Do not invoke the helper
directly: its stdin/stdout carry private bounded IPC, not a terminal protocol.

## Startup and Credentials

```sh
terminal-mac connect default
terminal-mac connect default --server https://observer.example.net
terminal-mac connect default --force-login
terminal-mac connect default --verbose
terminal-mac disconnect default
```

There is no built-in server URL. Replace `https://observer.example.net` with your
deployed relay's HTTPS origin (scheme, host and optional port, no path).
`--server` configures the selected service without prompting. Otherwise an
interactive terminal prompts for the address; Enter reuses the last successfully
authenticated server only when one is saved. First use requires manual input or
`--server`. The saved address is per VM in `remote-observer.json`; noninteractive
startup accepts `--server` or that saved address and never prompts.

`--verbose` writes foreground connection diagnostics to stderr: selected origin,
helper/Python paths, process IDs, exit status, result byte count, elapsed time,
validated error code and local helper error location, binding events and detach.
It also prints the validated temporary binding URL (including scanToken),
pairingId and expiry. This URL is a short-lived confirmation credential, not
public metadata: remove it before sharing logs. Cookie values, device keys,
raw HTTP headers, response bodies and Python exception messages are never logged.
The helper returns optional structured error metadata over its existing bounded
private result pipe; raw Python/Chrome stderr remains suppressed. Logging ends
when the foreground detaches; this is not a background tracing or file-log mode.

The helper preserves its own process group when Foundation has already created
one; it calls `setsid()` only when inheriting another group. Calling `setsid()`
as a process-group leader fails with EPERM before dependency or SSO checks and
was previously reported as `helper_protocol`. No cache reset is needed for this
startup failure. `--force-login` does not repair it; use a rebuilt client.

The background worker acquires the VM's existing `observer.lock` before
configuration, server selection or login. An absent VM fails immediately. `connect` never calls `up`,
requests Accessibility, starts a VM or captures the physical Host.

`remote-observer.json` in the VM directory stores version, stable random
observerId, last authenticated server and an optional deviceId index. It contains
no Cookie or device token and does not change `machine.json`. The deviceId is
not an authority source: recovery requires the actual device credential.

Separate login-Keychain services are used:

- `dev.terminal-mac.remote-observer.sso.v1`: per exact normalized origin;
  includes this program's own isolated Chrome-context cookies and save time.
- `dev.terminal-mac.remote-observer.device.v1`: per origin, protected identity
  username and local observerId; account name is a SHA-256 key, token is a
  system-generated 32-byte unpadded base64url value.

The product does not read the probe's cache or the user's other browser profiles.
First product login therefore creates its own SSO Keychain entry. Cached login
checks the protected `/api/observer/identity`, not `/healthz` or probe health.
Silent renewal follows at most ten HTTPS-only hops without a device Bearer;
the Chrome cookie jar controls domain/path/secure/expiry on each hop. Only
target-origin applicable cookies reach Swift, which filters them again for the
device WSS and diagnosis path. Business requests refuse redirects.

For first binding, the device key is saved before WSS creation/begin. Keychain
failure aborts without a QR or binding submission. Returned binding paths must
be exactly `/pair#token=<scanToken>` on the selected origin. QR is encoded locally
by CoreImage, integer-scaled into an AppKit window with a white quiet zone and
fixed 306-point area. It is held only in memory by default, not printed or saved;
the explicit `--verbose` diagnostic mode prints its URL as described above.
The window shows countdown, grey overlay and regenerate button after expiry;
there is no scanned state and no success screen. The browser confirmation button
uses the same temporary URL and is disabled on expiry.

The foreground passes authentication to `__observer` using bounded anonymous
pipes. The child validates scope, owns the device Keychain entry and sole WSS,
and reports online. A detach acknowledgement lets the foreground close its
window/pipes and return; the same child/socket survives terminal exit. No launchd,
login item, daemon installer or crash restart is added. The worker never opens a
Chrome login window; manual connect is required when cached silent renewal fails.
`remote-observer-control/` in the VM directory reuses the existing Mailbox API
for status/disconnect only; it stores no QR/Cookie/key. Repeated connect verifies
the current SSO identity before reusing a matching online origin/account worker.

Noninteractive startup never opens a login window or begins pairing. It requires
an explicit/previous server, reusable SSO and a server-validated `bound` key;
pending/unknown binding exits. Keychain UI is disallowed in that mode.

Before detach, window close/Ctrl+C cancels the frontend and stops its worker,
attempting authoritative pending cancellation without deleting a confirmed
Device. After detach, `disconnect`/SIGTERM stops the worker and releases the
lock without unbinding. Ordinary network/TLS/5xx/busy preserve
credentials. Only an explicit server `binding_invalid` invalidates the relevant
device entry; SSO and other origin/account entries are preserved. Reconnect delays are
1/2/4/8/15 seconds plus 0..2 seconds jitter, without repeating server selection.

## Service Handoff

The neighboring server has the formal identity/binding routes. No live
production-route or SSO test was performed in this stage. New upstream contract
requirements are in `../../specs/REMOTE_OBSERVER_QR_ADJUSTMENTS.md` (local copy
`REMOTE_OBSERVER_QR_ADJUSTMENTS.md`).

| Required service capability | Computer expectation |
| --- | --- |
| `GET /api/observer/identity` | Protected same-origin JSON `{username, relayVersion:1}`; no health fallback |
| `GET /api/observer/device-session` | Protected SSO + Bearer diagnosis; `bound` or `binding`, authoritative 410 `binding_invalid` |
| `WSS /ws/observer/device` | SSO-only starts unbound; valid Bearer resumes binding/online; invalid Bearer never downgrades |
| `device.bind.begin/ready` | Same connection; server-generated same-origin bindPath, pairingId, original five-minute expiry |
| Browser `/pair` + inspect/confirm | Same-account explicit POST confirmation; GET must not bind |
| `relay.hello(state=online)` | Push after confirm on the same connection; reconnect with saved key recovers lost notification |
| Relay heartbeat/error limits | 15s ping/45s timeout; fixed code/retryable JSON; v1 field and size validation |
| POST `/api/observer/pairings/cancel` | SSO + candidate Bearer, exact observerId/pairingId; cancelled or confirmation-won result; implemented upstream |

Regenerate is explicit, debounced, and does not extend the old QR. It first
stops/drains the old local connection and diagnoses the saved candidate:
confirmed -> resume online; pending -> cancel exact request; canonical invalid
-> discard. New candidate is saved only after cancellation/invalidity is proven.
Normal close uses the same cancellation rule. If upstream returns 404/405 or a
network/5xx response, the local worker exits or shows an error but preserves the
old key; it must not pretend the server pending is cancelled. Different-key
pending takeover is forbidden. Normal connect restores a valid pending without
cancelling it. Only explicit cancellation/regeneration may replace the key after
acknowledgement; failure cleanup/EOF preserves it. Forced kill/offline relies on
five-minute expiry when cancellation cannot be delivered.

First joint work is P0 protected identity / new Swift WSS gateway behavior,
followed by P1 real QR, pending recovery and lost-confirmation recovery. Verify
TLS/proxy behavior, Cookie/Header handling, rejected redirects, message limits
and WebSocket extension negotiation against the actual gateway.

P2 uses the existing ObserverHub/PNG/revision/pacing engine through a small
transport interface. watch.open invalidates old session outputs; ready shares
the image/control writer and follows old in-flight bytes. Matching subscribe
is required before acquisition. Full/delta are raw TMOB, observation controls
carry sessionId, and only browser ACK advances the baseline. A 10s ACK timeout
ends the watch without disconnecting the device; heartbeat loss closes the
physical connection and stops capture. Old encoding work cannot cross ready.

The old Web decoder/resources are removed. NIO and the local server are now
test-only dependencies; no loopback observer is shipped. `observe` and
`connect --port` only report migration. The client defaults to low bandwidth;
the browser switches 480/640 modes, and `--hide-cursor` is a local startup option.

Release packaging uses the fixed identity from `AGENTS.md` and verifies both
signatures; there is no ad-hoc fallback. Current build evidence and remaining
real-machine gates are in `REMOTE_OBSERVER_VALIDATION.md` and the shared
`../../specs/REMOTE_OBSERVER_PRELIVE.md` record.
