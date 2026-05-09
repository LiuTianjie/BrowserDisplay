#!/bin/zsh
set -euo pipefail

tccutil reset ScreenCapture com.turning4th.browserdisplay.app

echo "已重置 BrowserDisplay 的屏幕录制权限。请重新运行 tools/run-browserdisplay.command，然后在系统设置中允许屏幕录制。"
