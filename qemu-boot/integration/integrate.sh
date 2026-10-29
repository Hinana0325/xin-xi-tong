#!/usr/bin/env bash
# integrate.sh — 把自研应用 APK 集成进 GSI system.img 副本（仅 QEMU virt 测试用）
#
# 用法：
#   ./integrate.sh prepare --src-zip <GSI zip> --out-dir <目录>
#       从 GSI zip 解出 system.img/vbmeta.img/build.prop 的副本，并写入
#       .integration-copy-marker（之后 integrate 只认带此标记的副本）。
#   ./integrate.sh integrate --apk-dir <目录> --system-img-copy <system.img 路径> [--grow-mb N] [--remove-replaced] [--no-privapp-allowlist] [--default-permissions-file <文件>]
#   ./integrate.sh verify --system-img-copy <system.img 路径>
#
# 硬性限制（故意设计，勿绕过）：
#   * 绝不操作 ~/workspace/gsi/ 下的原始 zip，也绝不操作无标记的镜像。
#   * APK 目录为空（13 个包名 APK 一个都没有）时直接失败，并列出缺失项。
#   * 本脚本不签名、不启动 QEMU、不做 vbmeta 重签（见 INTEGRATION.md）。
#   * 默认只“添加”自研 APK，不删除任何 AOSP 应用；--remove-replaced 才
#     删除 replacement-mapping.csv 中标记为 REMOVE-OPTIONAL 的 UI 应用，
#     且永不删除 provider/service 类应用（见映射表 KEEP 行）。
#   * 本机无 loop 设备挂载：写入通过 debugfs -w 完成（raw ext4 镜像，
#     已核实 system.img 不是 sparse 镜像，无需 simg2img）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRIVAPP_XML="$SCRIPT_DIR/privapp-permissions-cn.xinxitong.xml"
MARKER_NAME=".integration-copy-marker"

# 包名 -> "镜像内路径|目录（调试用）"（与 replacement-mapping.csv 一致）
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

# 仅当 --remove-replaced 时才删除的 AOSP UI 应用目录（镜像内路径）。
# 绝不在此列之外删除任何东西；provider/service 永远保留。
declare -A REMOVE_DIR=(
  [com.android.launcher3]="/system/system_ext/priv-app/Launcher3QuickStep"
  [com.android.dialer]="/system/product/priv-app/Dialer"
  [com.android.contacts]="/system/product/priv-app/Contacts"
  [com.android.messaging]="/system/product/app/messaging"
  [com.android.camera2]="/system/product/app/Camera2"
  [com.android.gallery3d]="/system/product/app/Gallery2"
  [com.android.deskclock]="/system/product/app/DeskClock"
  [com.android.calendar]="/system/product/app/Calendar"
)

log()  { printf '[integrate] %s\n' "$*"; }
die()  { printf '[integrate] ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "缺少必需工具: $1（本机未安装，见 INTEGRATION.md 第 2 节）"; }

dbg() { # dbg "<debugfs 命令>" — 在镜像上执行一条 debugfs 命令（-w 写入模式）
  local img="$1"; shift
  debugfs -w "$img" -R "$*" 2>&1
}
dbg_batch() { # dbg_batch <img> <命令文件> — 批量执行（命令经 stdin 送入 debugfs）
  local img="$1" cmds="$2"
  debugfs -w "$img" < "$cmds" 2>&1
}
img_exists() { # 镜像内路径是否存在（debugfs stat 退出码恒为 0，必须解析输出）
  local out
  out="$(debugfs "$1" -R "stat $2" 2>&1)" || true
  [[ "$out" == *"Inode:"* ]]
}
img_sha256() { # 把镜像内文件 dump 到临时文件并算 sha256；不存在则返回空
  local img="$1" path="$2" tmp="$3"
  if ! img_exists "$img" "$path"; then echo ""; return 0; fi
  debugfs "$img" -R "dump $path $tmp" >/dev/null 2>&1 || true
  sha256sum "$tmp" | awk '{print $1}'
}
free_bytes() {
  local img="$1"
  local blocks bsize
  blocks="$(dumpe2fs -h "$img" 2>/dev/null | awk -F: '/Free blocks/{gsub(/ /,"",$2); print $2}')"
  bsize="$(dumpe2fs -h "$img" 2>/dev/null | awk -F: '/Block size/{gsub(/ /,"",$2); print $2}')"
  echo $((blocks * bsize))
}
check_marker() {
  local img="$1"
  [[ "$img" != *.zip ]] || die "拒绝操作 zip 文件：$img（只能操作 prepare 解出的副本）"
  case "$img" in
    */workspace/gsi/*|*/gsi/*) die "拒绝操作原始 GSI 目录下的文件：$img" ;;
  esac
  local dir marker
  dir="$(dirname "$img")"; marker="$dir/$MARKER_NAME"
  [[ -f "$marker" ]] || die "镜像 $img 旁边没有 $MARKER_NAME：它不是本脚本 prepare 解出的副本，拒绝操作（防误写原始镜像）"
  grep -q '^QEMU-INTEGRATION-COPY$' "$marker" || die "标记文件 $marker 内容异常，拒绝操作"
  log "已核对副本标记：$marker"
}

cmd_prepare() {
  local src_zip="" out_dir=""
  while [[ $# -gt 0 ]]; do case "$1" in
    --src-zip) src_zip="$2"; shift 2 ;;
    --out-dir) out_dir="$2"; shift 2 ;;
    *) die "prepare: 未知参数 $1" ;;
  esac; done
  [[ -n "$src_zip" && -n "$out_dir" ]] || die "prepare 需要 --src-zip 和 --out-dir"
  [[ -f "$src_zip" ]] || die "找不到 GSI zip：$src_zip"
  need unzip; need sha256sum
  mkdir -p "$out_dir"
  unzip -o "$src_zip" system.img vbmeta.img build.prop -d "$out_dir" >/dev/null
  local zip_sha img_sha
  zip_sha="$(sha256sum "$src_zip" | awk '{print $1}')"
  img_sha="$(sha256sum "$out_dir/system.img" | awk '{print $1}')"
  {
    echo "QEMU-INTEGRATION-COPY"
    echo "source_zip=$src_zip"
    echo "source_zip_sha256=$zip_sha"
    echo "pristine_system_img_sha256=$img_sha"
    echo "prepared_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "gsi_build=DP11.261002.005 (见 build.prop；以镜像内 build.prop 为准)"
  } > "$out_dir/$MARKER_NAME"
  log "副本已解出：$out_dir/system.img"
  log "原始 system.img sha256: $img_sha（回滚时以此为准）"
  log "标记文件：$out_dir/$MARKER_NAME"
}

cmd_integrate() {
  local apk_dir="" img="" grow_mb=0 remove_replaced=0 with_privapp=1 default_perm_file=""
  while [[ $# -gt 0 ]]; do case "$1" in
    --apk-dir) apk_dir="$2"; shift 2 ;;
    --system-img-copy) img="$2"; shift 2 ;;
    --grow-mb) grow_mb="$2"; shift 2 ;;
    --remove-replaced) remove_replaced=1; shift ;;
    --no-privapp-allowlist) with_privapp=0; shift ;;
    --default-permissions-file) default_perm_file="$2"; shift 2 ;;
    *) die "integrate: 未知参数 $1" ;;
  esac; done
  [[ -n "$apk_dir" && -n "$img" ]] || die "integrate 需要 --apk-dir 和 --system-img-copy"
  [[ -d "$apk_dir" ]] || die "APK 目录不存在：$apk_dir"
  [[ -f "$img" ]] || die "镜像文件不存在：$img"
  need debugfs; need dumpe2fs; need e2fsck; need resize2fs; need unzip; need sha256sum
  check_marker "$img"

  # --- 1. 收集 APK：文件名必须是 <包名>.apk，或由 apk-map.csv 指定 ---
  declare -A APK_FOR_PKG=()
  local found=0
  for pkg in "${!TARGET[@]}"; do
    local cand="$apk_dir/$pkg.apk"
    if [[ -f "$cand" ]]; then APK_FOR_PKG[$pkg]="$cand"; found=$((found+1)); fi
  done
  if [[ -f "$apk_dir/apk-map.csv" ]]; then
    log "发现 apk-map.csv，按其映射覆盖文件名推断"
    while IFS=, read -r pkg file; do
      pkg="$(echo "$pkg" | tr -d '[:space:]')"; file="$(echo "$file" | tr -d '[:space:]')"
      [[ -z "$pkg" || "$pkg" == "package" ]] && continue
      [[ -n "${TARGET[$pkg]:-}" && -f "$apk_dir/$file" ]] && { APK_FOR_PKG[$pkg]="$apk_dir/$file"; found=$((found+1)); }
    done < "$apk_dir/apk-map.csv"
  fi
  if [[ "$found" -eq 0 ]]; then
    die "APK 目录 $apk_dir 为空：13 个期望 APK（${!TARGET[*]}）一个都没有。请先在有 JDK/Android SDK 的机器上构建（见 INTEGRATION.md 第 7 节），把 APK 按 <包名>.apk 命名后放入该目录；本脚本绝不伪造 APK。"
  fi
  local missing=()
  for pkg in "${!TARGET[@]}"; do [[ -n "${APK_FOR_PKG[$pkg]:-}" ]] || missing+=("$pkg"); done
  [[ "${#missing[@]}" -eq 0 ]] || log "警告：本次缺少 ${#missing[@]} 个 APK，将跳过：${missing[*]}（其余 ${found} 个继续集成）"

  # --- 2. 校验 APK（必须是 zip 且含 AndroidManifest.xml）---
  for pkg in "${!APK_FOR_PKG[@]}"; do
    local apk="${APK_FOR_PKG[$pkg]}" list_tmp
    list_tmp="$(mktemp)"
    unzip -t -q "$apk" >/dev/null || die "APK 不是合法 zip：$apk"
    # 注意：不可用 `unzip -l | grep -q`（pipefail 下 unzip 会因 SIGPIPE 返回 141）
    unzip -l "$apk" > "$list_tmp" 2>/dev/null
    grep -q 'AndroidManifest.xml' "$list_tmp" || die "APK 内无 AndroidManifest.xml：$apk"
    rm -f "$list_tmp"
  done

  # --- 3. 文件系统干净检查 + 空间检查 / 扩容 ---
  e2fsck -fn "$img" >/dev/null 2>&1 || die "镜像文件系统检查未通过（e2fsck -fn 非 0），拒绝写入：$img"
  local need_bytes=0
  for pkg in "${!APK_FOR_PKG[@]}"; do need_bytes=$((need_bytes + $(stat -c%s "${APK_FOR_PKG[$pkg]}"))); done
  need_bytes=$((need_bytes + need_bytes/5 + 16777216))
  local free
  free="$(free_bytes "$img")"
  log "镜像剩余空间 ${free} 字节，本次约需 ${need_bytes} 字节"
  if [[ "$free" -lt "$need_bytes" ]]; then
    [[ "$grow_mb" -gt 0 ]] || die "空间不足：剩余 ${free} 字节 < 需要 ${need_bytes} 字节。请加 --grow-mb N（建议 >= $(( (need_bytes - free) / 1048576 + 64 ))）扩容后重试。"
    log "扩容镜像 +${grow_mb} MiB"
    truncate -s "+${grow_mb}M" "$img"
    e2fsck -fy "$img" >/dev/null 2>&1 || die "扩容后 e2fsck 失败"
    resize2fs "$img" >/dev/null 2>&1 || die "resize2fs 失败"
    free="$(free_bytes "$img")"; log "扩容后剩余空间 ${free} 字节"
    [[ "$free" -ge "$need_bytes" ]] || die "扩容后空间仍不足"
  fi

  # --- 4. 写入 APK（幂等：已存在且 sha256 相同则跳过）---
  local before_sha manifest_tmp
  before_sha="$(sha256sum "$img" | awk '{print $1}')"
  manifest_tmp="$(mktemp)"
  local placed=() skipped=()
  for pkg in "${!TARGET[@]}"; do
    [[ -n "${APK_FOR_PKG[$pkg]:-}" ]] || continue
    local apk="${APK_FOR_PKG[$pkg]}" target="${TARGET[$pkg]}"
    local dir="${target%/*}" tmp_dump
    tmp_dump="$(mktemp)"
    local cur_sha host_sha
    host_sha="$(sha256sum "$apk" | awk '{print $1}')"
    cur_sha="$(img_sha256 "$img" "$target" "$tmp_dump")"
    rm -f "$tmp_dump"
    if [[ -n "$cur_sha" && "$cur_sha" == "$host_sha" ]]; then
      skipped+=("$pkg"); log "跳过（已存在且内容相同）：$target"; continue
    fi
    # 建目录（逐级 mkdir，已存在则忽略失败）、写入、定权限/属主/SELinux 上下文
    local cmds="$manifest_tmp.cmds"
    : > "$cmds"
    local p="" part
    IFS=/ read -ra parts <<< "${dir#/}"
    for part in "${parts[@]}"; do
      p="$p/$part"; echo "mkdir $p" >> "$cmds"
    done
    if [[ -n "$cur_sha" ]]; then echo "rm $target" >> "$cmds"; fi
    echo "write $apk $target" >> "$cmds"
    dbg_batch "$img" "$cmds" >/dev/null 2>&1 || log "警告：debugfs 批量写入输出异常，继续以 stat 核对：$target"
    dbg "$img" "sif $target mode 33188" >/dev/null 2>&1 || log "警告：设置 $target 模式失败（sif），需启动后核对"
    dbg "$img" "sif $target uid 0" >/dev/null 2>&1 || true
    dbg "$img" "sif $target gid 0" >/dev/null 2>&1 || true
    dbg "$img" "ea_set $target security.selinux u:object_r:system_file:s0" >/dev/null 2>&1 \
      || log "警告：设置 $target 的 SELinux 上下文失败（ea_set），首次启动需核对上下文为 u:object_r:system_file:s0"
    cur_sha="$(img_sha256 "$img" "$target" "$tmp_dump")"; rm -f "$tmp_dump"
    [[ "$cur_sha" == "$host_sha" ]] || die "写入后校验失败：$target（镜像内 sha256 与 APK 不一致）"
    placed+=("$pkg"); log "已写入：$target"
  done

  # --- 5. 特权白名单（默认写；内容见 privapp-permissions-cn.xinxitong.xml 顶部说明）---
  if [[ "$with_privapp" -eq 1 ]]; then
    [[ -f "$PRIVAPP_XML" ]] || die "找不到特权白名单草案：$PRIVAPP_XML"
    local allow_target="/system/etc/permissions/privapp-permissions-cn.xinxitong.xml"
    local allow_tmp; allow_tmp="$(mktemp)"
    local allow_sha host_allow_sha
    host_allow_sha="$(sha256sum "$PRIVAPP_XML" | awk '{print $1}')"
    allow_sha="$(img_sha256 "$img" "$allow_target" "$allow_tmp")"; rm -f "$allow_tmp"
    if [[ "$allow_sha" != "$host_allow_sha" ]]; then
      local cmds="$manifest_tmp.allow.cmds"; : > "$cmds"
      [[ -n "$allow_sha" ]] && echo "rm $allow_target" >> "$cmds"
      echo "write $PRIVAPP_XML $allow_target" >> "$cmds"
      dbg_batch "$img" "$cmds" >/dev/null 2>&1 || true
      dbg "$img" "sif $allow_target mode 33188" >/dev/null 2>&1 || true
      dbg "$img" "ea_set $allow_target security.selinux u:object_r:system_file:s0" >/dev/null 2>&1 || true
      log "已写入特权白名单草案：$allow_target（仅草案，未用平台密钥签名时不授予权限）"
    else
      log "跳过特权白名单（已存在且内容相同）"
    fi
  fi

  # --- 6. 可选的默认权限预授予文件（默认不做；需显式给文件）---
  if [[ -n "$default_perm_file" ]]; then
    [[ -f "$default_perm_file" ]] || die "找不到默认权限文件：$default_perm_file"
    local dp_target="/system/etc/default-permissions/default-permissions-cn.xinxitong.xml"
    local cmds="$manifest_tmp.dp.cmds"; : > "$cmds"
    img_exists "$img" "$dp_target" && echo "rm $dp_target" >> "$cmds"
    echo "write $default_perm_file $dp_target" >> "$cmds"
    dbg_batch "$img" "$cmds" >/dev/null 2>&1 || true
    dbg "$img" "sif $dp_target mode 33188" >/dev/null 2>&1 || true
    log "已写入默认权限文件：$dp_target（仅 QEMU 测试便利，见 INTEGRATION.md 说明）"
  fi

  # --- 7. 可选删除 AOSP UI 应用（默认关闭）---
  local removed=()
  if [[ "$remove_replaced" -eq 1 ]]; then
    for aosp_pkg in "${!REMOVE_DIR[@]}"; do
      local rdir="${REMOVE_DIR[$aosp_pkg]}"
      img_exists "$img" "$rdir" || { log "跳过删除（不存在）：$rdir"; continue; }
      local list_tmp; list_tmp="$(mktemp)"
      debugfs "$img" -R "ls -l $rdir" 2>/dev/null | awk '{print $NF}' | grep -v -E '^(\.|..)$' > "$list_tmp" || true
      local cmds="$manifest_tmp.rm.cmds"; : > "$cmds"
      while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        # 只删文件与一级子目录内的文件；目录本身用 rmdir（失败则保留空目录并记录）
        if img_exists "$img" "$rdir/$entry"; then echo "rm $rdir/$entry" >> "$cmds"; fi
      done < "$list_tmp"
      dbg_batch "$img" "$cmds" >/dev/null 2>&1 || true
      dbg "$img" "rmdir $rdir" >/dev/null 2>&1 || log "警告：目录 $rdir 未能 rmdir（可能仍有子目录），已清空其文件，空目录保留并记录"
      rm -f "$list_tmp"
      removed+=("$aosp_pkg:$rdir"); log "已删除（可选）：$rdir"
    done
  else
    log "默认模式：不删除任何 AOSP 应用（加 --remove-replaced 才删映射表中的 UI 应用）"
  fi

  # --- 8. 完整性复查 + 清单 ---
  e2fsck -fn "$img" >/dev/null 2>&1 || die "写入后 e2fsck -fn 未通过，镜像可能已损坏：请用 pristine 副本恢复后重试"
  local after_sha
  after_sha="$(sha256sum "$img" | awk '{print $1}')"
  python3 - "$img" "$before_sha" "$after_sha" "${placed[*]}" "${skipped[*]}" "${removed[*]}" "${missing[*]}" <<'PYEOF'
import json, sys
img, before, after, placed, skipped, removed, missing = sys.argv[1:8]
manifest = {
  "image": img,
  "system_img_sha256_before": before,
  "system_img_sha256_after": after,
  "placed_packages": placed.split() if placed else [],
  "skipped_identical_packages": skipped.split() if skipped else [],
  "removed_aosp": removed.split() if removed else [],
  "missing_apks_skipped": missing.split() if missing else [],
  "note": "QEMU-only test integration. Rollback: restore the pristine copy recorded in .integration-copy-marker.",
}
with open(img + ".integration.json", "w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=2, ensure_ascii=False)
PYEOF
  log "完成。清单：$img.integration.json"
  log "集成前 sha256: $before_sha"
  log "集成后 sha256: $after_sha"
  log "本次写入：${placed[*]:-(无)}；跳过（相同）：${skipped[*]:-(无)}；删除：${removed[*]:-(无)}"
  log "注意：vbmeta/AVB 未处理——启动前须按 INTEGRATION.md 第 8 节处理（由 QEMU 启动方负责），否则修改后的镜像可能无法通过校验启动。"
}

cmd_verify() {
  local img=""
  while [[ $# -gt 0 ]]; do case "$1" in
    --system-img-copy) img="$2"; shift 2 ;;
    *) die "verify: 未知参数 $1" ;;
  esac; done
  [[ -n "$img" && -f "$img" ]] || die "verify 需要 --system-img-copy <镜像文件>"
  need debugfs; need e2fsck
  check_marker "$img"
  e2fsck -fn "$img" || die "e2fsck -fn 未通过"
  local ok=0 miss=0
  for pkg in "${!TARGET[@]}"; do
    if img_exists "$img" "${TARGET[$pkg]}"; then echo "OK   $pkg -> ${TARGET[$pkg]}"; ok=$((ok+1));
    else echo "MISS $pkg -> ${TARGET[$pkg]}"; miss=$((miss+1)); fi
  done
  echo "placed: $ok, missing: $miss"
  [[ -f "$img.integration.json" ]] && log "清单文件存在：$img.integration.json" || log "无清单文件（未运行过 integrate 或清单被删）"
  [[ "$miss" -eq 0 ]] || exit 1
}

usage() {
  sed -n '2,20p' "$0"
  exit "${1:-0}"
}

[[ $# -ge 1 ]] || usage 1
case "$1" in
  prepare)   shift; cmd_prepare "$@" ;;
  integrate) shift; cmd_integrate "$@" ;;
  verify)    shift; cmd_verify "$@" ;;
  -h|--help|help) usage 0 ;;
  *) die "未知子命令：$1（prepare / integrate / verify）" ;;
esac
