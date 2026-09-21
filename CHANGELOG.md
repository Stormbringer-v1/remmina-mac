# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.9.1-beta] - 2026-09-21

### Added
- First-launch hint: when credential storage is set to None, the welcome screen and the profile editor explain that passwords aren't saved yet and offer an "Open Security Settings…" link.
- Screenshots in the README (first launch, main window, SSH session, Settings → Security).

### Fixed
- Idle VNC sessions no longer drop after 30 seconds — a periodic liveness probe plus TCP keepalive keep the connection classified as alive.
- The Reconnect button is enabled again after a session error instead of staying disabled.
- Opening a second VNC tab no longer steals keyboard focus from the tab you were using.
- The fit-to-window toggle and window resize now repaint the VNC canvas instead of leaving stale framebuffer content on screen.
- Clearing the password field no longer deletes the stored password; removing a saved password now requires the explicit "Remove saved password" toggle.
- Deleting a profile closes its live sessions first and only removes stored credentials after the profile deletion itself succeeds.
- Store-corruption recovery now converges: the old, unreadable store is moved aside and a fresh store is created at the original location, with banner text that accurately describes what happened.
- Re-importing a previously exported file no longer duplicates profiles — exports carry stable ids, and the importer reports how many profiles were imported versus skipped.
- Tags containing commas no longer get split into multiple tags.
- A passphrase-protected SSH key now stops the connection with an `ssh-add --apple-use-keychain` instruction instead of a bare "Permission denied".
- An SSH key path rejected by validation fails fast with a clear message instead of proceeding to a confusing connection failure.
- SSH exit output is now mapped to specific errors — permission denied, host key changed, DNS failure, connection refused, timeout, host unreachable — instead of one generic failure message.
- Selecting a profile no longer reads the stored password just to check whether one exists; it uses a Keychain attributes-only query, so it no longer triggers an access-control prompt.
- Unlocking the encrypted credential store no longer freezes the UI while it works.

- With the encrypted-file backend locked, the profile detail now says "Encrypted store locked — unlock it in Settings → Security" instead of "Keychain access denied".
- Settings → Security now refreshes the encrypted store's Locked/Unlocked row after Create, Unlock, and Lock instead of showing stale state.

### Changed
- README and ROADMAP now describe the credential backends and hostname-validation rules as actually implemented.
- Added a root `LICENSE` file.

### Tests
- No test touches the real login keychain.
- Flaky or vacuous tests were fixed or removed.
- Added coverage for prompt classification, SSH diagnostics, the VNC liveness probe, credential existence checks, profile id round-tripping, and session hosting.
- Process-spawning and socket-based suites are serialized and their wait deadlines scale under CI, and the VNC suite is serialized, to harden against slow CI runners.

## [0.9.0-beta] - 2026-09-10

First public beta: SSH/VNC/RDP profiles, PTY password delivery, opt-in credential backends.

[0.9.1-beta]: https://github.com/Stormbringer-v1/remmina-mac/compare/v0.9.0-beta...v0.9.1-beta
[0.9.0-beta]: https://github.com/Stormbringer-v1/remmina-mac/releases/tag/v0.9.0-beta
