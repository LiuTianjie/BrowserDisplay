# Release workflow

This project builds, signs, notarizes, and uploads macOS releases from your local Mac.

## One-time setup

Install GitHub CLI and sign in:

```bash
brew install gh
gh auth login
```

Install your `Developer ID Application` certificate in Keychain Access.

For notarization, either export these each time:

```bash
export APPLE_ID="you@example.com"
export APPLE_TEAM_ID="ABCDE12345"
export APPLE_APP_SPECIFIC_PASSWORD="xxxx-xxxx-xxxx-xxxx"
```

Or store credentials once in Keychain:

```bash
xcrun notarytool store-credentials BrowserDisplayNotary \
  --apple-id "you@example.com" \
  --team-id "ABCDE12345" \
  --password "xxxx-xxxx-xxxx-xxxx"
```

Then use:

```bash
export NOTARYTOOL_PROFILE=BrowserDisplayNotary
```

## Unsigned local package

```bash
tools/package-macos.sh
```

This creates `dist/BrowserDisplay-macOS.dmg`, `dist/BrowserDisplay-macOS.zip`, a dSYM zip, and `dist/SHA256SUMS.txt`.

## Signed and notarized local package

```bash
export REQUIRE_SIGNING=YES
export NOTARIZE=YES
export CREATE_APP_ZIP=NO
export NOTARYTOOL_PROFILE=BrowserDisplayNotary
tools/package-macos.sh
```

The script auto-detects the first `Developer ID Application` identity. To choose one explicitly:

```bash
export SIGNING_IDENTITY="Developer ID Application: Your Name (ABCDE12345)"
```

## GitHub release

```bash
tools/release-github.sh v1.0.0
```

The release script requires a clean working tree by default, creates the tag if needed, pushes it to `origin`, builds a signed and notarized DMG, and uploads the DMG, dSYM zip, and checksums to the GitHub Release.

For a one-off local test against uncommitted code, use `ALLOW_DIRTY=YES`, but do not use that for real releases.
