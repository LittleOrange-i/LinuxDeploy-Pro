#!/bin/sh
# Linux Deploy Component
# (c) Anton Skshidlevsky <meefik@gmail.com>, GPLv3

[ -n "${SUITE}" ] || SUITE="latest-stable"

if [ -z "${ARCH}" ]
then
    case "$(get_platform)" in
    x86) ARCH="x86" ;;
    x86_64) ARCH="x86_64" ;;
    arm) ARCH="armhf" ;;
    arm_64) ARCH="aarch64" ;;
    esac
fi
# Alpine 官方发布目录使用 aarch64 代号；即使配置中显式指定 arm64 也统一映射
case "${ARCH}" in
arm64) ARCH="aarch64" ;;
esac

[ -n "${SOURCE_PATH}" ] || SOURCE_PATH="http://dl-cdn.alpinelinux.org/alpine/"

apk_repository()
{
  # Backup repositories
  if [ -e "${CHROOT_DIR}/etc/apk/repositories" ]; then
      cp "${CHROOT_DIR}/etc/apk/repositories" "${CHROOT_DIR}/etc/apk/repositories.bak"
  fi
  # Update repositories
  echo "${SOURCE_PATH%/}/${SUITE}/main" > "${CHROOT_DIR}/etc/apk/repositories"
  echo "${SOURCE_PATH%/}/${SUITE}/community" >> "${CHROOT_DIR}/etc/apk/repositories"
}

apk_install()
{
    # mksh 的 local 不接受以 "$@" 直接赋值（会把包名当变量名报错）
    local packages
    packages="$@"
    [ -n "${packages}" ] || return 1
    (set -e
        chroot_exec -u root apk update || true
        chroot_exec -u root apk add ${packages}
    exit 0)
    return $?
}

do_install()
{
    is_archive "${SOURCE_PATH}" && return 0

    msg ":: 正在安装 ${COMPONENT} ... "

    msg -n "正在获取 rootfs 归档 ... "
    local repo_url="${SOURCE_PATH%/}/${SUITE}"
    local rootfs_name=$(wget -q -O - "${repo_url}/releases/${ARCH}/latest-releases.yaml" | grep -m1 "file: alpine-minirootfs" | awk '{print $2}')
    wget -q -O - "${repo_url}/releases/${ARCH}/${rootfs_name}" | tar xz -C "${CHROOT_DIR}"
    is_ok "失败" "完成" || return 1

    component_exec core/emulator core/mnt core/net

    msg -n "正在更新软件源 ... "
    apk_repository
    is_ok "失败" "完成"

    msg "正在安装软件包: "
    # 通用性：与 Debian 系对齐，补齐各组件会用到的常见工具。
    # - shadow：提供 useradd/chpasswd（core/profile、core/aid 依赖）
    # - sudo / tzdata：权限与时区（core/sudo、core/timezone）
    # - bash：脚本与交互默认 shell（ldstatus、终端优先使用）
    # - curl、wget、ca-certificates：包下载与 https 校验（各组件/用户常用）
    # - openssh-client：容器内可主动 ssh 出去（部分组件与用户习惯依赖）
    apk_install shadow sudo tzdata bash curl wget ca-certificates openssh-client ${EXTRA_PACKAGES}
    is_ok || return 1

    return 0
}

do_help()
{
cat <<EOF
   --arch="${ARCH}"
     Architecture of Linux distribution, supported "aarch64", "armhf", "x86" and "x86_64".

   --suite="${SUITE}"
     Version of Linux distribution, supported version "latest-stable", "edge".

   --source-path="${SOURCE_PATH}"
     Installation source, can specify address of the repository or path to the rootfs archive.

   --extra-packages="${EXTRA_PACKAGES}"
     List of optional installation packages, separated by spaces.

EOF
}
