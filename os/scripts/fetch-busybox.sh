#!/bin/sh
set -e
. "$(dirname "$0")/env.sh"
mkdir -p "$BUILD_ROOT/bb"
cd "$BUILD_ROOT"
part="$BUSYBOX_APK.part"
if [ ! -f "$BUSYBOX_APK" ]; then
  ok=0
  for base in $BUSYBOX_MIRRORS; do
    url="$base/$BUSYBOX_APK"
    echo "下载 $url"
    if ! curl -L --fail --connect-timeout 15 -o "$part" "$url"; then
      rm -f "$part"
      continue
    fi
    if printf '%s  %s\n' "$BUSYBOX_SHA256" "$part" | sha256sum -c - >/dev/null 2>&1; then
      mv "$part" "$BUSYBOX_APK"
      ok=1
      break
    fi
    echo "SHA256 校验失败，换下一个镜像"
    rm -f "$part"
  done
  [ "$ok" = 1 ] || { echo "所有国内镜像均失败，请检查网络或设置 BUSYBOX_MIRRORS"; exit 1; }
fi
printf '%s  %s\n' "$BUSYBOX_SHA256" "$BUSYBOX_APK" | sha256sum -c -
tar -xzf "$BUSYBOX_APK" -C bb bin/busybox.static
cp bb/bin/busybox.static "$BUILD_ROOT/busybox.static"
chmod 755 "$BUILD_ROOT/busybox.static"
ls -la "$BUILD_ROOT/busybox.static"
