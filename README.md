# QuickSpot

**A fast, 100% local macOS launcher with instant fuzzy search, on-device Apple Vision OCR, optional local EmbeddingGemma 2 semantic visual & document search, clipboard history, path navigation, quick actions, and live previews.**

[English](README.md) · [Türkçe](README.tr.md)

[![CI](https://github.com/onrunun/QuickSpot/actions/workflows/ci.yml/badge.svg)](https://github.com/onrunun/QuickSpot/actions/workflows/ci.yml)
[![macOS 14+ Apple Silicon](https://img.shields.io/badge/macOS-14%2B%20Apple%20Silicon-000000?logo=apple)](https://www.apple.com/macos/)
[![Swift 6](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

---

## Highlights

- **Instant Launch & Fuzzy Search** — Zero-polling in-memory application index with frecency learning, camelCase acronym matching (`vsc` → Visual Studio Code), and multilingual diacritic folding.
- **On-Device Image & PDF OCR Search** — Indexes text inside screenshots, photos, and scanned PDFs using Apple Vision OCR + SQLite FTS5, plus smart QR code & IBAN detection. Battery-, thermal-, and Low Power Mode-aware background indexing.
- **Optional Local Semantic Search & Near-Duplicate Finder** — Powered by on-device Apple Silicon Metal inference (`GemmaEmbed` / EmbeddingGemma 2 GGUF weights supplied by the user) to search photos and documents by meaning, find visually similar images, and review near-duplicate photos cleanly.
- **Spotlight-Safe Setup & Custom Hotkey Recorder** — Guided first-launch setup automatically checks macOS Spotlight shortcuts so QuickSpot starts conflict-free (`⌥Space` alongside Spotlight, `⌘Space` replacing Spotlight, or any custom shortcut with live conflict detection).
- **Progressive Spotlight File Search & Path Navigation** — Instant recent-file cache, progressive Spotlight search, and interactive filesystem browsing (`~/`, `/`) with `Tab` folder drill-down.
- **Built-In Quick Actions & System Settings** — Math & percentage calculator (`20% of 450`, `1500 + 18%`), color converter (`#3B82F6`, `rgb(59,130,246)`), unit & Unix timestamp converter (`120 km to mi`), Terminal runner (`> git status`), URL opener, 27 macOS System Settings deep links, and macOS system commands with two-step safety confirmation for destructive actions.
- **Privacy-First Clipboard History (`cb:` / `⇧⌘V`)** — Local searchable clipboard history that automatically ignores password managers (Apple Passwords, 1Password, Bitwarden, KeePassXC, LastPass, Dashlane) and concealed/transient pasteboard types, stored owner-only (`0600`).
- **Context Action Palette (`⌘K`)** — Secondary actions for any item: *Open With*, *Open Folder in Terminal*, *Find Similar*, *Reveal in Finder*, *Quick Look*, *Copy Path*, *Copy OCR Text*, and confirmed *Move to Trash*.
- **Split-Pane Live Preview** — Instant thumbnails, syntax/text snippets (automatically redacting sensitive files like `.env`, `.pem`, `.key`), QR/IBAN actions, Finder drag-out, and Quick Look (`Space` / `⌘Y`).
- **Native macOS Performance** — Built with Swift, AppKit, SwiftUI, Vision, PDFKit, Metal, Accelerate, and SQLite3, with a single open-source SwiftPM dependency ([GemmaEmbed](https://github.com/maralski/gemma-embed-swift), Apache-2.0) for optional on-device semantic embeddings.

---

## 100% Local & Privacy-First

QuickSpot is designed to keep your data strictly on your Mac:

- **No telemetry, analytics, or crash trackers.**
- **No cloud APIs or external servers.** Vision OCR, PDF parsing, SQLite FTS5 indexing, optional EmbeddingGemma 2 Metal inference, calculator evaluation, and Spotlight queries all run completely on-device.
- **No automatic network requests.** QuickSpot never downloads models or contacts remote servers in the background. The only network action ever triggered is opening a URL (such as a web search or the optional model download page) in your default browser when you explicitly click or press Enter.
- **Sensitive file & password manager protection.** Files such as `.env`, `.env.*`, `.pem`, `.key`, and SSH private keys are excluded from inline preview rendering, and clipboard history automatically ignores password managers and `ConcealedType` / `TransientType` entries.
- **Local storage only.** Local indexes (`image-ocr.sqlite`, `image-embeddings.sqlite`, `document-embeddings.sqlite`) and optional clipboard history (`clipboard-history.json`, `0600` permissions) live strictly in `~/Library/Application Support/QuickSpot/`, and preferences live in standard macOS `UserDefaults`.

---

## Supported Languages

QuickSpot automatically follows your macOS system language and includes a live **Language Picker** in Settings (`⌘,`) supporting 8 languages:

| Language | Code | UI | System Commands | Vision OCR |
|---|---|:---:|:---:|:---:|
| English (Default) | `en` | ✅ | ✅ | ✅ |
| Türkçe | `tr` | ✅ | ✅ | ✅ |
| Deutsch | `de` | ✅ | ✅ | ✅ |
| Español | `es` | ✅ | ✅ | ✅ |
| Français | `fr` | ✅ | ✅ | ✅ |
| 日本語 | `ja` | ✅ | ✅ | ✅ |
| 简体中文 | `zh-Hans` | ✅ | ✅ | ✅ |
| Português (Brasil) | `pt-BR` | ✅ | ✅ | ✅ |

Want to add another language? See [CONTRIBUTING.md](CONTRIBUTING.md).

---

## Search Prefixes & Quick Actions

| Input | Behavior |
|---|---|
| `safari`, `vsc`, `qs` | Fuzzy search apps, recent files, Spotlight, OCR, and semantic matches |
| `img: receipt` | Search only images (filename + Vision OCR + semantic visual search) |
| `pdf: contract` | Search only PDFs (filename + embedded/OCR + semantic text search) |
| `f: budget` | Search only files |
| `dir: projects` | Search only folders |
| `in: invoice` | Search inside file contents & OCR text |
| `app: notes` | Search only installed applications |
| `cb: link` / `clip:` | Search local clipboard history (`⇧⌘V` shortcut) |
| `~/Desktop/` | Browse filesystem directly (`Tab` enters folders) |
| `> git status` | Run a command in macOS Terminal |
| `1500 + 18%`, `20% of 450` | Instant calculator (`Enter` copies result) |
| `120 km to mi`, `0 c to f` | Unit conversion (length, mass, data, temperature) |
| `#3B82F6`, `1731960000` | HEX/RGB/HSL color & Unix timestamp converter |
| `dark mode`, `lock`, `ip`, `mute`, `screenshot`, `caffeinate` | macOS system commands (multilingual aliases supported) |

---

## Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| `⌥Space`, `⌘Space`, `⌥⌘Space`, or custom | Toggle QuickSpot (first-launch setup lets you run alongside Spotlight with zero conflict or replace `⌘Space` with live conflict detection) |
| `↑` / `↓` | Navigate results |
| `⏎` | Open / run selected item (destructive commands require `⏎` twice) |
| `⌘1` – `⌘9` | Jump directly to result 1–9 |
| `⇥` (Tab) | Drill into selected folder / path completion |
| `⌘K` | Open secondary Action Palette (*Open With*, *Find Similar*, Terminal, Trash, etc.) |
| `⇧⌘V` | Jump directly to Clipboard History (`cb:`) |
| `⌘⏎` | Reveal selected file in Finder |
| `Space` / `⌘Y` | Toggle macOS Quick Look |
| `⌘C` / `⌥⌘C` | Copy item/result or copy full file path |
| `⌘⌫` | Clear search query |
| `⎋` | Close Quick Look → cancel confirmation → clear query → hide panel |
| `⌘,` | Open Settings & Indexing |

---

## Installation

Requires an Apple Silicon Mac (`arm64`) running **macOS 14.0 (Sonoma)** or later.

### Option 1: Homebrew Cask

```bash
brew tap onrunun/tap
brew install --cask quickspot
```

> On Homebrew 7+, if prompted to trust third-party taps, run `brew trust onrunun/tap` first.

### Option 2: Direct Download (`.dmg`)

Download the latest Apple Silicon `.dmg` and verify checksums from [GitHub Releases](https://github.com/onrunun/QuickSpot/releases/latest).

### Option 3: Build from Source

Requires Xcode Command Line Tools or Xcode 16+ (Swift 6.0).

```bash
git clone https://github.com/onrunun/QuickSpot.git
cd QuickSpot
./build.sh
cp -R build.noindex/QuickSpot.app /Applications/
open /Applications/QuickSpot.app
```

> **Note on macOS Gatekeeper (pre-built downloads):** Ad-hoc signed community releases are not notarized by Apple. If macOS displays a Gatekeeper warning on first launch, either build directly from source above, or open `QuickSpot.app` once via **System Settings → Privacy & Security → Open Anyway** (or run `xattr -dr com.apple.quarantine /Applications/QuickSpot.app`).

> **Note on local code signing:** By default, `./build.sh` ad-hoc signs the app (`-`). If you have a local signing identity (e.g. a self-signed certificate or Apple Development certificate) and want macOS permissions to persist across rebuilds, create an ignored `.sign-id` file containing your certificate name before running `./build.sh`.

### Run Tests

```bash
swift test
```

---

## macOS Permissions

QuickSpot only requests macOS permissions when needed:

- **Folder access (Desktop, Downloads, Documents, Pictures)** — Needed for recent files and OCR/semantic indexing of folders you select in Settings.
- **Automation / Accessibility (Optional)** — Only requested if you trigger macOS system commands (such as *Lock Screen*, *Toggle Dark Mode*, *Empty Trash*, or *Run in Terminal*).

---

## Community, Security & License

- [Changelog](CHANGELOG.md)
- [Contributing & Translations](CONTRIBUTING.md)
- [Security Policy](SECURITY.md)
- [Code of Conduct](CODE_OF_CONDUCT.md)
- [Third-Party Notices](THIRD_PARTY_NOTICES.md)
- Released under the [MIT License](LICENSE).
