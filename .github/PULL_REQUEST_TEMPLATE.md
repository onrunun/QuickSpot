## Summary

<!-- Briefly describe what this pull request changes and why. -->

## Type of Change

- [ ] Bug fix
- [ ] New feature
- [ ] Localization / Translation
- [ ] Security / Privacy hardening
- [ ] Documentation / CI / Maintenance

## Checklist

- [ ] `swift test` passes locally (including localization parity & privacy tests)
- [ ] `./scripts/check-privacy.sh` passes locally
- [ ] `./build.sh` builds and verifies the signed `.app` bundle
- [ ] No telemetry, analytics, external dependencies, or unrequested network calls added
- [ ] Any new user-facing strings are added across all bundled `.lproj/Localizable.strings` files
