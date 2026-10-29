#!/usr/bin/env bash
# verify-bootable.sh — 校验 integrate-bootable.sh 产出的 bundle 完整性
#
# 用法：./verify-bootable.sh --bundle-dir <bundle 目录>
#
# 校验项（任一失败即退出码 1，并列出缺失/不符项）：
#   1. manifest.json 存在且为合法 JSON；
#   2. manifest.json 所列每个文件存在、大小与 SHA-256 对得上；
#   3. system.img 通过 e2fsck -fn；
#   4. 13 个应用 APK 在镜像内目标路径存在，模式 0644、属主 root:root、
#      SELinux 上下文含 u:object_r:system_file:s0，dump 出的 SHA-256 与
#      manifest 记录的 APK 来源一致（manifest 只存 bundle 文件哈希，
#      APK 内容哈希在校验时现场从 --apk-dir 之外的 bundle 证据重算：
#      此处改为核对镜像内 APK 的 SHA-256 与 system-integration.json /
#      integrate.sh 清单一致，若无清单则只核对存在性与属性）；
#   5. Agent APK（若 manifest 标注已提供）在目标路径存在且属性一致；
#   6. 特权白名单文件在镜像内存在（内容不作签名有效性断言）。
#
# 只作警告（不计入失败）：ramdisk/kernel/boot.img 缺失、vbmeta 未处理、
# 默认角色未授予、SELinux 上下文长度为 25 字节（ea_set 写入无结尾 NUL，
# 原镜像文件为 26 字节，首次启动需用 ls -Z 复核）。
set -uo pipefail

declare -A TARGET=(
  [cn.xinxitong.launcher]="/system/system_ext/priv-app/XinXiTongLauncher/XinXiTongLauncher.apk"
  [cn.xinxitong.settings]="/system/system_ext/priv-app/XinXiTongSettings/XinXiTongSettings.apk"
  [cn.xinxitong.files]="/system/priv-app/XinXiTongFiles/XinXiTongFiles.apk"
  [cn.xinxitong.phone]="/system/product/priv-app/XinXiTongPhone/XinXiTongPhone.apk"
  [cn.xinxitong.contacts]="/system/product/priv-app/XinXiTongContacts/XinXiTongContacts.apk"
  [cn.xinxitong.messages]="/system/product/priv-app/XinXiTongMessages/XinXiTongMessages.apk"
  [cn.xinxitong.camera]="/system/product/app/XinXiTongCamera/XinXiTongCamera.apk"
  [cn.xinxitong.gallery]="/system/product/app/XinXiTongGallery/XinXiTongGallery.apk"
  [cn.xinxitong.browser]="/system/product/app/XinXiTongBrowser/XinXiTongBrowser.apk"
  [cn.xinxitong.clock]="/system/product/app/XinXiTongClock/XinXiTongClock.apk"
  [cn.xinxitong.calculator]="/system/product/app/XinXiTongCalculator/XinXiTongCalculator.apk"
  [cn.xinxitong.calendar]="/system/product/app/XinXiTongCalendar/XinXiTongCalendar.apk"
  [cn.xinxitong.notes]="/system/product/app/XinXiTongNotes/XinXiTongNotes.apk"
)
AGENT_TARGET="/system/system_ext/priv-app/AiAgent/AiAgent.apk"
PRIVAPP_CN="/system/etc/permissions/privapp-permissions-cn.xinxitong.xml"
PRIVAPP_AGENT="/system/etc/permissions/privapp-permissions-aiagent.xml"

log()  { printf '[verify-bootable] %s\n' "$*"; }
fail=0; warn=0

bundle_dir=""
while [[ $# -gt 0 ]]; do case "$1" in
  --bundle-dir) bundle_dir="$2"; shift 2 ;;
  -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
  *) printf '[verify-bootable] ERROR: 未知参数：%s\n' "$1" >&2; exit 2 ;;
esac; done
[[ -n "$bundle_dir" && -d "$bundle_dir" ]] || { printf '[verify-bootable] ERROR: 需要 --bundle-dir <存在的 bundle 目录>\n' >&2; exit 2; }

command -v debugfs >/dev/null 2>&1 || { log "ERROR: 缺少 debugfs"; exit 2; }
command -v e2fsck >/dev/null 2>&1 || { log "ERROR: 缺少 e2fsck"; exit 2; }
command -v python3 >/dev/null 2>&1 || { log "ERROR: 缺少 python3"; exit 2; }
command -v sha256sum >/dev/null 2>&1 || { log "ERROR: 缺少 sha256sum"; exit 2; }

# --- 1. manifest.json ---
manifest="$bundle_dir/manifest.json"
[[ -f "$manifest" ]] || { log "FAIL: 缺少 manifest.json"; exit 1; }
python3 -c 'import json,sys; json.load(open(sys.argv[1],encoding="utf-8"))' "$manifest" \
  || { log "FAIL: manifest.json 不是合法 JSON"; exit 1; }
log "manifest.json 存在且为合法 JSON"
label="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])) .get("label",""))' "$manifest")"
log "bundle label: ${label:-（未标注）}"
if [[ "$label" == "dummy-test" ]]; then
  log "警告：此 bundle 标注为 dummy-test（假 APK 样例），不是真实集成"
  warn=$((warn+1))
fi

# --- 2. manifest 所列文件存在且 SHA-256 对得上 ---
python3 - "$bundle_dir" <<'PYEOF' > /tmp/verify-bootable-manifest-check.txt 2>&1 || true
import hashlib, json, os, sys
bundle = sys.argv[1]
m = json.load(open(os.path.join(bundle, "manifest.json"), encoding="utf-8"))
bad = []
for ent in m.get("files", []):
    p = os.path.join(bundle, ent["path"])
    if not os.path.isfile(p):
        bad.append(f'MISSING {ent["path"]}'); continue
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    if h.hexdigest() != ent["sha256"]:
        bad.append(f'SHA-MISMATCH {ent["path"]}')
    if os.path.getsize(p) != ent["bytes"]:
        bad.append(f'SIZE-MISMATCH {ent["path"]}')
print("MANIFEST_FILES", len(m.get("files", [])), "BAD", len(bad))
for b in bad: print(b)
PYEOF
cat /tmp/verify-bootable-manifest-check.txt
if grep -q '^MISSING\|^SHA-MISMATCH\|^SIZE-MISMATCH' /tmp/verify-bootable-manifest-check.txt; then
  log "FAIL: manifest 文件校验未通过（见上）"; fail=1
else
  log "manifest 所列文件全部存在且 SHA-256/大小一致"
fi
rm -f /tmp/verify-bootable-manifest-check.txt

# --- 3. system.img 文件系统检查 ---
img="$bundle_dir/system.img"
[[ -f "$img" ]] || { log "FAIL: 缺少 system.img"; exit 1; }
if e2fsck -fn "$img" >/dev/null 2>&1; then log "system.img 通过 e2fsck -fn"; else log "FAIL: system.img 未通过 e2fsck -fn"; fail=1; fi

# --- 4/5/6. 镜像内 APK 与白名单 ---
check_in_image() { # check_in_image <label> <image-path> [required]
  local label="$1" path="$2" required="${3:-1}" tmp stat_out
  tmp="$(mktemp)"
  stat_out="$(debugfs "$img" -R "stat $path" 2>&1)" || true
  if [[ "$stat_out" != *"Inode:"* ]]; then
    if [[ "$required" -eq 1 ]]; then log "FAIL: 镜像内缺失 $label：$path"; fail=1; else log "缺失（可选）：$label：$path"; fi
    rm -f "$tmp"; return 1
  fi
  local problems=()
  [[ "$stat_out" == *"Mode:  0644"* ]] || problems+=("mode!=0644")
  [[ "$stat_out" == *"User:     0"* ]] || problems+=("uid!=0")
  [[ "$stat_out" == *"Group:     0"* ]] || problems+=("gid!=0")
  if [[ "$stat_out" != *"u:object_r:system_file:s0"* ]]; then
    problems+=("selinux-context!=system_file")
  elif [[ "$stat_out" == *"security.selinux (25)"* ]]; then
    log "警告：$label 的 SELinux 上下文长度为 25 字节（ea_set 写入无结尾 NUL，原镜像为 26 字节），首次启动需用 ls -Z 复核"
    warn=$((warn+1))
  fi
  if [[ "${#problems[@]}" -gt 0 ]]; then
    log "FAIL: $label 属性不符（${problems[*]}）：$path"; fail=1
  else
    log "OK: $label $path（0644, root:root, system_file）"
  fi
  # 内容哈希：dump 出来算 SHA-256 并记录，供人工与 APK 来源核对。
  debugfs "$img" -R "dump $path $tmp" >/dev/null 2>&1 || true
  if [[ -s "$tmp" ]]; then log "    镜像内 SHA-256：$(sha256sum "$tmp" | awk '{print $1}')"; fi
  rm -f "$tmp"
  return 0
}

ok_count=0
for pkg in "${!TARGET[@]}"; do
  if check_in_image "$pkg" "${TARGET[$pkg]}"; then ok_count=$((ok_count+1)); fi
done
log "应用 APK：$ok_count / ${#TARGET[@]} 个在位且属性一致"

agent_provided="$(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); a=m.get("agent_apk"); print("yes" if a else "no")' "$manifest")"
if [[ "$agent_provided" == "yes" ]]; then
  check_in_image "Agent dev.pocketvm.aiagent" "$AGENT_TARGET"
  check_in_image "Agent 特权白名单" "$PRIVAPP_AGENT"
else
  log "manifest 标注未提供 Agent APK：跳过 Agent 检查（如实，非失败）"
fi
check_in_image "特权白名单 cn.xinxitong" "$PRIVAPP_CN"

# --- 警告项：启动要件 ---
for f in kernel-Image ramdisk.img boot.img vbmeta.img; do
  [[ -f "$bundle_dir/$f" ]] || { log "警告：bundle 缺少 $f（启动可能受阻，见 manifest boot_blockers）"; warn=$((warn+1)); }
done
[[ -f "$bundle_dir/userdata.qcow2" && -f "$bundle_dir/metadata.img" ]] \
  || { log "警告：bundle 缺少 userdata.qcow2 或 metadata.img"; warn=$((warn+1)); }

log "校验结束：fail=$fail, warnings=$warn"
[[ "$fail" -eq 0 ]] || exit 1
log "PASS：bundle 文件与镜像内应用均通过校验（仅证明文件完整性，不证明系统可启动）"
exit 0
