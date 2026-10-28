#!/bin/sh
# 创建 AI 用户（在设备/客户机的 root shell 里执行）
set -e
PM=${PM:-pm}
NAME=${1:-AI}
echo "== 当前用户 =="
$PM list users || true
echo "== 创建用户 $NAME =="
$PM create-user "$NAME"
echo "== 完成：请在 Agent 设置里填写 AI 用户 id（pm list users 查看）=="
