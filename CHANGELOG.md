# Changelog

All notable changes to QuickSpot will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-11-26

### Added
- Instant fuzzy application, recent file, and progressive Spotlight search with frecency learning and diversity-aware ranking.
- On-device Apple Vision OCR indexing for images and PDFs backed by SQLite FTS5, smart QR code & IBAN extraction, FSEvents incremental watching, and battery/thermal/Low Power Mode awareness.
- Optional on-device semantic visual & document search (EmbeddingGemma 2 via Apple Silicon Metal / `GemmaEmbed`), visual similarity search (*Find Similar*), and a Near-Duplicate Photo Finder window.
- Guided first-launch onboarding, live macOS Spotlight shortcut conflict detection, and a custom global hotkey recorder.
- Interactive filesystem path navigation (`~/`, `/`) with `Tab` folder drill-down.
- Built-in quick actions: JavaScriptCore math & percentage calculator, HEX/RGB/HSL color & Unix timestamp converter, unit converter, Terminal runner (`>`), URL opener, 27 macOS System Settings deep links, and two-step confirmed system commands.
- Privacy-first local clipboard history (`cb:` / `⇧⌘V`) filtering out password managers and concealed/transient entries with `0600` file permissions.
- Context Action Palette (`⌘K`) with *Open With*, *Find Similar*, *Open in Terminal*, *Quick Look*, *Copy Path*, *Copy OCR Text*, and confirmed *Move to Trash*.
- Split-pane live preview with thumbnails, Quick Look, Finder drag-out, and sensitive-file redaction (`.env`, `.pem`, `.key`).
- Full localization across 8 languages (`en`, `tr`, `de`, `es`, `fr`, `ja`, `zh-Hans`, `pt-BR`) with live Language Picker in Settings and dynamic multilingual Vision OCR.
- Automated CI, privacy/secret gate, Apple Silicon (`arm64`) Release packaging (`DMG`, `ZIP`, `SHA256SUMS.txt`), optional Homebrew Cask tap updates, and third-party license notices.
