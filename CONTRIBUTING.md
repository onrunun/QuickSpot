# Contributing to QuickSpot

Thank you for your interest in contributing to QuickSpot!

## Development Setup

Requirements:
- macOS 14.0+
- Swift 6.0 (Xcode 16+ or Xcode Command Line Tools)

Run the test suite:

```bash
swift test
```

Build the standalone `.app` bundle:

```bash
./build.sh
```

Run the privacy, plist, and localization syntax gate (also executed in CI):

```bash
./scripts/check-privacy.sh
```

Package a release (`DMG`, `ZIP`, and `SHA256SUMS.txt` for Apple Silicon):

```bash
./scripts/package-release.sh --version 1.0.0
```

Maintainers can apply GitHub branch/tag rulesets and security settings after creating the remote repository:

```bash
./scripts/setup-github-rules.sh --repo onrunun/QuickSpot
```

Please review our [Code of Conduct](CODE_OF_CONDUCT.md) and [Security Policy](SECURITY.md) before contributing.

## Architecture

QuickSpot follows a clean vertical-slice layout:

- `Sources/QuickSpotCore/` — Core slices (`Localization`, `Contracts`, `Hotkey`, `AppSearch`, `FileSearch`, `ImageOCR`, `SemanticSearch`, `Indexing`, `Clipboard`, `QuickActions`)
- `Sources/QuickSpotApp/` — macOS AppKit/SwiftUI UI (`Panel`, `Preview`, `Settings`, `Onboarding`, `Duplicates`, `Hotkey`, `StatusBarMenu`, `BrandIcon`)
- `Tests/QuickSpotCoreTests/` — Unit tests covering fuzzy matching, ranking, OCR & semantic indexing, hotkey conflict detection, privacy rules, and localization parity

## Adding or Improving a Translation

QuickSpot stores all strings in standard Apple `.lproj/Localizable.strings` files under `Sources/QuickSpotCore/Resources/`.

To add a new language (for example, Italian `it`):

1. Copy `Sources/QuickSpotCore/Resources/en.lproj/Localizable.strings` to `Sources/QuickSpotCore/Resources/it.lproj/Localizable.strings` and translate all values while keeping `%@` / `%d` placeholders intact.
2. Add the language case to `AppLanguage` in `Sources/QuickSpotCore/Localization/L10n.swift` (including `concreteLanguages`, `displayName`, `visionLanguageCode`, `localeIdentifier`, and `match(identifier:)`).
3. Add the language code to `CFBundleLocalizations` in `Resources/Info.plist`.
4. Optionally add localized command aliases in `Sources/QuickSpotCore/QuickActions/SystemCommandAction.swift`.
5. Run `swift test` — `LocalizationAndPrivacyTests` automatically verifies that every language has 100% key coverage and matching format specifiers.

## Privacy & Security Guidelines

- QuickSpot must remain 100% offline/local by default — do not introduce telemetry, analytics, or unrequested network calls.
- Never log user file contents or personal file paths with `.public` OSLog privacy.
- Keep sensitive files (`.env`, private keys, certificates) excluded from inline previews.
