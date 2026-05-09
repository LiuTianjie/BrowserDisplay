#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
DERIVED_DATA_PATH="$PROJECT_ROOT/DerivedData"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug/BrowserDisplay.app"

cd "$PROJECT_ROOT"

echo "正在构建 Mac 端应用..."
xcodebuild \
  -workspace BrowserDisplay.xcworkspace \
  -scheme BrowserDisplay \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -quiet \
  build

echo "正在退出旧实例..."
for pid in $(/usr/bin/pgrep -f '/BrowserDisplay.app/Contents/MacOS/BrowserDisplay' || true); do
  parent_pid=$(/bin/ps -o ppid= -p "$pid" | /usr/bin/tr -d ' ')
  /bin/kill "$pid" >/dev/null 2>&1 || true

  if [[ -n "$parent_pid" ]]; then
    parent_command=$(/bin/ps -o command= -p "$parent_pid" || true)
    if [[ "$parent_command" == *"/debugserver"* ]]; then
      /bin/kill "$parent_pid" >/dev/null 2>&1 || true
    fi
  fi
done
/bin/sleep 0.5

echo "正在从固定路径启动：$APP_PATH"
/usr/bin/open -n "$APP_PATH"
