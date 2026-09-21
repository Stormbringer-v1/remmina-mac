# Security Policy

## Supported Versions

RemminaMac is pre-1.0 and moves quickly. Only the latest beta released from
`main` is supported with security fixes; older betas (including 0.9.0-beta)
do not receive backports. Please upgrade to the latest release before
reporting an issue.

## Reporting a Vulnerability

**Please do not open a public GitHub issue for a security vulnerability.**

Instead, use GitHub's private vulnerability reporting: go to the repository's
**Security** tab and choose **"Report a vulnerability"**. This opens a
private draft security advisory visible only to you and the maintainer, so
the issue isn't disclosed before a fix is available.

Include, where relevant:
- The affected version or commit.
- Steps to reproduce, or a minimal proof of concept.
- The impact you believe it has (e.g. credential exposure, arbitrary command
  execution, bypass of host validation).

The maintainer will acknowledge new reports within 7 days. There is no
established bug-bounty program; this is an independent open-source project.

## Scope

Security reports are welcome for areas specific to RemminaMac, including:

- **Credential handling** — the Keychain and AES-256-GCM encrypted-file
  credential backends, and the default no-storage behavior.
- **PTY password delivery** — how SSH and RDP passwords are written to the
  PTY in response to a prompt, and whether they could leak (on disk, in
  process arguments, in logs, via `ps aux`, etc.).
- **Hostname validation** — bypasses of the link-local/metadata-address,
  encoded-IP, and shell-metacharacter checks applied before connecting.
- **Import parsing** — handling of untrusted profile-export files, including
  malformed or adversarial input.
- **VNC and RDP parsers** — the RFB client's framebuffer/message parsing and
  the arguments passed to the external FreeRDP client.

## Out of Scope

Vulnerabilities in `ssh`, `xfreerdp`/`sdl-freerdp`, or other external tools
RemminaMac shells out to are out of scope here — please report those upstream
to the respective project. General macOS or Apple framework vulnerabilities
are also out of scope; report those to Apple.
