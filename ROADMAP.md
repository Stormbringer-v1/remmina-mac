# Roadmap

This document is the public-facing status and direction for the project. It is
intentionally short — see `README.md` for capabilities and architecture.

## Status

Active development. The core SSH experience is stable and verified by an
automated test suite covering security, validator fuzzing, keychain behaviour,
session lifecycle limits, and reactivity. VNC and RDP are functional but partial;
expect rough edges on real servers until matured.

## What's working

- SwiftUI / SwiftData profile management with search, favorites, tags, and
  recents.
- macOS Keychain-backed credential storage. No plaintext on disk, no
  credentials in environment variables.
- SSH terminal with a custom credential pipe (`ssh_askpass` workflow) so the
  Keychain password is delivered in-memory only.
- Hostname validation that blocks SSRF-style encoded IP notation, command
  metacharacters, and (when opted in) loopback / private / metadata ranges.
- Bounded per-session output buffers, maximum concurrent session cap,
  duplicate-session prevention, and dock badge reflecting active count.
- Sleep/wake session handling with keepalive-driven health checking.
- Structured in-memory + on-disk logger with correlation IDs and rotation.
  Credentials are never logged.

## Known limitations

- VNC supports the RFB 3.8 baseline (Raw and CopyRect encodings, DES auth,
  mouse/keyboard, clipboard). Tight/CoRRE/ZRRE encodings and reverse
  connections are not implemented.
- RDP integrates with a locally installed `xfreerdp` (FreeRDP) or the
  Microsoft Remote Desktop app. There is no embedded RDP engine.
- `Foundation.Process` does not zero the heap after `String` references are
  released, so a process memory dump could in principle still contain an
  unflushed password. Mitigations in place: passwords are released
  immediately after their single use; SSH passwords are written to the
  askpass pipe rather than passed as a `Process` argument.
- The macOS app sandbox can restrict spawning of non-bundled executables
  (`xfreerdp`). A small set of entitlement exceptions may be required when
  distributing; see the project's release notes for the current configuration.

## Future ideas

- Tight/CoRRE/ZRRE encodings and reverse-direction connections for VNC.
- SFTP drag-and-drop file browser over the existing SSH transport.
- Cloud sync of profiles (e.g. iCloud Drive, encrypted export/import round-trip).
- Embedded RDP engine (replace the `xfreerdp` shell-out for users who prefer
  a fully native experience).
- App notarization with a hardened sandbox profile and helper tool for
  external process spawning.
