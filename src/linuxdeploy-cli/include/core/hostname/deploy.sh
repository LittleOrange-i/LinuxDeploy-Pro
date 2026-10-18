#!/bin/sh
# Linux Deploy Component
# (c) Anton Skshidlevsky <meefik@gmail.com>, GPLv3

do_install()
{
    msg ":: 正在安装 ${COMPONENT} ... "
    # 兜底保护：正常部署时本组件已在 bootstrap 之后执行（见 cli.sh deploy 分支
    # 的两段式执行），但若通过 component_exec 单独调用而 rootfs 尚未安装，
    # 此时容器内没有包管理器，chroot/apt 会直接卡死。
    # 引导阶段已把 hostname 打包进基础系统（见 bootstrap/*/deploy.sh 的
    # BASE_INCLUDE_PACKAGES），仅在容器已可用时兜底补装。
    if [ ! -x "${CHROOT_DIR}/bin/sh" ] && [ ! -x "${CHROOT_DIR}/usr/bin/sh" ]; then
        msg "容器系统尚未安装，跳过（hostname 随引导组件一并安装）"
        return 0
    fi
    local packages=""
    case "${DISTRIB}:${ARCH}:${SUITE}" in
    debian:*|ubuntu:*|kali:*)
        # Debian 系：必须真正调用安装函数，旧实现只赋值未安装，
        # 容器内缺失 hostname 命令且无任何提示（部署日志只剩"正在配置"）
        packages="hostname"
        apt_install ${packages}
    ;;
    archlinux:*)
        # Arch 没有独立 hostname 包：命令由 inetutils 提供，直接 install 会报
        # "target not found: hostname"，导致整个组件失败
        packages="inetutils"
        pacman_install ${packages}
    ;;
    fedora:*)
        packages="hostname"
        dnf_install ${packages}
    ;;
    centos:*)
        packages="hostname"
        yum_install ${packages}
    ;;
    slackware:*)
        # Slackware 的 hostname 在 net-tools 包内，没有同名包
        packages="net-tools"
        slackpkg_install ${packages}
    ;;
    alpine:*)
        # Alpine 的 hostname 由 busybox 提供，无需安装
        return 0
    ;;
    esac
    # 安装失败只提示不中断：容器主机名主要由 /etc/hostname 决定（见 do_configure），
    # 缺少 hostname 命令不影响 SSH 与系统运行
    return 0
}
do_configure()
{
    msg ":: 正在配置 ${COMPONENT} ... "
    echo ${HOST_NAME} > "${CHROOT_DIR}/etc/hostname"
    return 0
}

do_start()
{
    # chroot 下调用 hostname 会直接作用于宿主系统主机名，且非 root 用户通常无权限，
    # 容器主机名由 /etc/hostname 文件管理（见 do_configure），启动时无需额外操作。
    msg ":: 启动 ${COMPONENT}: chroot 中主机名由 /etc/hostname 管理，跳过"
    return 0
}

do_stop()
{
    # 停止时同样无需重置主机名（避免影响宿主系统）。
    msg ":: 停止 ${COMPONENT}: chroot 中无需重置主机名，跳过"
    return 0
}
