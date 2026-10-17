#!/bin/sh
# Linux Deploy Component
# (c) Anton Skshidlevsky <meefik@gmail.com>, GPLv3

do_configure()
{
    msg ":: 正在配置 ${COMPONENT} ... "
    local sudo_str="${USER_NAME} ALL=(ALL:ALL) NOPASSWD:ALL"
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
