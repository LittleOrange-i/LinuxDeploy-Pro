#!/bin/sh
# Linux Deploy Component
# (c) Anton Skshidlevsky <meefik@gmail.com>, GPLv3
#
# Kali 复用 bootstrap/debian 的 debootstrap 安装流程（EXTENDS=bootstrap/debian），
# 此处只覆盖发行版差异：
# 1) 默认代号 kali-rolling、默认源 http.kali.org（arm64 同样走该地址）；
# 2) Kali 的 debootstrap 脚本要求系统内存在 kali-archive-keyring，
#    安卓宿主没有，必须传 --no-check-gpg（debian 流程已默认携带）；
# 3) Kali 安装包较多，首次 apt 索引较大，需放宽下载重试，避免网络抖动直接失败。

[ -n "${SUITE}" ] || SUITE="kali-rolling"

if [ -z "${ARCH}" ]
then
    case "$(get_platform)" in
    x86) ARCH="i386" ;;
    x86_64) ARCH="amd64" ;;
    arm) ARCH="armhf" ;;
    arm_64) ARCH="arm64" ;;
    esac
fi

# 镜像源：默认官方；国内网络可在配置中改为镜像（如
# http://mirrors.ustc.edu.cn/kali/ 或 http://mirrors.tuna.tsinghua.edu.cn/kali/）
[ -n "${SOURCE_PATH}" ] || SOURCE_PATH="http://http.kali.org/kali/"

do_help()
{
cat <<EOF
   --arch="${ARCH}"
     Architecture of Linux distribution, supported "armel", "armhf", "arm64", "i386" and "amd64".

   --suite="${SUITE}"
     Version of Linux distribution, supported version "kali-rolling".

   --source-path="${SOURCE_PATH}"
     Installation source, can specify address of the repository or path to the rootfs archive.

   --extra-packages="${EXTRA_PACKAGES}"
     List of optional installation packages, separated by spaces.

EOF
}
