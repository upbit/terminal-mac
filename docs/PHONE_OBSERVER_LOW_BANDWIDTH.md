# Low-bandwidth observer

## Header Switch

The Debug title bar now contains a `Low bitrate` switch. Standard startup is off
unless `--low-bandwidth` is supplied. On selects a proportional 480px capture
(or the existing width if already smaller), 10 FPS, 180 KB/s pacing, 128px tiles,
and adaptive PNG. Off restores the standard width/configuration (640px and 30 FPS
by default). CLI overrides apply to the corresponding initial profile. Cursor
visibility remains the explicit `--hide-cursor` startup choice in both modes.

The observer service owns one shared Guest capture: toggling broadcasts the
setting to every connected tab. New tabs and reconnects read the server's setting;
the browser does not persist or overwrite a competing local preference. Mode
changes cancel encoding and the capture task, await lease cleanup, reopen with
the new width/FPS, and send a full image with a new epoch. Old ACKs/decodes cannot
advance the new baseline. Byte debt survives mode changes. The VM display and
terminal viewer are never resized.

Protocol addition: C->S `{type:"mode", lowBandwidth:boolean}`; S->C
`{type:"mode", lowBandwidth:boolean, maxFps:number}` on connection and changes.
Only an actual JSON boolean is accepted; this message shares the lifecycle rate
limit. The frontend disables the switch until connected and while its debounced
request is awaiting confirmation. Errors still leave the confirmed mode visible
so the user can switch back. The actual mirror frame changes only on full commit.

Header-switch regression: 39 Swift tests passed, 4 opt-in tests skipped; 12 JS
tests passed. Fake Guest transport verifies close-before-open and widths
640 -> 480 -> 640. No new live-Guest measurement is claimed by this UI change.
The measurements below remain historical **640px** low-profile results, not a
prediction or measurement of the new 480px profile.

## Strategy

This opt-in profile supersedes the no-throttling decision for `--low-bandwidth`.
Plain `observe` retains the standard 30 FPS / 128 tile / 40% fixed fallback profile.
Terminal capture and input are unchanged. No JPEG, perceptual pixel threshold,
cursor overlay, automatic resolution change, or increased decode concurrency.

```sh
./dist/terminal-mac observe default --low-bandwidth --hide-cursor
```

- Capture and send ceiling: 10 FPS. Guest configuration is negotiated explicitly;
  unsupported helpers fail before opening a lease, not silently ignore options.
- Per-connection budget: 180,000 bytes/s for binary envelopes plus welcomes.
  Heartbeats, HTTP, WS/TCP overhead and retransmission are not included.
- After an image is written, the next encoding opportunity is no earlier than
  `sendTime + max(1/maxFPS, actualMessageBytes/bytesPerSecond)`. Use monotonic time.
  ACK backpressure and encoding costs may reduce the effective FPS further.
- This is byte-driven pacing, not a fixed 10 FPS promise, a network shaper, or an
  arbitrary-window hard cap. There is no minimum FPS that overrides the budget.
  One atomic image can burst above the budget, then must be repaid. At 640x400 the
  recorded initial PNG was 198 KB, followed by about 1.1s of repayment time.
- Idle time earns no credit. Resync, source resets and pause/resume preserve the
  connection's debt. A new WS connection has a fresh first-image allowance.
  Eight viewers have independent budgets, not one shared 180 KB/s limit.
- Keep only the latest source snapshot while waiting. One encoding/sent/ACK slot
  remains in force. A cancellable precise wake sends the final change even if no
  further capture arrives. Do not include budget wait in the ACK timeout.
- Source polling and SCK also respect the configured ceiling. They do not yet
  adapt below that ceiling to an individual viewer's budget or ACK speed.
- `--hide-cursor` sets SCK `showsCursor=false`; it does not suppress genuine hover
  effects. It is optional, explicit, and does not touch terminal capture.

## Tile and Full Selection

128 remains the default. `--tile-size 64` maps accumulated native 128px dirty tiles
onto a finer Host grid, then performs exact pixel comparisons there. Guest dirty
metadata remains compatible. Both welcome and binary image headers identify the
output tile grid; browser validation supports only 64 or 128, including edge tiles.

Low mode uses adaptive PNG selection:

1. First/recovery, all-tile changes, or more than 256 changed tiles: full only.
2. Below 40% coverage and 32 blocks: delta only, avoiding a speculative full encode.
3. Otherwise encode full once, then the changed tiles once. Stop tile encoding
   early when its payload alone exceeds the full envelope. Compare complete
   envelope sizes (including JSON) and select the smaller result.

The 40% value now triggers a comparison, not a mandatory full. This bounded
heuristic is not guaranteed byte-optimal below its comparison region. It trades
Host CPU for fewer bytes near the crossover. There is no repeated quality search.
The browser still decodes at most four PNGs concurrently and validates at most
256 blocks. Larger grids do not raise the message, pixel, or memory limits.

Fixed thresholds are retained for controlled experiments:

```sh
./dist/terminal-mac observe default --low-bandwidth --tile-size 64 --full-threshold 60
./dist/terminal-mac observe default --low-bandwidth --max-fps 8 --budget-kbps 160
```

## Recorded Workload

2026-11-07, Apple silicon / macOS, release Host encoder, Safari inside Guest.
Tripadvisor homepage, visible rotating photo banner, 1280x800 Guest points,
640x400 observer pixels, cursor stationary. Recorded 407 SCK snapshots in 15.02s.
No account login or changes to the website. Raw pixels remain local under
`/private/tmp/observer-budget/tripadvisor`, not in the repository.

All 20 matrix variants replay the **same** captured pixels and timestamps.
Native dirty metadata is not a variable in this comparison. Simulated pacing
uses actual encoded envelope sizes, instantaneous ACK and a precise pending-frame
wake; it does not model network RTT or add measured encode time to simulated time.
Report steady image bytes within the recording window, excluding the first image.
The final pending change is flushed separately, so all variants end on the same image.

| Tile | Selection | Send ceiling/budget | Steady KB/s | Batches incl. first/final | Full batches |
| --- | --- | --- | ---: | ---: | ---: |
| 128 | fixed 40% | 30 FPS / none | 478.9 | 407 | 11 |
| 128 | fixed 40% | 10 FPS / 180 KB/s | 162.8 | 51 | 11 |
| 128 | fixed 60% or 80% | 10 FPS / 180 KB/s | 140.9 | 91 | 1 |
| 128 | adaptive | 10 FPS / 180 KB/s | 140.9 | 91 | 1 |
| 64 | fixed 25% | 10 FPS / 180 KB/s | 165.5 | 52 | 11 |
| 64 | fixed 40%, 60%, 80%, or adaptive | 10 FPS / 180 KB/s | 146.3 | 95 | 1 |

The fixed 25% and 40% variants were identical for 128 in this recording. Without
budget pacing, adaptive 128 used 422.1 KB/s; adaptive 64 used 430.3 KB/s. Threshold
tuning alone therefore did not achieve the 200 KB/s target. With 40% forced full,
low mode spent its budget on larger images and delivered fewer useful updates.
60% worked well here but is not a universal optimum for other pages or sizes.

## Browser Cost

Chrome headless, production `parseBatch` and `drawBatch`, same binary envelopes.
1280x900 at normal CPU and 390x844 with Chrome 4x CPU throttling. The latter is a
stress proxy, **not an iPhone/Android measurement**. Timings exclude fetch, include
PNG validation/CRC, decode, staging Canvas and commit. First image excluded.

| Low-mode adaptive | Blocks P95 | Host encode P95 | Desktop total P95 | 4x CPU total P95 |
| --- | ---: | ---: | ---: | ---: |
| 128 tile | 7 | 10.65 ms | 1.3 ms | 5.2 ms |
| 64 tile | 22 | 4.17 ms | 2.5 ms | 10.8 ms |

64 generates more independently decoded PNGs, increases fixed per-image/header
cost, and can reduce PNG spatial compression. In this banner workload it did not
save bytes. Smaller tiles may still help isolated cursor/text edits; do not infer
that a quarter-sized tile always cuts traffic by 75%.

Adaptive 128 costs more Host encoding than fixed 60% here (10.65 vs 3.56 ms P95),
because it tests a full candidate near the crossover. Both are below the 100ms
10 FPS budget on this Host. Repeated runs and lower-power Hosts remain necessary.
All 20 variants in both browser configurations ended with identical canvas hashes.
This checks the final real image, not every intermediate real Guest frame.

## Live Transport and Limits

A separate actual WS standard-profile run measured 448.9 KB/s over 15s after a
2.5s warmup, 26.3 image batches/s, 10 full + 385 delta; non-overlapping one-second
P95 was 723.9 KB/s. Received-to-ACK P95 was 1.2ms on the Mac browser. This reproduced
the reported bandwidth problem; these are different wall-clock frames from replay.

The first low-profile live attempt correctly rejected an older helper. After
opening the updated shared helper, Guest status reported Screen Recording and
Accessibility false. At that point, further live capture required the user's
system permission approval. No live low-profile, hidden-cursor savings, real mobile hardware,
cellular network, or every-one-second <=200 KB guarantee is claimed by this run.

Subsequently the user removed and re-added the Guest permission entries and
confirmed recovery; a Host status query returned both permissions true. The
Guest window now displays its own `CFBundleVersion` as `rN` in the title bar.
The release package was built and signature-verified as 0.2.2 / build 14, and the
user confirmed it worked. This is functional confirmation, not a new bandwidth
measurement or proof of the cause of the stale permission entries.

## Reproduction

Use a writable Swift module cache if required by the environment. Stop other
observer services before taking the exclusive real Guest recording lease.

```sh
OBSERVER_LIVE_DIRECTORY="$HOME/Library/Application Support/terminal-mac/machines/default" \
OBSERVER_RECORD_OUTPUT=/private/tmp/observer-budget/tripadvisor \
OBSERVER_RECORD_SECONDS=15 swift test --filter ObserverBenchmarkTests.testRecordGuest

OBSERVER_REPLAY_DIRECTORY=/private/tmp/observer-budget/tripadvisor \
swift test -c release --filter ObserverBenchmarkTests.testReplayEncodingMatrix

PLAYWRIGHT_MODULE=/absolute/path/to/playwright \
node scripts/benchmark-observer-browser.mjs /private/tmp/observer-budget/tripadvisor

PLAYWRIGHT_MODULE=/absolute/path/to/playwright \
node scripts/measure-observer-live.mjs default /private/tmp/observer-budget/live
```

The last script starts/stops its own standard and low services, keeps the current
Guest page unchanged, and records each successful case immediately. For a static
desktop cursor experiment, set `OBSERVER_MEASURE_MOTION=1`; only Guest cursor
positions are changed. Never describe a still-animating page as static.

Regression coverage includes byte pacing/no idle credit/large refresh repayment,
last-change wake without another frame, resync debt retention, source option
negotiation and old-helper refusal, native-to-64 mapping, edges, bounded blocks,
full/delta byte selection, parser limits, and negotiated FPS display. The low/64
browser fixture passed intermediate pixel oracle, damaged PNG recovery, pause,
resume, reconnect, two tabs, and 1280/390/320px layout checks.

Initial release Swift regression: 37 passed, 4 opt-in tests skipped, 0 failures.
JS parser/meter: 12 passed. Recording, replay matrix and low/64 browser fixture
were invoked separately. Final pre-commit regression after the header switch and
Guest version label: Swift 39 passed, 4 opt-in skipped; JS 12 passed, no failures.
