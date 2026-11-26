# Changelog

All notable changes to QuickSpot will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Instant fuzzy application, recent file, and progressive Spotlight search with frecency learning and diversity-aware ranking.
- On-device Apple Vision OCR indexing for images and PDFs backed by SQLite FTS5, FSEvents incremental watching, and battery/thermal/Low Power Mode awareness.
- Interactive filesystem path navigation (`~/`, `/`) with `Tab` folder drill-down.
- Built-in quick actions: JavaScriptCore math & percentage calculator, HEX/RGB/HSL color & Unix timestamp converter, unit converter, Terminal runner (`>`), URL opener, 27 macOS System Settings deep links, and two-step confirmed system commands.
- Privacy-first local clipboard history (`cb:` / `⇧⌘V`) filtering out password managers and concealed/transient entries with `0600` file permissions.
- Raycast-style context Action Palette (`⌘K`) with *Open With*, *Open in Terminal*, *Quick Look*, *Copy Path*, *Copy OCR Text*, and confirmed *Move to Trash*.
- Split-pane live preview with thumbnails, Quick Look, Finder drag-out, and sensitive-file redaction (`.env`, `.pem`, `.key`).
- Full localization across 8 languages (`en`, `tr`, `de`, `es`, `fr`, `ja`, `zh-Hans`, `pt-BR`) with live Language Picker in Settings and dynamic multilingual Vision OCR.
- Automated CI, privacy/secret gate, and universal macOS Release packaging (`DMG`, `ZIP`, `SHA256SUMS.txt`).
