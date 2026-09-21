# Roadmap

This document is the public-facing status and direction for the project. It is
intentionally short — see `README.md` for capabilities and architecture.

## Status

Active development. The core SSH experience is stable and verified by an
automated test suite covering security, validator fuzzing, credential-storage
behaviour, session lifecycle limits, and reactivity. VNC and RDP are functional
but partial; expect rough edges on real servers until matured.

## What's working

- SwiftUI / SwiftData profile management with search, favorites, tags, and
  recents.
- Credential storage is opt-in and defaults to none (`NullCredentialStore`
  stores nothing). Settings → Security → Credential Storage switches to the
  macOS Keychain or a portable AES-256-GCM-encrypted file
  (PBKDF2-HMAC-SHA256, 600,000 iterations); SSH works via keys/ssh-agent
  with no backend at all, while VNC/RDP need one configured. No plaintext
  on disk, no credentials in environment variables, either way.
- SSH terminal with PTY-write-on-prompt credential delivery: the child `ssh`
  gets the PTY slave as its controlling terminal and prints its normal
  `Password:` prompt there; the stored password — read from whichever
  credential backend is active, if any — is written to the PTY in-memory,
  exactly once — no askpass helper, no on-disk artifact, and nothing
  visible in `ps aux`. Passphrase-protected SSH keys must be loaded into
  `ssh-agent` first; if `ssh` prompts for a passphrase interactively, the
  session stops and tells you so instead of hanging. Host keys are
  trust-on-first-use (`StrictHostKeyChecking=accept-new`); a changed host
  key surfaces as an error pointing at `~/.ssh/known_hosts`.
- Hostname validation that always blocks link-local/metadata addresses
  (169.254.0.0/16, fe80::/10, including IPv4-mapped IPv6), 0.0.0.0, encoded
  IP notation, and command metacharacters. Loopback and RFC 1918 private
  ranges are allowed by default (opt-in flags exist in the validator but no
  setting exposes them yet) — this is a client, not a server guarding
  against SSRF.
- Bounded per-session output buffers, maximum concurrent session cap,
  duplicate-session prevention, and dock badge reflecting active count.
- Sleep/wake session handling: after wake, each still-`.connected` session
  is probed — SSH/RDP by child-process liveness (a dead child surfaces
  `Connection lost during sleep`), VNC by its own read loop — while SSH
  keepalive (`ServerAliveInterval=30`) catches connections whose process
  survived but whose TCP did not.
- Structured in-memory + on-disk logger with correlation IDs and rotation.
  Credentials are never logged.

## Known limitations

- VNC supports the RFB 3.8 baseline (Raw and CopyRect encodings, DES auth,
  mouse/keyboard, clipboard). Authentication is the classic DES challenge
  over a plain, unencrypted TCP socket — tunnel over SSH on untrusted
  networks. Tight/CoRRE/ZRRE encodings and reverse connections are not
  implemented.
- RDP prefers a locally installed native SDL FreeRDP client (`sdl-freerdp` /
  `sdl-freerdp3`) over the X11 `xfreerdp`, falling back to the Microsoft
  Remote Desktop app if neither is present. There is no embedded RDP engine,
  and RDP has not been verified against live servers.
- `Foundation.Process` does not zero the heap after `String` references are
  released, so a process memory dump could in principle still contain an
  unflushed password. Mitigations in place: passwords are released
  immediately after their single use; SSH passwords are written to the
  PTY in response to the server's `Password:` prompt rather than passed
  as a `Process` argument.
- The macOS app sandbox can restrict spawning of non-bundled executables
  (the FreeRDP client). A small set of entitlement exceptions may be
  required when distributing; see the project's release notes for the
  current configuration.

## Future ideas

- Tight/CoRRE/ZRRE encodings and reverse-direction connections for VNC.
- SFTP drag-and-drop file browser over the existing SSH transport.
- Cloud sync of profiles (e.g. iCloud Drive, encrypted export/import round-trip).
- Embedded RDP engine (replace the FreeRDP shell-out for users who prefer
  a fully native experience).
- App notarization with a hardened sandbox profile and helper tool for
  external process spawning.
