#!/usr/bin/env bash
# integrate-bootable.sh — 可启动镜像集成流水线（仅 QEMU virt 测试用）
#
# 把 GSI system.img 副本 + 13 个自研应用 APK（可选 + Agent APK）+ 内核/
# ramdisk/boot 镜像，组装成一个可交付的 bundle 目录，并生成 manifest.json。
#
# 用法：
#   ./integrate-bootable.sh \
#     --system-img-copy <GSI system.img 副本路径> \
#     --apk-dir <APK 目录，13 个 <包名>.apk> \
#     [--agent-apk <Agent APK 路径，可选>] \
#     [--src-zip <GSI zip，替代 --system-img-copy 时从中解出 system.img>] \
#     [--ramdisk <ramdisk 文件>] [--kernel <内核 Image 文件>] \
#     [--boot-img <boot.img 文件>] [--vbmeta <vbmeta.img 文件>] \
#     [--grow-mb N] [--remove-replaced] [--label <标签>] \
#     --bundle-dir <输出 bundle 目录> [--force]
#
# 硬性限制（故意设计，勿绕过）：
#   * 绝不修改输入的 system.img 副本、GSI 原始 zip、kernel、ramdisk 原件；
#     一律先把 system.img 复制到 bundle 内的工作区再集成。
#   * 13 个 APK 缺任何一个都直接失败并列出缺失包名，绝不伪造 APK，
#     也不用占位文件冒充真实应用。
#   * 本脚本不签名、不启动 QEMU、不处理 vbmeta/AVB 重签；
#     vbmeta 只是原样复制进 bundle（若提供），启动方自行处理。
#   * 本脚本不验证 APK 的签名证书身份、也不验证 ramdisk 内是否真有
#     first-stage init/fstab；这些缺口如实写进 manifest.json。
#   * 默认只添加、不删除 AOSP 应用；--remove-replaced 已在假 APK 测试中
#     证明会损坏文件系统（debugfs rm 后块位图不一致，e2fsck -fn 不通过，
#     见 TEST-RECORD-BOOTABLE.md），本流水线因此直接拒绝该选项，
#     直到复用的 integrate.sh 在上游修好删除实现为止。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTEGRATE_SH="$SCRIPT_DIR/integrate.sh"
AGENT_PRIVAPP_XML="$SCRIPT_DIR/privapp-permissions-aiagent.xml"

# 包名 -> 镜像内目标路径（与 replacement-mapping.csv / integrate.sh 一致）
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
AGENT_PKG="dev.pocketvm.aiagent"
AGENT_TARGET="/system/system_ext/priv-app/AiAgent/AiAgent.apk"
AGENT_PRIVAPP_TARGET="/system/etc/permissions/privapp-permissions-aiagent.xml"

log()  { printf '[bootable] %s\n' "$*"; }
die()  { printf '[bootable] ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "缺少必需工具: $1"; }

validate_apk() { # validate_apk <apk> <label>
  local apk="$1" label="$2" list_tmp
  [[ -f "$apk" ]] || die "找不到 $label：$apk"
  unzip -t -q "$apk" >/dev/null 2>&1 || die "$label 不是合法 zip：$apk"
  list_tmp="$(mktemp)"
  unzip -l "$apk" > "$list_tmp" 2>/dev/null || true
  grep -q 'AndroidManifest.xml' "$list_tmp" || { rm -f "$list_tmp"; die "$label 内无 AndroidManifest.xml：$apk"; }
  rm -f "$list_tmp"
}

img_exists() {
  local out
  out="$(debugfs "$1" -R "stat $2" 2>&1)" || true
  [[ "$out" == *"Inode:"* ]]
}
img_sha256() {
  local img="$1" path="$2" tmp="$3"
  if ! img_exists "$img" "$path"; then echo ""; return 0; fi
  debugfs "$img" -R "dump $path $tmp" >/dev/null 2>&1 || true
  sha256sum "$tmp" | awk '{print $1}'
}
dbg_batch() {
  local img="$1" cmds="$2"
  debugfs -w "$img" < "$cmds" 2>&1
}
dbg() {
  local img="$1"; shift
  debugfs -w "$img" -R "$*" 2>&1
}

# --- 参数 ---
system_img_copy=""; apk_dir=""; agent_apk=""; src_zip=""
ramdisk=""; kernel=""; boot_img=""; vbmeta=""
grow_mb=0; remove_replaced=0; label="integration"; bundle_dir=""; force=0
while [[ $# -gt 0 ]]; do case "$1" in
  --system-img-copy) system_img_copy="$2"; shift 2 ;;
  --apk-dir) apk_dir="$2"; shift 2 ;;
  --agent-apk) agent_apk="$2"; shift 2 ;;
  --src-zip) src_zip="$2"; shift 2 ;;
  --ramdisk) ramdisk="$2"; shift 2 ;;
  --kernel) kernel="$2"; shift 2 ;;
  --boot-img) boot_img="$2"; shift 2 ;;
  --vbmeta) vbmeta="$2"; shift 2 ;;
  --grow-mb) grow_mb="$2"; shift 2 ;;
  --remove-replaced) remove_replaced=1; shift ;;
  --label) label="$2"; shift 2 ;;
  --bundle-dir) bundle_dir="$2"; shift 2 ;;
  --force) force=1; shift ;;
  -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
  *) die "未知参数：$1" ;;
esac; done

[[ -n "$bundle_dir" ]] || die "需要 --bundle-dir <输出 bundle 目录>"
if [[ "$remove_replaced" -eq 1 ]]; then
  die "--remove-replaced 已禁用：假 APK 测试证明复用的 integrate.sh 删除后 e2fsck -fn 不通过（块位图不一致），会产出损坏镜像。详见 TEST-RECORD-BOOTABLE.md；修好上游删除实现前请勿删除 AOSP 应用（默认只添加、不删除）。"
fi
[[ -n "$apk_dir" ]] || die "需要 --apk-dir <APK 目录>"
[[ -d "$apk_dir" ]] || die "APK 目录不存在：$apk_dir"
[[ -x "$INTEGRATE_SH" ]] || die "找不到复用的 integrate.sh：$INTEGRATE_SH"
need debugfs; need dumpe2fs; need e2fsck; need resize2fs; need unzip; need sha256sum; need python3
need qemu-img; need mkfs.ext4; need truncate

# --- 1. 输入校验：拒绝原始 zip / 原始 GSI 目录；13 个 APK 一个都不能缺 ---
if [[ -n "$src_zip" ]]; then
  [[ -f "$src_zip" ]] || die "找不到 GSI zip：$src_zip"
else
  [[ -n "$system_img_copy" ]] || die "需要 --system-img-copy 或 --src-zip 之一"
  [[ -f "$system_img_copy" ]] || die "system.img 副本不存在：$system_img_copy"
  [[ "$system_img_copy" != *.zip ]] || die "拒绝以 zip 作为 system.img 输入：$system_img_copy"
  case "$system_img_copy" in
    */workspace/gsi/*|*/gsi/*) die "拒绝操作原始 GSI 目录下的文件：$system_img_copy（请先复制一份再传入）" ;;
  esac
fi

declare -A APK_FOR_PKG=()
missing=()
for pkg in "${!TARGET[@]}"; do
  cand="$apk_dir/$pkg.apk"
  if [[ -f "$cand" ]]; then APK_FOR_PKG[$pkg]="$cand"; else missing+=("$pkg"); fi
done
if [[ "${#missing[@]}" -gt 0 ]]; then
  printf '[bootable] ERROR: APK 目录缺 %d 个包，拒绝集成（绝不伪造 APK）：\n' "${#missing[@]}" >&2
  printf '[bootable]   缺失：%s\n' "${missing[*]}" >&2
  printf '[bootable]   期望：13 个 <包名>.apk（见 replacement-mapping.csv），APK 目录：%s\n' "$apk_dir" >&2
  exit 1
fi
for pkg in "${!TARGET[@]}"; do validate_apk "${APK_FOR_PKG[$pkg]}" "应用 $pkg"; done
log "13 个应用 APK 全部就位，逐一校验为合法 zip 且含 AndroidManifest.xml"

agent_sha=""; agent_size=0
if [[ -n "$agent_apk" ]]; then
  validate_apk "$agent_apk" "Agent APK"
  agent_sha="$(sha256sum "$agent_apk" | awk '{print $1}')"
  agent_size="$(stat -c%s "$agent_apk")"
  log "Agent APK 就位：$agent_apk（$agent_sha）"
else
  log "未提供 --agent-apk：bundle 中不含 Agent，manifest 会如实标注 agent_absent"
fi
for f in "$ramdisk" "$kernel" "$boot_img" "$vbmeta"; do
  [[ -z "$f" ]] || [[ -f "$f" ]] || die "输入文件不存在：$f"
done

# --- 2. 准备 bundle 目录与工作区（输入文件一律只读复制） ---
if [[ -e "$bundle_dir" && -n "$(ls -A "$bundle_dir" 2>/dev/null)" ]]; then
  [[ "$force" -eq 1 ]] || die "bundle 目录已存在且非空：$bundle_dir（加 --force 才会清空重建）"
  rm -rf "$bundle_dir"
fi
mkdir -p "$bundle_dir"
staging="$bundle_dir/.staging"
mkdir -p "$staging"
trap 'log "失败：工作区保留在 $staging 供排查，bundle 未完成"' ERR

input_img="$staging/input-system.img"
if [[ -n "$src_zip" ]]; then
  unzip -o "$src_zip" system.img -d "$staging" >/dev/null
  mv "$staging/system.img" "$input_img"
  src_zip_sha="$(sha256sum "$src_zip" | awk '{print $1}')"
  log "已从 GSI zip 解出 system.img 副本（原始 zip 未修改），zip sha256=$src_zip_sha"
else
  cp -- "$system_img_copy" "$input_img"
  src_zip_sha=""
  log "已复制输入 system.img（原件未修改）：$system_img_copy"
fi
input_img_sha_before="$(sha256sum "$input_img" | awk '{print $1}')"

# integrate.sh 要求镜像旁有标记文件：只在工作区内写标记，原件不受影响。
{
  echo "QEMU-INTEGRATION-COPY"
  echo "source=integrate-bootable.sh"
  echo "input_system_img_sha256=$input_img_sha_before"
  echo "prepared_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$staging/.integration-copy-marker"
cp -- "$input_img" "$staging/system.img"

# --- 3. 复用 integrate.sh 写入 13 个 APK + 特权白名单 ---
integrate_args=(integrate --apk-dir "$apk_dir" --system-img-copy "$staging/system.img")
[[ "$grow_mb" -gt 0 ]] && integrate_args+=(--grow-mb "$grow_mb")
[[ "$remove_replaced" -eq 1 ]] && integrate_args+=(--remove-replaced)
log "调用复用的 integrate.sh：${integrate_args[*]}"
"$INTEGRATE_SH" "${integrate_args[@]}"

# --- 4. 写入 Agent APK + Agent 特权白名单（可选） ---
if [[ -n "$agent_apk" ]]; then
  [[ -f "$AGENT_PRIVAPP_XML" ]] || die "找不到 Agent 特权白名单草案：$AGENT_PRIVAPP_XML"
  tmp_dump="$(mktemp)"
  # 写 APK
  cmds="$(mktemp)"; : > "$cmds"
  p=""; IFS=/ read -ra parts <<< "${AGENT_TARGET#/}"
  dir="${AGENT_TARGET%/*}"
  for part in "${parts[@]:0:${#parts[@]}-1}"; do p="$p/$part"; echo "mkdir $p" >> "$cmds"; done
  echo "write $agent_apk $AGENT_TARGET" >> "$cmds"
  dbg_batch "$staging/system.img" "$cmds" >/dev/null 2>&1 || log "警告：Agent APK 写入输出异常，继续以 stat/sha 核对"
  dbg "$staging/system.img" "sif $AGENT_TARGET mode 33188" >/dev/null 2>&1 || true
  dbg "$staging/system.img" "sif $AGENT_TARGET uid 0" >/dev/null 2>&1 || true
  dbg "$staging/system.img" "sif $AGENT_TARGET gid 0" >/dev/null 2>&1 || true
  dbg "$staging/system.img" "ea_set $AGENT_TARGET security.selinux u:object_r:system_file:s0" >/dev/null 2>&1 || true
  cur_sha="$(img_sha256 "$staging/system.img" "$AGENT_TARGET" "$tmp_dump")"
  [[ "$cur_sha" == "$agent_sha" ]] || die "Agent APK 写入后校验失败（镜像内 sha256 与 APK 不一致）"
  log "已写入 Agent APK：$AGENT_TARGET"
  # 写白名单
  cmds2="$(mktemp)"; echo "write $AGENT_PRIVAPP_XML $AGENT_PRIVAPP_TARGET" > "$cmds2"
  dbg_batch "$staging/system.img" "$cmds2" >/dev/null 2>&1 || true
  dbg "$staging/system.img" "sif $AGENT_PRIVAPP_TARGET mode 33188" >/dev/null 2>&1 || true
  dbg "$staging/system.img" "ea_set $AGENT_PRIVAPP_TARGET security.selinux u:object_r:system_file:s0" >/dev/null 2>&1 || true
  log "已写入 Agent 特权白名单草案：$AGENT_PRIVAPP_TARGET（仅草案，未用平台密钥签名时不授予 DUMP）"
  rm -f "$tmp_dump" "$cmds" "$cmds2"
fi

e2fsck -fn "$staging/system.img" >/dev/null 2>&1 || die "集成后 e2fsck -fn 未通过"
integrated_img_sha="$(sha256sum "$staging/system.img" | awk '{print $1}')"
integrated_img_size="$(stat -c%s "$staging/system.img")"
log "集成后 system.img sha256=$integrated_img_sha，大小 $integrated_img_size 字节"

# --- 5. 组装 bundle：system.img、内核/ramdisk/boot、vbmeta、userdata、metadata ---
mv -- "$staging/system.img" "$bundle_dir/system.img"
if [[ -f "$staging/system.img.integration.json" ]]; then
  mv -- "$staging/system.img.integration.json" "$bundle_dir/system-integration.json"
fi
cp -- "$SCRIPT_DIR/replacement-mapping.csv" "$bundle_dir/replacement-mapping.csv"
cp -- "$SCRIPT_DIR/privapp-permissions-cn.xinxitong.xml" "$bundle_dir/privapp-permissions-cn.xinxitong.xml"
cp -- "$SCRIPT_DIR/privapp-permissions-aiagent.xml" "$bundle_dir/privapp-permissions-aiagent.xml"

declare -A COPIED=()  # bundle 相对路径 -> 来源路径
copy_input() { # copy_input <src> <bundle-rel-name> <role>
  local src="$1" rel="$2"
  [[ -n "$src" ]] || return 0
  cp -- "$src" "$bundle_dir/$rel"
  COPIED["$rel"]="$src"
}
copy_input "$kernel" "kernel-Image" "kernel"
copy_input "$ramdisk" "ramdisk.img" "ramdisk"
copy_input "$boot_img" "boot.img" "boot"
copy_input "$vbmeta" "vbmeta.img" "vbmeta"
# 若 system.img 副本旁有同名 vbmeta/build.prop 且未显式传入，顺手复制并记录。
if [[ -z "$vbmeta" && -f "$(dirname "$system_img_copy")/vbmeta.img" ]]; then
  copy_input "$(dirname "$system_img_copy")/vbmeta.img" "vbmeta.img" "vbmeta"
fi
if [[ -f "$(dirname "$system_img_copy")/build.prop" ]]; then
  copy_input "$(dirname "$system_img_copy")/build.prop" "build.prop" "gsi-build-prop"
fi

qemu-img create -f qcow2 "$bundle_dir/userdata.qcow2" 4G >/dev/null
truncate -s 16M "$bundle_dir/metadata.img"
mkfs.ext4 -q -F -L metadata "$bundle_dir/metadata.img" >/dev/null 2>&1 || die "metadata.img 制作失败（mkfs.ext4）"
log "已生成 userdata.qcow2（4G qcow2）与 metadata.img（16M ext4）"

# 校验脚本随 bundle 一起交付（bundle 内副本与本目录 canonical 版本一致）。
cp -- "$SCRIPT_DIR/verify-bootable.sh" "$bundle_dir/verify-bootable.sh"
chmod +x "$bundle_dir/verify-bootable.sh"

# --- 6. 生成 manifest.json ---
created_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
python3 - "$bundle_dir" "$created_utc" "$label" "$input_img_sha_before" "$integrated_img_sha" \
  "$grow_mb" "$remove_replaced" "$src_zip_sha" "$agent_apk" "$agent_sha" "$agent_size" <<'PYEOF'
import hashlib, json, os, sys
bundle, created, label, before, after, grow, removed, src_zip_sha, agent_apk, agent_sha, agent_size = sys.argv[1:12]
def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()
files = []
for name in sorted(os.listdir(bundle)):
    p = os.path.join(bundle, name)
    if not os.path.isfile(p) or name == "manifest.json":
        continue
    files.append({"path": name, "sha256": sha(p), "bytes": os.path.getsize(p)})
manifest = {
    "bundle": "xin-xi-tong bootable image bundle (QEMU virt only)",
    "label": label,
    "created_utc": created,
    "gsi_source_zip_sha256": src_zip_sha or None,
    "system_img_sha256_before_integration": before,
    "system_img_sha256_after_integration": after,
    "grow_mb": int(grow),
    "remove_replaced": removed == "1",
    "apk_source_dir_note": "APK files were taken from the --apk-dir given at run time; this manifest does not prove they are real signed apps.",
    "real_apks_verified": False,
    "agent_apk": {"provided": bool(agent_apk), "source": agent_apk or None,
                  "sha256": agent_sha or None, "bytes": int(agent_size or 0),
                  "target": "/system/system_ext/priv-app/AiAgent/AiAgent.apk"} if agent_apk else None,
    "boot_blockers": [
        "first-stage ramdisk / vendor_boot presence is NOT verified by this pipeline: the ramdisk supplied (if any) was only copied and hashed, its /init and fstab were not inspected.",
        "vbmeta/AVB was NOT re-signed or handled: a modified system.img may fail verification at boot unless the boot flow disables it (see INTEGRATION-BOOTABLE.md).",
        "Default roles (HOME/DIALER/SMS/BROWSER) must be granted at first boot; they are not granted by image integration.",
        "Priv-app whitelist entries grant nothing without platform-key signing; see privapp XML draft warnings.",
    ],
    "files": files,
}
with open(os.path.join(bundle, "manifest.json"), "w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=2, ensure_ascii=False)
    f.write("\n")
PYEOF

# --- 7. 清理工作区，收尾 ---
rm -rf "$staging"
trap - ERR
log "完成。bundle：$bundle_dir"
log "system.img：$input_img_sha_before（集成前） -> $integrated_img_sha（集成后）"
log "下一步：用 bundle/verify-bootable.sh --bundle-dir $bundle_dir 校验 bundle 完整性；"
log "注意：本流水线只证明文件已写入镜像，绝不声称系统已启动或应用已真实集成。"
