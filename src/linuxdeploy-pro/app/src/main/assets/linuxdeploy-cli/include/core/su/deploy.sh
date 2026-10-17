#!/bin/sh
# Linux Deploy Component
# (c) Anton Skshidlevsky <meefik@gmail.com>, GPLv3

do_configure()
{
    msg ":: 正在配置 ${COMPONENT} ... "
    local item pam_su
    for item in /etc/pam.d/su /etc/pam.d/su-l
    do
        pam_su="${CHROOT_DIR}/${item}"
        if [ -e "${pam_su}" ]; then
            if ! $(grep -q '^auth.*sufficient.*pam_succeed_if.so uid = 0 use_uid quiet$' "${pam_su}"); then
                sed -i '1,/^auth/s/^\(auth.*\)$/auth\tsufficient\tpam_succeed_if.so uid = 0 use_uid quiet\n\1/' "${pam_su}"
            fi
        fi
    done
    # Alpine（BusyBox su / util-linux su，均无 PAM）：root 切换本身不受限制，
    # 无对应配置文件可改，直接跳过即可，不必报错。
    return 0
}
