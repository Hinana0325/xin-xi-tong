#!/bin/sh
# DEPRECATED（已废弃）：双用户应用同步不再采用，单用户 user 0 唯一用户。
# 本文件仅保留供查阅，不得执行。见 custom/DEPRECATED.md 与 SPEC.md 末节。
# 双向同步 user 0 与 AI 用户的应用清单（在设备/客户机的 root shell 里执行）
set -e
AI_USER=${1:-10}
echo "== 机主(user 0) -> AI(user $AI_USER) =="
for p in $(${PM:-pm} list packages --user 0 | sed 's/^package://'); do
  ${PM:-pm} install-existing --user "$AI_USER" "$p" >/dev/null 2>&1 || true
done
echo "== AI(user $AI_USER) -> 机主(user 0) =="
for p in $(${PM:-pm} list packages --user "$AI_USER" | sed 's/^package://'); do
  ${PM:-pm} install-existing --user 0 "$p" >/dev/null 2>&1 || true
done
echo "完成：user 0 与 user $AI_USER 应用清单已对齐"
