# QuickSpot Project Guidelines

This file defines non-negotiable engineering, privacy, and localization standards for human contributors and coding agents working on QuickSpot.

## Core Invariants

1. **100% Local & Zero Telemetry**: Never add analytics, crash reporting, cloud API calls, or background network requests. The only network actions allowed are explicit user-initiated browser URL/search launches.
2. **Minimal Dependency Discipline**: Build primarily with Apple system frameworks (`Foundation`, `AppKit`, `SwiftUI`, `Vision`, `PDFKit`, `Metal`, `Accelerate`, `JavaScriptCore`, `Carbon`, `SQLite3`, `IOKit`). The only approved SwiftPM package is `GemmaEmbed` (Apache-2.0) for optional on-device EmbeddingGemma 2 inference. Do not add further third-party packages unless strictly justified, license-compatible, and recorded in `THIRD_PARTY_NOTICES.md`.
3. **Privacy Hardening**:
   - Never log user filenames, paths, clipboard items, or OCR text with `privacy: .public` in OSLog.
   - Keep sensitive files (`.env`, `.env.*`, `.pem`, `.key`, SSH keys) excluded from inline previews.
   - Keep password managers and `ConcealedType` / `TransientType` pasteboard entries excluded from clipboard history, and persist local history files with `0600` permissions.
   - Sanitize control/newline characters before interpolating user input into AppleScript.

## Architecture (Vertical Slice + Encapsulation)

- `Sources/QuickSpotCore/` is organized by feature slice (`Localization`, `Contracts`, `AppSearch`, `FileSearch`, `ImageOCR`, `Clipboard`, `QuickActions`).
- `Sources/QuickSpotApp/` holds macOS UI (`Panel`, `Preview`, `Settings`, `Hotkey`, `StatusBarMenu`, `BrandIcon`).
- Keep files focused on a single responsibility (target ~150–250 lines, soft cap ~300 lines). Split only along genuine sub-responsibilities without breaking encapsulation.

## Localization Requirement

- **Never hardcode user-facing strings** in `.swift` files. Always use `L10n.tr(...)` or `L10n.format(...)`.
- Every new key must be added to all 8 bundled `.lproj/Localizable.strings` files (`en`, `tr`, `de`, `es`, `fr`, `ja`, `zh-Hans`, `pt-BR`) with matching `%@` / `%d` format specifiers.
- Use `L10n.currentLocale` for date/time formatting rather than hardcoding a locale.

## Required Verification Before Every PR

```bash
./scripts/check-privacy.sh
swift test
./build.sh
```
