#!/bin/sh
# Linux Deploy Component
# (c) Anton Skshidlevsky <meefik@gmail.com>, GPLv3

[ -n "${SSH_PORT}" ] || SSH_PORT="22"

# sshd 路径因发行版而异：Debian 系在 /usr/sbin，Alpine/Arch 部分版本在 /sbin。
sshd_bin()
{
    local p
    for p in /usr/sbin/sshd /usr/bin/sshd /sbin/sshd /bin/sshd; do
        [ -x "${CHROOT_DIR}${p}" ] && { echo "${p}"; return 0; }
    done
    echo "/usr/sbin/sshd"
}

# host key 是否已生成（不依赖 key 文件名后缀：RSA/ECDSA/ED25519 均含 key 字样）
ssh_keys_ready()
{
    ls "${CHROOT_DIR}/etc/ssh/" 2>/dev/null | grep -q 'key$'
}

# 把密码登录 / root 登录 / 端口写入 sshd_config（部署与每次启动共用）
ssh_config_apply()
{
    local sshd_config="${CHROOT_DIR}/etc/ssh/sshd_config"
    [ -e "${sshd_config}" ] || { msg "[提示] 容器内没有 ${sshd_config}，跳过 sshd 配置"; return 0; }
    sed -i -E 's/#?PasswordAuthentication .*/PasswordAuthentication yes/g' "${sshd_config}" 2>/dev/null || true
    sed -i -E 's/#?PermitRootLogin .*/PermitRootLogin yes/g' "${sshd_config}" 2>/dev/null || true
    sed -i -E 's/#?AcceptEnv .*/AcceptEnv LANG/g' "${sshd_config}" 2>/dev/null || true
    # 端口写入 sshd_config（systemctl 模式经 ssh.service 启动 sshd 时无 -p 参数，走配置端口）
    sed -i -E 's/^#?Port .*/Port '"${SSH_PORT}"'/' "${sshd_config}" 2>/dev/null || true
    grep -q "^Port " "${sshd_config}" 2>/dev/null || echo "Port ${SSH_PORT}" >> "${sshd_config}"
    # 容器内没有 systemd 的运行目录时，sshd 的 privsep 目录缺失会直接启动失败
    make_dirs "${CHROOT_DIR}/run/sshd" "${CHROOT_DIR}/var/run/sshd"
    if ! ssh_keys_ready; then
        chroot_exec -u root ssh-keygen -A >/dev/null 2>&1 || true
    fi
    # Debian/Ubuntu 的「不启动 sshd」标记文件：存在时 ssh.service 的条件检查失败、
    # sshd 永不启动（与 ssh 是否启用无关，属发行版遗留状态）
    if [ -e "${CHROOT_DIR}/etc/ssh/sshd_not_to_be_run" ]; then
        rm -f "${CHROOT_DIR}/etc/ssh/sshd_not_to_be_run"
        msg ":: 已移除 ${CHROOT_DIR}/etc/ssh/sshd_not_to_be_run（否则 sshd 不会启动）"
    fi
    return 0
}

do_install()
{
    msg ":: 正在安装 ${COMPONENT} ... "
    local packages=""
    case "${DISTRIB}:${ARCH}:${SUITE}" in
    debian:*|ubuntu:*|kali:*)
        packages="openssh-server"
        [ "${METHOD}" = "proot" ] && packages="${packages} fakechroot"
        apt_install ${packages}
    ;;
    archlinux:*)
        packages="openssh"
        pacman_install ${packages}
    ;;
    fedora:*)
        packages="openssh-server"
        dnf_install ${packages}
    ;;
    centos:*)
        packages="openssh-server"
        yum_install ${packages}
    ;;
    slackware:*)
        packages="openssh"
        slackpkg_install ${packages}
    ;;
    alpine:*)
        packages="openssh-server"
        apk_install ${packages}
    ;;
    esac
}

do_configure()
{
    msg ":: 正在配置 ${COMPONENT} ... "
    ssh_config_apply
    # 注：ssh.service 的 enable 由 init/systemctl 组件在 start 拉起 --init 前统一执行，
    # 此处不再调用 python systemctl（部署期调用曾导致进程异常终止）。
    return 0
}

do_start()
{
    msg -n ":: Starting ${COMPONENT} ... "
    # systemctl 模式：ssh 由 systemctl 管理（ssh.service / sshd.service），CLI 不直启
    if [ "${INIT}" = "systemctl" ]; then
        # 端口/密钥/privsep 目录在每次启动也应用（do_configure 仅部署时执行，老容器靠此兜底）
        ssh_config_apply >/dev/null 2>&1
        msg "跳过（systemctl 模式：ssh 由 systemctl 管理，端口 ${SSH_PORT} 已写入 sshd_config）"
        return 0
    fi
    # 已由 init（sysv/run-parts）拉起的 sshd 不重复启动
    if sshd_running; then
        msg "跳过（sshd 已在运行）"
        return 0
    fi
    make_dirs /run/sshd /var/run/sshd
    local sshd
    sshd=$(sshd_bin)
    # exec sshd
    if [ "${METHOD}" = "proot" ]; then
        chroot_exec -u root fakechroot ${sshd} -p ${SSH_PORT} ${SSH_ARGS} &
    else
        chroot_exec -u root ${sshd} -p ${SSH_PORT} ${SSH_ARGS}
    fi
    is_ok "失败" "完成"
    return 0
}

do_stop()
{
    msg -n ":: Stopping ${COMPONENT} ... "
    # 先按 pid 文件（各发行版位置不同），残留的 sshd 统一由 kill_pids 兜底收尾
    kill_pids /run/sshd.pid /var/run/sshd.pid
    is_ok "失败" "完成"
    return 0
}

do_status()
{
    msg -n ":: ${COMPONENT} ... "
    # 按容器目录匹配 sshd 进程（systemctl 模式由 init 拉起，无固定 pid 文件）
    if sshd_running; then
        msg "已启动"
    else
        msg "已停止"
    fi
    return 0
}

do_help()
{
cat <<EOF
   --ssh-port="${SSH_PORT}"
     Port of SSH server.

   --ssh-args="${SSH_ARGS}"
     Defines other sshd options, separated by a space.

EOF
}
