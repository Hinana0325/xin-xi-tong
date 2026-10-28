#!/bin/sh
# 把 Agent 安装到机主与 AI 用户（宿主机 adb，用于原型验证）
set -e
APK=${1:-../agent/app/build/outputs/apk/debug/app-debug.apk}
AI_USER=${2:-10}
PKG=dev.pocketvm.aiagent
adb install -r -g "$APK"
adb shell pm install-existing --user "$AI_USER" "$PKG"
echo "已安装到 user 0 与 user $AI_USER"
