#!/bin/sh
# Linux Deploy Component
# (c) Anton Skshidlevsky <meefik@gmail.com>, GPLv3

do_configure()
{
    msg ":: 正在配置 ${COMPONENT} ... "
    local sudo_str="${USER_NAME} ALL=(ALL:ALL) NOPASSWD:ALL"
    # Alpine 默认不带 sudo（也没装 doas）：非 root 用户登录后无法提权。
    # 这里在容器内补装 sudo；失败不阻断（root 用户不受影响，SSH 可正常登录）。
    if [ "${DISTRIB}" = "alpine" ] && [ ! -x "${CHROOT_DIR}/usr/bin/sudo" ] && [ ! -x "${CHROOT_DIR}/bin/sudo" ]; then
        apk_install sudo >/dev/null 2>&1 || msg "[提示] Alpine 容器内 sudo 安装失败（非 root 用户将无法提权）"
    fi
    # sudoers 文件可能不存在（精简发行版/未安装 sudo 的镜像），先确保目录与文件就绪
    if [ ! -e "${CHROOT_DIR}/etc/sudoers" ]; then
        mkdir -p "${CHROOT_DIR}/etc"
        : > "${CHROOT_DIR}/etc/sudoers"
    fi
    if ! grep -q "${sudo_str}" "${CHROOT_DIR}/etc/sudoers"; then
        chmod 640 "${CHROOT_DIR}/etc/sudoers"
        echo ${sudo_str} >> "${CHROOT_DIR}/etc/sudoers"
        chmod 440 "${CHROOT_DIR}/etc/sudoers"
    fi
    if [ -e "${CHROOT_DIR}/etc/profile.d" ]; then
        echo '[ -n "$PS1" -a "$(whoami)" = "'${USER_NAME}'" ] || return 0' > "${CHROOT_DIR}/etc/profile.d/sudo.sh"
        echo 'alias su="sudo su"' >> "${CHROOT_DIR}/etc/profile.d/sudo.sh"
    fi
    return 0
}
