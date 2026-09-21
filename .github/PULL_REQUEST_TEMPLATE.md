## Summary

<!-- What changes and why. Link the issue if there is one. -->

## How it was verified

- [ ] `swift build -Xswiftc -warnings-as-errors` is clean (this is the CI gate)
- [ ] `swift test` passes locally
- [ ] Tested against a live host (say which protocol), or explicitly not applicable

## Checklist

- [ ] No credentials, hostnames, or usernames in logs, tests, or fixtures
- [ ] New tests do not touch the real login keychain or the real Application Support directory
- [ ] Any wall-clock wait in tests is scaled with `ciDeadlineScale`
- [ ] README / CHANGELOG updated if user-visible behaviour changed
