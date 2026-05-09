#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}

WORKSPACE=${WORKSPACE:-BrowserDisplay.xcworkspace}
SCHEME=${SCHEME:-BrowserDisplay}
CONFIGURATION=${CONFIGURATION:-Release}
APP_NAME=${APP_NAME:-BrowserDisplay}
DERIVED_DATA_PATH=${DERIVED_DATA_PATH:-"$PROJECT_ROOT/DerivedData/Package"}
DIST_DIR=${DIST_DIR:-"$PROJECT_ROOT/dist"}
ZIP_BASENAME=${ZIP_BASENAME:-"$APP_NAME-macOS"}
DMG_BASENAME=${DMG_BASENAME:-"$ZIP_BASENAME"}
DMG_VOLUME_NAME=${DMG_VOLUME_NAME:-"$APP_NAME"}
SIGNING_ALLOWED=${CODE_SIGNING_ALLOWED:-NO}
SIGNING_IDENTITY=${SIGNING_IDENTITY:-}
ENTITLEMENTS_PATH=${ENTITLEMENTS_PATH:-"$PROJECT_ROOT/BrowserDisplay/BrowserDisplay.entitlements"}
REQUIRE_SIGNING=${REQUIRE_SIGNING:-NO}
CREATE_APP_ZIP=${CREATE_APP_ZIP:-YES}
CREATE_DMG=${CREATE_DMG:-YES}
NOTARIZE=${NOTARIZE:-NO}
NOTARYTOOL_PROFILE=${NOTARYTOOL_PROFILE:-}

APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"
DSYM_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app.dSYM"
APP_ZIP="$DIST_DIR/$ZIP_BASENAME.zip"
DSYM_ZIP="$DIST_DIR/$ZIP_BASENAME.dSYM.zip"
DMG_PATH="$DIST_DIR/$DMG_BASENAME.dmg"
DMG_ROOT="$DIST_DIR/dmg-root"

require_env() {
  local name=$1
  if [[ -z "${(P)name:-}" ]]; then
    echo "Missing required environment variable: $name" >&2
    exit 1
  fi
}

find_developer_id_identity() {
  /usr/bin/security find-identity -v -p codesigning | \
    /usr/bin/awk -F '"' '/Developer ID Application/ { print $2; exit }'
}

codesign_runtime() {
  local path=$1
  echo "Signing $path"
  /usr/bin/codesign \
    --force \
    --timestamp \
    --options runtime \
    --sign "$SIGNING_IDENTITY" \
    "$path"
}

codesign_file() {
  local path=$1
  echo "Signing $path"
  /usr/bin/codesign \
    --force \
    --timestamp \
    --sign "$SIGNING_IDENTITY" \
    "$path"
}

sign_app() {
  if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY=$(find_developer_id_identity)
  fi

  if [[ -z "$SIGNING_IDENTITY" ]]; then
    if [[ "$REQUIRE_SIGNING" == "YES" ]]; then
      echo "No Developer ID Application signing identity was found." >&2
      exit 1
    fi
    echo "No signing identity provided; leaving app unsigned."
    return
  fi

  if [[ ! -f "$ENTITLEMENTS_PATH" ]]; then
    echo "Entitlements file was not found at: $ENTITLEMENTS_PATH" >&2
    exit 1
  fi

  echo "Using signing identity: $SIGNING_IDENTITY"

  if [[ -d "$APP_PATH/Contents/Frameworks" ]]; then
    while IFS= read -r binary; do
      codesign_runtime "$binary"
    done < <(/usr/bin/find "$APP_PATH/Contents/Frameworks" -type f \( -name "*.dylib" -o -perm -111 \) -print | /usr/bin/sort)

    while IFS= read -r framework; do
      codesign_runtime "$framework"
    done < <(/usr/bin/find "$APP_PATH/Contents/Frameworks" -depth -type d -name "*.framework" -print | /usr/bin/sort)
  fi

  echo "Signing $APP_PATH with entitlements..."
  /usr/bin/codesign \
    --force \
    --timestamp \
    --options runtime \
    --entitlements "$ENTITLEMENTS_PATH" \
    --sign "$SIGNING_IDENTITY" \
    "$APP_PATH"

  /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
}

create_dmg() {
  rm -rf "$DMG_ROOT"
  mkdir -p "$DMG_ROOT"

  /bin/cp -R "$APP_PATH" "$DMG_ROOT/"
  /bin/ln -s /Applications "$DMG_ROOT/Applications"

  echo "Packaging $DMG_PATH..."
  /usr/bin/hdiutil create \
    -volname "$DMG_VOLUME_NAME" \
    -srcfolder "$DMG_ROOT" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

  rm -rf "$DMG_ROOT"

  if [[ -n "$SIGNING_IDENTITY" ]]; then
    codesign_file "$DMG_PATH"
    /usr/bin/codesign --verify --verbose=2 "$DMG_PATH"
  fi
}

notarize_dmg() {
  if [[ "$NOTARIZE" != "YES" ]]; then
    return
  fi

  if [[ ! -f "$DMG_PATH" ]]; then
    echo "DMG was not found at: $DMG_PATH" >&2
    exit 1
  fi

  echo "Submitting $DMG_PATH for notarization..."
  if [[ -n "$NOTARYTOOL_PROFILE" ]]; then
    /usr/bin/xcrun notarytool submit "$DMG_PATH" \
      --keychain-profile "$NOTARYTOOL_PROFILE" \
      --wait
  else
    require_env APPLE_ID
    require_env APPLE_TEAM_ID
    require_env APPLE_APP_SPECIFIC_PASSWORD

    /usr/bin/xcrun notarytool submit "$DMG_PATH" \
      --apple-id "$APPLE_ID" \
      --team-id "$APPLE_TEAM_ID" \
      --password "$APPLE_APP_SPECIFIC_PASSWORD" \
      --wait
  fi

  echo "Stapling notarization ticket..."
  /usr/bin/xcrun stapler staple "$DMG_PATH"
  /usr/bin/xcrun stapler validate "$DMG_PATH"
  /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose "$DMG_PATH"
}

cd "$PROJECT_ROOT"

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

echo "Building $APP_NAME ($CONFIGURATION)..."
xcodebuild \
  -workspace "$WORKSPACE" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED="$SIGNING_ALLOWED" \
  build

if [[ ! -d "$APP_PATH" ]]; then
  echo "Expected app was not found at: $APP_PATH" >&2
  exit 1
fi

sign_app

if [[ "$CREATE_APP_ZIP" == "YES" ]]; then
  echo "Packaging $APP_ZIP..."
  /usr/bin/ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"
fi

if [[ -d "$DSYM_PATH" ]]; then
  echo "Packaging $DSYM_ZIP..."
  /usr/bin/ditto -c -k --keepParent "$DSYM_PATH" "$DSYM_ZIP"
fi

if [[ "$CREATE_DMG" == "YES" ]]; then
  create_dmg
  notarize_dmg
fi

(
  cd "$DIST_DIR"
  for artifact in ./*.zip(N) ./*.dmg(N); do
    /usr/bin/shasum -a 256 "$artifact"
  done > SHA256SUMS.txt
)

echo "Packaged artifacts:"
/bin/ls -lh "$DIST_DIR"
