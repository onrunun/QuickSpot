# QuickSpot

**A fast, 100% local macOS launcher with instant fuzzy search, on-device Apple Vision OCR for images & PDFs, path navigation, quick actions, and live previews.**

[English](README.md) · [Türkçe](README.tr.md)

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple)](https://www.apple.com/macos/)
[![Swift 6](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

---

## Highlights

- **Instant Launch & Fuzzy Search** — Zero-polling in-memory application index with frecency learning, camelCase acronym matching (`vsc` → Visual Studio Code), and diacritic/multilingual folding.
- **On-Device Image & PDF OCR Search** — Indexes text inside screenshots, photos, and scanned PDFs using Apple Vision OCR + SQLite FTS5. Battery-, thermal-, and Low Power Mode-aware background indexing.
- **Progressive Spotlight File Search & Path Navigation** — Instant recent-file cache, progressive Spotlight search, and interactive filesystem browsing (`~/`, `/`) with `Tab` folder drill-down.
- **Built-In Quick Actions & System Settings** — Math & percentage calculator (`20% of 450`, `1500 + 18%`), color converter (`#3B82F6`, `rgb(59,130,246)`), unit & Unix timestamp converter (`120 km to mi`), Terminal runner (`> git status`), URL opener, 27 macOS System Settings deep links, and macOS system commands with two-step safety confirmation for destructive actions.
- **Privacy-First Clipboard History (`cb:` / `⇧⌘V`)** — Local searchable clipboard history that automatically ignores password managers (Apple Passwords, 1Password, Bitwarden, KeePassXC, LastPass, Dashlane) and concealed/transient pasteboard types, stored owner-only (`0600`).
- **Context Action Palette (`⌘K`)** — Secondary actions for any item: *Open With*, *Open Folder in Terminal*, *Reveal in Finder*, *Quick Look*, *Copy Path*, *Copy OCR Text*, and confirmed *Move to Trash*.
- **Split-Pane Live Preview** — Instant thumbnails, syntax/text snippets (automatically redacting sensitive files like `.env`, `.pem`, `.key`), OCR text copy, Finder drag-out, and Quick Look (`Space` / `⌘Y`).
- **Zero Dependencies & Native Performance** — Built purely with Swift, AppKit, SwiftUI, Vision, PDFKit, and SQLite3. No Electron, no external packages.

---

## 100% Local & Privacy-First

QuickSpot is designed to keep your data strictly on your Mac:

- **No telemetry, analytics, or crash trackers.**
- **No cloud APIs or external servers.** Vision OCR, PDF parsing, SQLite FTS5 indexing, calculator evaluation, and Spotlight queries all run completely on-device.
- **No automatic network requests.** The only network action QuickSpot ever triggers is opening a URL or web search in your default browser when you explicitly press Enter.
- **Sensitive file & password manager protection.** Files such as `.env`, `.env.*`, `.pem`, `.key`, and SSH private keys are excluded from inline preview rendering, and clipboard history automatically ignores password managers and `ConcealedType` / `TransientType` entries.
- **Local storage only.** The OCR index (`image-ocr.sqlite`) and optional clipboard history (`clipboard-history.json`, `0600` permissions) live strictly in `~/Library/Application Support/QuickSpot/`, and preferences live in standard macOS `UserDefaults`.

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
| `safari`, `vsc`, `qs` | Fuzzy search apps, recent files, Spotlight, and OCR |
| `img: receipt` | Search only images (filename + Vision OCR text) |
| `pdf: contract` | Search only PDFs (filename + embedded/OCR text) |
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
| `⌘Space` or `⌥Space` | Toggle QuickSpot (configurable in Settings or menu bar) |
| `↑` / `↓` | Navigate results |
| `⏎` | Open / run selected item (destructive commands require `⏎` twice) |
| `⌘1` – `⌘9` | Jump directly to result 1–9 |
| `⇥` (Tab) | Drill into selected folder / path completion |
| `⌘K` | Open secondary Action Palette (*Open With*, Terminal, Trash, etc.) |
| `⇧⌘V` | Jump directly to Clipboard History (`cb:`) |
| `⌘⏎` | Reveal selected file in Finder |
| `Space` / `⌘Y` | Toggle macOS Quick Look |
| `⌘C` / `⌥⌘C` | Copy item/result or copy full file path |
| `⌘⌫` | Clear search query |
| `⎋` | Close Quick Look → cancel confirmation → clear query → hide panel |
| `⌘,` | Open Settings & Indexing |

---

## Build from Source

### Requirements
- macOS 14.0 (Sonoma) or later
- Xcode Command Line Tools or Xcode 16+ (Swift 6.0)

### Build & Install `.app`

```bash
git clone https://github.com/<your-username>/QuickSpot.git
cd QuickSpot
./build.sh
cp -R build.noindex/QuickSpot.app /Applications/
open /Applications/QuickSpot.app
```

> **Note on code signing:** By default, `./build.sh` ad-hoc signs the app (`-`). If you have a local signing identity (e.g. a self-signed certificate or Apple Development certificate) and want macOS permissions to persist across rebuilds, create an ignored `.sign-id` file containing your certificate name before running `./build.sh`.

### Run Tests

```bash
swift test
```

---

## macOS Permissions

QuickSpot only requests macOS permissions when needed:

- **Folder access (Desktop, Downloads, Documents, Pictures)** — Needed for recent files and OCR indexing of folders you select in Settings.
- **Automation / Accessibility (Optional)** — Only requested if you trigger macOS system commands (such as *Lock Screen*, *Toggle Dark Mode*, *Empty Trash*, or *Run in Terminal*).

---

## License

Released under the [MIT License](LICENSE).
