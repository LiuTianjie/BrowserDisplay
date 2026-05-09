#!/bin/zsh
set -euo pipefail

tccutil reset ScreenCapture com.turning4th.mirrordisplay.machost

echo "已重置镜像显示的屏幕录制权限。请重新运行 tools/run-mac-host.command，然后在系统设置中允许屏幕录制。"
