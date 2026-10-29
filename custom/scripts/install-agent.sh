#!/bin/sh
# 把 Agent 安装到唯一用户 user 0（宿主机 adb，用于原型验证；单用户设计）
# 已废弃的双用户安装方式见 DEPRECATED.md：不再安装到 AI 用户。
set -e
APK=${1:-../agent/app/build/outputs/apk/debug/app-debug.apk}
PKG=dev.pocketvm.aiagent
adb install -r -g "$APK"
echo "已安装到 user 0（$PKG）"
