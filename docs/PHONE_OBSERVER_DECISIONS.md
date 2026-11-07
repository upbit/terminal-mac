# Local observer: first implementation decisions

This memo supersedes the initial release scope in PHONE_OBSERVER.md for this
development iteration. The original document remains the broader design baseline,
not a claim that the release/security/performance matrix has passed.

The opt-in low-bandwidth profile and its measurements are now defined in
[PHONE_OBSERVER_LOW_BANDWIDTH.md](PHONE_OBSERVER_LOW_BANDWIDTH.md). It supersedes
the no-deliberate-FPS-reduction decision for that profile only.

## Agreed Scope

- Explicit `terminal-mac observe [NAME]`, HTTP + WS on 127.0.0.1 only.
- Mac browser debug preview: simple iPhone outline, one VM image card, Canvas.
- No HTTPS, proxy, pairing, public access, fullscreen, detail mode, or VM input.
- Multiple browser tabs are permitted with a simple connection limit of 8.
  There is no multi-mode arbitration or advanced multicast/encoding-cache system.
- Independent Guest capture; terminal viewer and its capture behavior stay unchanged.
- ScreenCaptureKit output width 640 pixels by default, internally configurable;
  proportional height, no cropping, no VM display-resolution changes.
- Capture ceiling 30 FPS, no deliberate FPS reduction initially. This is not a
  guarantee of 30 browser commits/second; ACK/encoding/transport impose backpressure.
- Native dirtyRects select candidate 128x128 tiles. Compare candidate pixels to
  avoid resending identical content, then encode changed tiles as lossless PNG.
- First image and reconnect/recovery use full PNG. No changed pixels means no
  image push; static content is not an error.
- Debug shows received application-message bytes, commit FPS, latest batch and
  actual errors. No standalone bandwidth/codec comparison project.
- Preserve essential correctness: accumulated dirty tiles across skipped frames,
  per-connection ACK baselines, one in-flight batch, bounded memory/messages,
  full recovery, and cleanup. Clip partial edge tiles to the actual image bounds.
- Surface Guest/transport errors in debug; do not infer user login state or
  start/resume the VM. Never capture the physical Host as a fallback.

## Native Metadata Findings

Apple WWDC22 session 10155 recommends dirtyRects to avoid application-side
whole-frame delta calculation. The SDK SCStream.h declares dirtyRects in pixels,
representing the union of redrawn and moved rectangles. They describe successive
capture frames, not each browser's ACK baseline. Accumulate them before discarding
intermediate frames. Native output scaling avoids a second Host resampling pass.
Verify output coordinates with a controlled Guest fixture; missing/invalid metadata
or unknown continuity must fall back to a full comparison, not assume no changes.

Sources:
- https://developer.apple.com/videos/play/wwdc2022/10155/
- https://developer.apple.com/documentation/screencapturekit/scstreamframeinfo/dirtyrects

There are no measured dirtyRects-vs-pixel-scan timings or bandwidth-savings claims
in this memo. Integration and test results belong in PHONE_OBSERVER_VALIDATION.md.
