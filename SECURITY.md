# Security Policy

## Local-Only Privacy & Threat Model

QuickSpot runs 100% locally on macOS with zero external dependencies, zero telemetry, and no cloud APIs:

- All OCR indexing (Apple Vision + PDFKit + SQLite FTS5), Spotlight queries, calculator evaluations, and clipboard history happen strictly on-device.
- Clipboard history automatically excludes password managers (`Apple Passwords`, `1Password`, `Bitwarden`, `KeePassXC`, `LastPass`, `Dashlane`, `Keychain Access`) and `ConcealedType` / `TransientType` pasteboard entries, and persists local history with owner-only `0600` permissions.
- Sensitive files (`.env`, `.env.*`, `.pem`, `.key`, `.p12`, SSH keys) are excluded from inline text previews.
- Destructive system/file actions require explicit two-step keyboard confirmation (`⏎` twice).

## Supported Versions

| Version | Supported |
| --- | :---: |
| `1.x` (latest release on `main`) | ✅ |

## Reporting a Vulnerability

Please **do not** report security vulnerabilities through public GitHub issues.

Instead, use **GitHub Private Vulnerability Reporting** under the repository's **Security → Advisories → Report a vulnerability** tab.

Please include:
- A clear description of the vulnerability and potential impact
- Steps to reproduce or a minimal proof of concept
- macOS version and QuickSpot version

We will acknowledge receipt promptly and work on a fix before public disclosure.
