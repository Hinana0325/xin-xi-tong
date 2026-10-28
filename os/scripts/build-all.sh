#!/bin/sh
set -e
D=$(dirname "$0")
sh "$D/fetch-kernel.sh"
sh "$D/build-kernel.sh"
sh "$D/fetch-busybox.sh"
sh "$D/make-rootfs.sh"
echo "完成：build/Image 与 build/rootfs.ext4"
