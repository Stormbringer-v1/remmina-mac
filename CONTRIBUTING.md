# Contributing to RemminaMac

Thanks for considering a contribution. This project is a Swift Package, and
the flow below matches what CI (`.github/workflows/build-test.yml`) checks.

## Prerequisites

- macOS 14 Sonoma or later.
- Xcode 16.3+ / Swift 6.1+. The test target uses Swift Testing (6.0+), and
  SwiftTerm 1.10.1's own `Package.swift` uses a trailing-comma argument list
  (SE-0439) that only parses on Swift 6.1+, so anything older fails during
  dependency resolution rather than during compilation of this project's own
  code.

## Building

```bash
swift build -Xswiftc -warnings-as-errors
```

This is the same command CI runs for the main target; keep it warning-free.

## Testing

```bash
swift test
```

Several suites spawn real child processes and open real sockets (PTY/SSH,
VNC, RDP argument-building), so they're slower and more timing-sensitive than
pure unit tests. Process-spawning and socket-based suites are serialized, and
wait deadlines scale under CI via a `ciDeadlineScale` multiplier rather than
using fixed sleeps, to stay reliable on slower CI runners.

## Building the app bundle

```bash
./build_app.sh
```

Produces a `.app` bundle under `dist/`, ad-hoc signed, with the build number
stamped from the commit count.

## Branch and PR flow

- Branch from `main`.
- Open pull requests against `main`.
- CI (build with `-warnings-as-errors`, then `swift test`) must pass before
  merge.

## Conventions

- Tests use **Swift Testing** (`@Test`, `#expect`), not XCTest.
- No test may touch the real login keychain. Keychain-backed tests must use
  a per-run random service name (e.g. `KeychainStore(service:)` with a
  `UUID()`-suffixed identifier) so they're namespaced away from both the
  production service and each other.
- Avoid wall-clock assertions under 2 seconds without scaling them by
  `ciDeadlineScale` — CI runners are slower and less consistent than a local
  machine.
- Keep comments self-explanatory. Don't reference private backlogs, ticket
  numbers, or issue trackers a reader outside the project can't see.

## Running under Thread Sanitizer

`swift test --sanitize=thread` builds the sanitized suite, but on recent
Xcode toolchains you need to launch the built test executable under `.build`
directly rather than relying on `swift test`'s own runner for the run to be
correctly instrumented.
