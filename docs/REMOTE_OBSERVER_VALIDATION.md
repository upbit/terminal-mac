# Remote Observer Implementation Evidence

## Current Development Status: 2026-11-09

The P0/P1 records below are historical. Current source includes P2 Hub/Relay
full/delta/ACK, single-writer ready barrier, late-encoding isolation, ACK timeout
without device disconnect, capture shutdown, default low/standard switching,
pending recovery, explicit-cancel classification, live-generation detach and
exact MIME/UTF-8 cancellation checks. Old Web resources and duplicate JS tests
are removed; local NIO transport is only in the test target.

Latest full Swift run: 82 total, 78 passed, 4 opt-in skipped, zero failures.
The local joint opt-in was separately run successfully from the server:
Swift synthetic producer -> loopback device WS -> relay -> isolated Chrome ->
committed ACK, including mode changes, hidden/reopen and explicit revoke.
No real SSO/Keychain/Guest is used. Shared Swift-generated fixture hashes pass;
browser pixels equal the full oracle, and corrupt PNG receives no ACK.
Current source bases are server `79cec68` and client `2c3e066`, plus uncommitted
changes; there is no compatibility/release commit yet.

Helper tests: 10 passed; CLI subprocess tests: 7 passed. Release build succeeded
using `Govijr Code Signing` / `2AECB8B345BA4B952EA6D595AAD94CCE4707A35C`.
Host and bundled Guest each pass `codesign --verify --deep --strict` outside the
sandbox; no trust setting or signing identity was changed. Updated dist help
contains connect/disconnect/hide-cursor. Old observer Web/NIO resources are not
packaged and Auth resources are Host-only. Artifact hashes are in the shared
pre-live record. This signature is not Apple notarization.

C01-C07 now have implementation/local regression evidence; their real SSO,
Guest, timing and phone portions remain unrun. C08 production Web cleanup and
independent source boundaries are implemented; Linux image and actual published
entry acceptance remain open. See the shared
`../../specs/REMOTE_OBSERVER_PRELIVE.md` for commands and release evidence.

## Historical P0/P1 Evidence

Date: 2026-11-08. Stage: P0/P1 computer-side implementation, stopped for server
cooperation. This document does not mark the complete MVP or real-server
acceptance as passed.

## Native QR / Background Follow-up: 2026-11-09

Implemented `connect` foreground bootstrap plus `__observer` background owner,
anonymous bounded pipe IPC, existing observer.lock, matching-account/origin
reuse and Mailbox-only `disconnect`. Entry enables AppKit for interactive
connect; the child uses its own session. Acknowledged online detach closes the
QR window and returns the foreground while preserving the same device WSS.
No background interactive login, launch-at-login or automatic process restart.

Native QR uses CoreImage integer raster scaling and white quiet zone. Waiting
and expired screenshots were rendered and visually checked at
`/private/tmp/terminal-mac-binding-window/{waiting,expired}.png`: stable layout,
visible countdown, grey expired QR with centered regenerate button and disabled
confirmation link. Images are synthetic, not actual binding requests. Button
actions, duplicate click rejection and close-once behavior are tested locally.

The worker diagnoses saved credentials before regenerate/cancel, preserves
confirmation-winning key/deviceId, and discards only an acknowledged cancelled
or canonical invalid candidate. A new cancellation adapter targets the proposed
contract in `../../specs/REMOTE_OBSERVER_QR_ADJUSTMENTS.md`. Upstream presently
does not expose this cancel endpoint or same-ID pending replacement. 404/405 and
unknown/network errors preserve the key; immediate server cancellation is not
claimed. The adjustment was written to upper specs; no upstream source edited.

New tests exercise same-socket detach then disconnect, cancelled pending key
cleanup, confirm/cancel races, unsupported cancel preserving keys, IPC bounds
and cancellation, native UI states, expiry/manual regeneration, and foreground
EOF before/after detach. CLI subprocess tests cover worker SIGTERM/EOF cleanup
and released lock with no real Keychain operations. The earlier 2026-11-08
evidence below is historical; real SSO/Keychain/TLS/mobile and P2 client capture
remain unverified. Signed dist and user VM state were not changed.

Latest follow-up results: Swift 71 total / 67 passed / 4 opt-in skipped /
0 failures, Python helper 10 passed, CLI subprocess 7 passed, JS 12 passed.
`git diff --check` and build-script shell syntax passed. Swift QR/window and
loopback regressions required approved execution outside the sandbox.
Process-level tests verify bootstrap EOF/SIGTERM, and injected worker tests
verify online pipe-detach/socket preservation and pending races; actual Keychain
and real network foreground-to-background handoff remain joint-test items.

## Versions and Environment

- Client base commit: `9fd8daeee0a6e701588f07fbd0aeb14d66f81a3d` plus the
  current uncommitted implementation; no release/compatibility commit yet.
- Server: unchanged by this task; formal identity/binding APIs not present in
  the adjacent source. A compatible server commit is not available yet.
- Protocol: `relayVersion=1`, `tmobVersion=1`, shared protocol dated 2026-11-08.
- Apple silicon, Swift 6.2, Python 3.13.12, installed Playwright 1.59.0 and
  keyring 25.7.0; Google Chrome application present. This is dependency
  inventory, not a successful live authentication claim.

## Local Evidence

The inherited `.build` module caches referenced a previous checkout directory.
Tests use a fresh scratch/module-cache directory without deleting old artifacts:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/remote-observer/ModuleCache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/remote-observer/ModuleCache" \
swift test --scratch-path .build/remote-observer --disable-sandbox \
  --cache-path .build/cache --config-path .build/configuration \
  --security-path .build/security

python3 -B -m unittest discover -s Tests/AuthHelperTests -v
python3 -B -m unittest discover -s Tests/CLIIntegrationTests -v
node --test Tests/ObserverWebTests/observer.test.mjs
```

Full Swift regression requires sandbox-external execution for existing loopback
tests and the system CoreImage/Vision QR path. The sandbox-only run failed those
system operations; the approved external run passed. No real Guest live/record
environment variables were supplied, and no VM start/input action was performed.

Latest results: Swift 60 total / 56 passed / 4 opt-in skipped / 0 failures;
Python helper 10 passed; CLI executable integration 5 passed; JS parser/meter
12 passed. `git diff --check` and `bash -n scripts/build.sh` passed.

Local tests cover:

- Stable observerId/configuration, preserved machine.json, corrupt/symlink file
  rejection; isolated token keys, canonical system-random token generation,
  reuse and Keychain-save-failure ordering with an in-memory credential store.
- Product helper pipe result/size validation and cancellation/reaping with a
  separate synthetic Python fixture, not Chrome or actual Keychain writes.
- Mocked helper behavior: protected identity schema/origin, Cookie rules,
  bounded silent SSO renewal, headless cache, exactly one interactive fallback,
  no login/cache deletion on network/5xx, no interactive login in check-only or
  noninteractive mode. Formal helper does not invoke the old probes.
- Fake RelaySocket: begin/ready/online, ping/pong while binding, pending/bound
  resume without a new begin, unknown fields/types/state rejection, bounded
  control queue, blocked-send timeout and cancellation. No image/ready messages
  are generated by the P1 client.
- Authoritative 410 binding_invalid classification vs HTML, 403 and 5xx;
  terminal QR reconstructed from character cells and decoded by Vision.
- CLI executable checks without authentication: removed observe/port, absent
  VM, lock conflict before login/config, noninteractive server requirement,
  process-exit lock release and unchanged up --plan/help behavior.
- Existing dirty/revision/ACK, PNG, pacing, fake Guest lease, loopback full/delta
  and JS parser/meter regressions. These remain local-engine evidence only.

Actual Keychain persistence, real Chrome cancellation/renewal, target gateway
Swift WebSocket redirects/TLS/extensions/library buffering, and mobile QR/SSO
round-trip are not covered by these mocks and must be checked at handoff.

## Acceptance Status

| ID | Overall status | Current evidence / remaining work |
| --- | --- | --- |
| C01 | blocked | Local CLI/isolation/helper checks pass; real SSO and new paths await service |
| C02 | blocked | Candidate storage and binding state machine tested with mocks; real Keychain, confirm and notification-loss integration pending |
| C03 | blocked | P2 Hub/Canvas/ACK path not implemented |
| C04 | blocked | Existing epoch/ACK tests pass; new relay session barrier/generation not implemented |
| C05 | blocked | Helper/socket cancellation tested; real watch/capture lifecycle requires P2 |
| C06 | blocked | Credential-preserving error/retry policy and pending resume mocked; real network/SSO/server restart integration pending |
| C07 | blocked | Existing local algorithm/transport/JS regressions pass; remote Guest/readonly/viewer joint checks pending |
| C08 | blocked | Host helper resource built; independent signed release, frontend migration and real browser acceptance pending |

No server files, signed `dist` bundles, user SSO cache or real device Keychain
items were modified for testing. See `REMOTE_OBSERVER_SETUP.md` for the precise
server handoff and the intentionally unsupported P2 watch path.
