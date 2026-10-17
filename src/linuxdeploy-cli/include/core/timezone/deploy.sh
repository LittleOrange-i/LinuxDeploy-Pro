#!/bin/sh
# Linux Deploy Component
# (c) Anton Skshidlevsky <meefik@gmail.com>, GPLv3

do_configure()
{
    msg ":: 正在配置 ${COMPONENT} ... "
    local timezone
    if [ -n "$(which getprop)" ]; then
        timezone=$(getprop persist.sys.timezone)
    elif [ -e "/etc/timezone" ]; then
        timezone=$(cat /etc/timezone)
    fi
    if [ -n "${timezone}" ]; then
        # 优先用符号链接（Alpine/Arch 原生做法）；zoneinfo 缺失时直接跳过，
        # 避免把容器 /etc/localtime 写成空文件或顺着已有软链写坏目标
        if [ -e "${CHROOT_DIR}/usr/share/zoneinfo/${timezone}" ]; then
            rm -f "${CHROOT_DIR}/etc/localtime"
            ln -sf "/usr/share/zoneinfo/${timezone}" "${CHROOT_DIR}/etc/localtime" 2>/dev/null \
                || cp -f "${CHROOT_DIR}/usr/share/zoneinfo/${timezone}" "${CHROOT_DIR}/etc/localtime"
            # Debian 系写 /etc/timezone；Alpine/Arch 无此文件时一并创建（无害且便于保持一致）
            echo "${timezone}" > "${CHROOT_DIR}/etc/timezone"
        else
            msg "[跳过] 容器内缺少时区文件 /usr/share/zoneinfo/${timezone}（可安装 tzdata）"
        fi
    fi
    return 0
}
