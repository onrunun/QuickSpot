# Releasing QuickSpot

QuickSpot's release pipeline (`.github/workflows/release.yml`) builds Apple Silicon (`arm64`) macOS releases, packages `.dmg` + `.zip` + `SHA256SUMS.txt`, and optionally signs, notarizes, and updates a Homebrew Cask Tap automatically.

---

## 1. Cutting a New Release

1. Update `CHANGELOG.md` and commit on `main`.
2. Push a Semantic Versioning tag:

```bash
git tag v1.0.0
git push origin v1.0.0
```

You can also trigger a release manually from **GitHub → Actions → Release → Run workflow**.

The workflow automatically:
- Runs `./scripts/check-privacy.sh` and `swift test`
- Builds a signed `QuickSpot.app` (`arm64` Apple Silicon) with all 8 bundled `.lproj` localizations and `THIRD_PARTY_NOTICES.md`
- Produces `QuickSpot-<version>-macos-arm64.dmg`, `.zip`, and `SHA256SUMS.txt`
- Publishes a GitHub Release with auto-categorized release notes (`.github/release.yml`)

---

## 2. Enabling Automatic Homebrew Cask Updates (Optional)

Once you create a public tap repository named `onrunun/homebrew-tap`:

1. Create a fine-grained Personal Access Token scoped **only** to `onrunun/homebrew-tap` with **Contents: Read and write** permission.
2. In the `QuickSpot` repository's **Settings → Secrets and variables → Actions**:
   - Add **Variable**: `HOMEBREW_TAP_REPO` = `onrunun/homebrew-tap`
   - Add **Secret**: `HOMEBREW_TAP_TOKEN` = `<your fine-grained PAT>`
3. On every stable `v*.*.*` release (pre-releases are skipped automatically), `release.yml` renders `Casks/quickspot.rb` via `scripts/render-homebrew-cask.sh` with the exact `.dmg` SHA-256 and pushes it to your tap.

Users can then install and update via:

```bash
brew tap onrunun/tap
brew install --cask quickspot
```

---

## 3. Enabling Apple Developer ID Signing & Notarization (Optional)

Without Apple signing secrets, releases use ad-hoc signing (`-`). When you have an Apple Developer Program membership, add these **Repository Secrets** under **Settings → Secrets and variables → Actions**:

| Secret | Value |
|---|---|
| `APPLE_CERT_P12_BASE64` | Base64-encoded Developer ID Application `.p12` (`base64 -i DeveloperID.p12 \| pbcopy`) |
| `APPLE_CERT_PASSWORD` | Password protecting the `.p12` export |
| `APPLE_SIGN_IDENTITY` | Exact certificate common name (e.g. `Developer ID Application: Name (TEAMID)`) |
| `APPLE_NOTARY_KEY_BASE64` | Base64-encoded App Store Connect API `.p8` key (`base64 -i AuthKey_XXXX.p8 \| pbcopy`) |
| `APPLE_NOTARY_KEY_ID` | App Store Connect API Key ID |
| `APPLE_NOTARY_ISSUER_ID` | App Store Connect Issuer UUID |

When these secrets are present, `release.yml` automatically imports the certificate into a temporary CI keychain, signs with hardened runtime, submits the `.dmg` to Apple's `notarytool`, staples the notarization ticket, and regenerates `SHA256SUMS.txt`.
