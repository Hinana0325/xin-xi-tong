#!/bin/sh
set -e
. "$(dirname "$0")/env.sh"
mkdir -p "$BUILD_ROOT"
cd "$BUILD_ROOT"
part="$KERNEL_TARBALL.part"
if [ ! -f "$KERNEL_TARBALL" ]; then
  ok=0
  for base in $KERNEL_MIRRORS; do
    url="$base/$KERNEL_TARBALL"
    echo "下载 $url"
    if ! curl -L --fail --connect-timeout 15 -o "$part" "$url"; then
      rm -f "$part"
      continue
    fi
    if printf '%s  %s\n' "$KERNEL_SHA256" "$part" | sha256sum -c - >/dev/null 2>&1; then
      mv "$part" "$KERNEL_TARBALL"
      ok=1
      break
    fi
    echo "SHA256 校验失败，换下一个镜像"
    rm -f "$part"
  done
  [ "$ok" = 1 ] || { echo "所有国内镜像均失败，请检查网络或设置 KERNEL_MIRRORS"; exit 1; }
fi
printf '%s  %s\n' "$KERNEL_SHA256" "$KERNEL_TARBALL" | sha256sum -c -
if [ ! -d "linux-$KERNEL_VERSION" ]; then
  tar -xf "$KERNEL_TARBALL"
fi
echo "内核源码: $BUILD_ROOT/linux-$KERNEL_VERSION"
