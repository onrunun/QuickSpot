#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

FAILURES=0

fail() {
  echo "FAIL: $1" >&2
  FAILURES=$((FAILURES + 1))
}

echo "Running QuickSpot privacy & hygiene checks..."

# 1. Verify no forbidden local/secret files are tracked in git
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  FORBIDDEN="$(git ls-files | grep -E '(^|/)(\.DS_Store|\.env(\..+)?|\.sign-id|.*\.(p12|pem|key|cer|mobileprovision))$' || true)"
  if [[ -n "$FORBIDDEN" ]]; then
    printf "%s\n" "$FORBIDDEN" >&2
    fail "Forbidden files tracked in git."
  fi
fi

# 2. Scan tracked source/docs/config for secrets, private keys, or personal paths
SCAN_TARGETS=()
for path in Sources Resources .github scripts Package.swift build.sh README.md README.tr.md CONTRIBUTING.md SECURITY.md CHANGELOG.md CODE_OF_CONDUCT.md AGENTS.md LICENSE; do
  if [[ -e "$path" ]]; then
    SCAN_TARGETS+=("$path")
  fi
done

SECRET_PATTERN='(sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----)'
SECRET_HITS="$(grep -rnE "$SECRET_PATTERN" "${SCAN_TARGETS[@]}" --exclude="check-privacy.sh" || true)"
if [[ -n "$SECRET_HITS" ]]; then
  printf "%s\n" "$SECRET_HITS" >&2
  fail "Potential hardcoded secret or private key detected."
fi

# 3. Ensure no hardcoded macOS /Users/<username> home paths appear outside Tests/
USERPATH_HITS="$(grep -rnE '/Users/[A-Za-z0-9._-]+' "${SCAN_TARGETS[@]}" --exclude="check-privacy.sh" || true)"
if [[ -n "$USERPATH_HITS" ]]; then
  printf "%s\n" "$USERPATH_HITS" >&2
  fail "Hardcoded /Users/<name> path detected outside Tests/."
fi

# 4. Ensure no personal email addresses appear in production source or Resources
EMAIL_HITS="$(grep -rnE '[A-Za-z0-9._%+-]+@(gmail|hotmail|outlook|yahoo|icloud|proton|protonmail)\.[A-Za-z]{2,}' Sources Resources build.sh Package.swift || true)"
if [[ -n "$EMAIL_HITS" ]]; then
  printf "%s\n" "$EMAIL_HITS" >&2
  fail "Personal email address detected in source/resources."
fi

# 5. Validate Info.plist XML & Localizable.strings syntax (when plutil is available on macOS)
if command -v plutil >/dev/null 2>&1; then
  if ! plutil -lint Resources/Info.plist >/dev/null; then
    fail "Resources/Info.plist failed plutil lint."
  fi
  for f in Sources/QuickSpotCore/Resources/*.lproj/Localizable.strings; do
    if ! plutil -lint "$f" >/dev/null; then
      fail "$f failed plutil lint."
    fi
  done
fi

# 6. Ensure no OSLog interpolation in Sources logs filenames/paths with privacy: .public
LOG_HITS="$(grep -rnE '(lastPathComponent|\.path)[^)]*privacy:[[:space:]]*\.public' Sources/ || true)"
if [[ -n "$LOG_HITS" ]]; then
  printf "%s\n" "$LOG_HITS" >&2
  fail "OSLog leaks user path/filename with privacy: .public."
fi

if [[ "$FAILURES" -gt 0 ]]; then
  echo "Privacy & hygiene check failed ($FAILURES issue(s))." >&2
  exit 1
fi

echo "PASS: Privacy, secret, plist, and localization syntax checks clean."
