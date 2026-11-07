# Local Observer Validation

Scope: PHONE_OBSERVER_DECISIONS.md, not the complete PHONE_OBSERVER.md release matrix.
Environment: macOS 15.7.3 (24G419), Apple silicon, Apple Swift 6.2, SwiftNIO 2.105.0.
Build: local debug Host/Guest 0.2.2, latest packaged CFBundleVersion 11. Worktree not committed.

## Implemented

- Independent 640px-wide proportional Guest SCK stream, 30 FPS capture ceiling.
- Native dirtyRects to 128px tile coverage; bounded 128-entry accumulated history.
  Missing/invalid/too-old metadata falls back to full comparison.
- BGRA/LZ4 mailbox transport, bounded decompression, opaque sRGB RGBA, candidate
  pixel comparison, PNG full/delta batches, per-connection revision/ACK baseline.
- One reserved encoding/sent batch per connection; no stale frame queue. Image
  generation occurs off the Guest main actor and off the NIO event loop.
- Loopback HTTP/WS, exact Host/Origin checks, 8 WS connections/24 TCP connections,
  control/message/fragment limits, heartbeat, ACK timeout, readonly fixed routes.
- Simple iPhone outline and Canvas image card, received application bytes, image
  commit FPS, batch details, decode/draw timing and debug errors.
- Background pause, resume/full, reconnect/full, PNG CRC/chunk/bounds validation,
  staging Canvas commit, at most 4 parallel decodes, resource release.
- Guest lease expiry and observer-owned late file/reply cleanup while helper runs.
- Static resources packaged with both Host/Guest copies; terminal viewer files unchanged.

The `stopping` Host state can mean a requested shutdown while VZ still runs. In
that state the observer attempts its readonly Guest capture and surfaces the
actual capture error rather than inferring that the display is already gone.

## Automated Evidence

```sh
swift test --disable-sandbox --cache-path .build/cache \
  --config-path .build/configuration --security-path .build/security
node --test Tests/ObserverWebTests/observer.test.mjs
```

Swift: latest ordinary run 33 tests, 31 passed, 2 opt-in live/browser tests skipped,
0 failures. The live Guest and browser harness tests were run separately and passed.
JS parser: 6 tests passed, including PNG chunk CRC/incomplete payload rejection.

Covered: partial edge tiles, dirty history merging/skips/eviction, identical pixels,
changes during ACK wait, independent clients, stale/future/duplicate ACKs, 100-step
pixel replay oracle, BGRA stride/channel conversion, bounded LZ4 expansion,
Guest/Host fake mailbox negotiation/polling/cleanup, real loopback HTTP and WS
full/delta, wrong Origin and nonexistent action route without starting capture.

Browser reproduction (requires Playwright and Chrome):

```sh
OBSERVER_BROWSER_PORT=33841 OBSERVER_BROWSER_SECONDS=30 swift test \
  --disable-sandbox --cache-path .build/cache --config-path .build/configuration \
  --security-path .build/security --filter testBrowserPreviewHarness
# In a second terminal while the fixture is running:
PLAYWRIGHT_MODULE=/absolute/path/to/playwright node scripts/test-observer-browser.mjs \
  http://127.0.0.1:33841/
```

Chrome desktop 1280x900 and mobile viewport 390x844: passed. Synthetic 640x400
pixel oracle: zero differences over repeated full/delta samples including last
row edge tiles. Two tabs, damaged PNG rejected without ACK/full recovery,
simulated visibility pause/resume, reload/reconnect, no page errors, no horizontal
overflow. Visibility simulation is not real OS browser freezing.

Local screenshots, not committed:
- `/private/tmp/terminal-mac-observer-screenshots/desktop.png`
- `/private/tmp/terminal-mac-observer-screenshots/mobile.png`
- `/private/tmp/terminal-mac-observer-screenshots/guest-error.png`

Build script and signature verification passed with the existing local signing
identity. Repeat resource packaging replaces only the two required bundles;
unrelated stale SwiftPM resource bundles are not copied.

## Initial Real Guest Attempt (Historical)

The user authorized starting the VM for testing. `start default` returned
`already-running`; Host status remained `stopping` (runtime PID 89013). Guest
status responded with Screen Recording and Accessibility allowed, but a Guest
screenshot returned `No guest display is available`. No force-stop, resume, Host
capture fallback or Guest input was performed.

The final packaged preview at `http://127.0.0.1:33842/` connected successfully
and showed `Unknown guest action: observe.capabilities`: the currently running
Guest helper does not yet support the observer protocol. Restarting a VM from
the newly built launcher, then installing/reopening its shared Guest helper,
is also required before live capture can be validated. The observer service
remains available in the background (PID 44237); this is not the VM runtime PID.

That attempt was blocked. The subsequent run below resolved the shutdown/helper
availability blockers. The initial error-path observations are retained as history.

## Real Guest Follow-up: 2026-11-07

After the user manually stopped the VM, `start default` succeeded: runtime PID
95824, state `running`. The Guest reached its desktop and helper became ready,
with Screen Recording and Accessibility already allowed. No extra permission
grant, forced stop, account login, or user-file edits were needed.

Two live issues were reproduced and fixed:

- `GuestObserverSource.close()` was called from a cancelled capture task;
  Mailbox.call immediately observed that cancellation, leaving the Guest lease
  until expiry. Run the bounded close request in an independent task, awaiting
  it before restart. A fake-mailbox cancelled-task regression now covers this.
- The 20 controls/second cap also counted image ACKs, disconnecting a valid
  30 FPS consumer. The cap is now 64 total controls/second; expensive lifecycle
  requests retain the separate limit of 4/second. A 40-ACK burst test passes.

Authorized native dirty coverage test:

```sh
OBSERVER_LIVE_DIRECTORY="$HOME/Library/Application Support/terminal-mac/machines/default" \
  swift test --disable-sandbox --cache-path .build/cache \
  --config-path .build/configuration --security-path .build/security \
  --filter testLiveGuestDirtyCoverage
```

Only the Guest cursor was moved to generate changes. In 8.797 seconds:
185 capture snapshots, 184 with native dirty tile metadata, 1 initial full fallback,
144 changed tile revisions. Selective dirty-tile comparison matched an independent
full-pixel-scan revision oracle on every snapshot, with no omitted changed tile.
This verifies native coverage on this 2x Retina Guest at output 640x400; it is not
a general proof for other displays/configurations or a CPU overhead measurement.

Real browser reproduction (also moves only the Guest cursor):

```sh
PLAYWRIGHT_MODULE=/absolute/path/to/playwright node scripts/test-observer-live.mjs \
  http://127.0.0.1:33842/ default
```

Latest run passed: one full plus 84 delta messages during the cursor-motion sample,
1,825,421 image-message bytes including full/headers, observed 17.6 image batches/sec
over that workload, highest rolling one-second count 29. No production throttling
was added; these counts are not a guaranteed FPS/throughput/bandwidth target.

640x400 Canvas was nonblank. No page error, capture error, or unexpected reconnect
during movement. Simulated hidden/resume required a new full; three page reloads
reconnected within the 5-second test timeout; two tabs worked independently.
The unchanged read-only terminal viewer ran concurrently in a PTY, produced two
1160x720 composed PNG frames and exited via Ctrl+] with status 0 while the browser
remained at width 640. This verifies separate capture sizing and viewer close;
it is not a native terminal screenshot/interactive-input test.

Desktop 1280x900 and mobile viewport 390x844 screenshots were visually checked:
`/private/tmp/terminal-mac-observer-screenshots/live-desktop.png` and `live-mobile.png`.
They stay local and are not added to the repository.

Short idle observation of the actual helper desktop still contained changing
pixels (single-tile updates), so it does not qualify as a perfectly static fixture.
No 10-minute zero-image claim is made; identical candidate-pixel filtering is
covered by the algorithm tests.

VM was left running. Latest local observer service is at
`http://127.0.0.1:33842/` (PID 7558). The former blocker is resolved.

## Debug UI Follow-up

The debug metrics now sit in a compact text card inside the phone screen. The
VM mirror sits toward the bottom, with a connection dot and live transfer rate
directly above it. Debug fields are FPS, Frame, Last batch, Draw speed, Transfer,
and cumulative Received. Draw speed retains the decode + staging/Canvas commit
duration rather than claiming a network or end-to-end latency measurement.

FPS is the current one-second image-commit sample and the highest sample seen
since page load, each capped at 30. The animated bar is current FPS / 30; pauses
and reconnects reset the sample window but preserve the sampled peak. No image
changes produces zero FPS without being interpreted as weak networking.

Transfer is received application-message bytes / elapsed time, displayed as
decimal KB/s (1 KB = 1000 B), in both the debug card and mirror status bar.
Received is the cumulative application payload, including control messages and
reconnects, now displayed consistently as decimal B/KB/MB. No WS/TCP overhead or
network retransmission bytes are inferred.

Green means an image was committed normally. Yellow means connecting/syncing,
paused, recoverable resync, or a measured decode + draw time exceeding the
33.3 ms 30 FPS budget. Red means a Guest error, disconnected socket, or lost
Canvas context. The upstream still does not intentionally reduce FPS, so the
page does not invent a bandwidth warning just because content is idle.

JS tests: 10 passed, including actual-interval rate calculation, sampled peak,
30 FPS clamp, zero-image samples, pause/reconnect resets and duplicate timestamps.
Chrome fixture tests cover nonzero rates and animated meter values, simulated
slow decode (yellow), idle (healthy/zero), Guest error and socket close (red),
recovery (green), full/delta pixel oracle, plus 1280/390/320 px layouts with all
metrics and the mirror inside the phone and no horizontal text overflow.

Latest Swift regression: 31 passed, 2 opt-in tests skipped, 0 failures. Packaged
frontend resources and signature verification passed without changing the Guest
helper build number. The observer alone was restarted; no VM lifecycle action
was needed. Real VM desktop/mobile screenshots show the new card and mirror
placement; a sample displayed 23.0 current / 23.0 sampled Max FPS, 603.8 KB/s,
0.5 ms decode + draw and a green connection indicator. This is a UI observation,
not a performance target. Local screenshots: `debug-live-desktop.png` and
`debug-live-mobile.png` in the existing temporary screenshots directory.
Updated preview remains at `http://127.0.0.1:33842/` (observer PID 40084).

## Compact Layout Refinement

Latest layout refinement: the centered `Debug` heading is outside the metrics
card; the card's ordinary content height is about 200px. `MacOS`, the connection
indicator and transfer rate share a single 20px title row above the mirror.
Removed bottom anchoring and used a fixed section gap so the mirror sits in the
middle/lower screen with whitespace below. At 1280/390/320px browser widths,
the fixture verified centered outside titles, no header wrapping, card height
<= 220px, zero horizontal overflow and at least 50px bottom whitespace (observed
159/156/86px). Pixel oracle and green/yellow/red state tests still pass; ordinary
Swift regression remains 31 passed, 2 opt-in skipped. Static resources rebuilt
and signed; only observer service restarted (PID 52420, same port 33842).

During the final real-page check, VM status was `running` but SCK returned
`No Guest display is available`. The new error layout and red indicator were
visually verified; no VM lifecycle action or permission change was attempted
for this layout-only task. Live image display for this final check was unavailable;
the synthetic image/oracle tests passed.

## Outstanding Coverage

- Browser pixel oracle for every real Guest batch (native metadata oracle and
  synthetic browser oracle are tested separately), other display/scale modes.
- Permission revocation, helper restart/crash cleanup, real freezing and long-run
  memory/CPU/idle capture costs. Helper-crash cleanup across process restarts has
  not been added; current late-reply cleanup depends on the helper remaining alive.
- No throughput/bandwidth/energy targets, 10-minute idle test, iPhone/Android device
  tests, HTTPS/pairing/public-access security or full release matrix are claimed.

There is no measured dirtyRects overhead claim or compression-savings comparison.
Synthetic fixture 2 FPS is only a test workload, not a production FPS throttle.
