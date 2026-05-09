#!/bin/zsh
set -euo pipefail

tccutil reset ScreenCapture com.turning4th.browserdisplay.app
tccutil reset ScreenCapture com.turning4th.browserdisplay.app.dev

echo "已重置 BrowserDisplay 正式版和开发版的屏幕录制权限。请重新运行应用，然后在系统设置中允许屏幕录制。"
