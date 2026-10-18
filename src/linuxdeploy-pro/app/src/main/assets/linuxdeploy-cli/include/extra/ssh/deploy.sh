#!/bin/sh
# Linux Deploy Component
# (c) Anton Skshidlevsky <meefik@gmail.com>, GPLv3
#
# 各发行版 SSH 差异（修复“容器能启动但 22 端口连不上 / 输入密码被拒”）：
# 1) 配置入口不同：Debian 系在 /etc/ssh/sshd_config 里 Include sshd_config.d/*.conf，
#    后加载的片段会覆盖主文件；Alpine/Arch/Slackware 直接读主文件。
#    旧实现只改主文件，Debian/Ubuntu 官方镜像若带片段（如 PasswordAuthentication no）
#    仍会拒绝密码登录。这里主文件与片段统一处理。
# 2) 新版 OpenSSH（9.8+，如 Arch/Ubuntu 24.10+）默认不再启用 ssh-rsa 主机密钥算法，
#    老客户端连接直接报 “no matching host key type”。
# 3) Alpine/Arch 默认没有 /run/sshd 与 host key，需显式生成。
# 4) 监听失败时只报“已启动”，用户无法判断端口是否真的可用；这里启动后回读监听结果。

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

# sshd 是否可执行：容器内 sshd 缺失时（组件安装失败）早期直接静默“完成”，
# 用户只能看到端口不通。这里统一判定，供启动/状态使用。
sshd_ready()
{
    local p
    p=$(sshd_bin)
    [ -x "${CHROOT_DIR}${p}" ]
}

# host key 是否已生成（不依赖 key 文件名后缀：RSA/ECDSA/ED25519 均含 key 字样）
ssh_keys_ready()
{
    ls "${CHROOT_DIR}/etc/ssh/" 2>/dev/null | grep -q 'key$'
}

# 对单个 sshd 配置文件应用统一策略（幂等）
# $1=配置文件绝对路径（容器内路径）
ssh_config_file_apply()
{
    local cfg="$1"
    [ -f "${cfg}" ] || return 0
    # 端口与服务端鉴权：允许密码、允许 root（容器场景由用户自行决定密码强度）
    sed -i -E 's/^[[:space:]]*#?[[:space:]]*PasswordAuthentication[[:space:]].*/PasswordAuthentication yes/' "${cfg}" 2>/dev/null || true
    sed -i -E 's/^[[:space:]]*#?[[:space:]]*PermitRootLogin[[:space:]].*/PermitRootLogin yes/' "${cfg}" 2>/dev/null || true
    # 部分精简发行版模板默认禁止空密码账号，这里放宽（root 密码由 core/profile 设置）
    sed -i -E 's/^[[:space:]]*#?[[:space:]]*PermitEmptyPasswords[[:space:]].*/PermitEmptyPasswords yes/' "${cfg}" 2>/dev/null || true
    sed -i -E 's/^[[:space:]]*#?[[:space:]]*UsePAM[[:space:]].*/UsePAM yes/' "${cfg}" 2>/dev/null || true
    # 键盘交互认证：Debian 系模板显式写了 KbdInteractiveAuthentication no，
    # 部分客户端会优先协商该方式（UsePAM 下同样走 PAM 校验密码），关闭时
    # 表现为"能连上但密码被拒"。这里与密码认证一起放开，保证各发行版行为一致；
    # 旧版 OpenSSH（Ubuntu 20.04 等）用 ChallengeResponseAuthentication 同名选项。
    sed -i -E 's/^[[:space:]]*#?[[:space:]]*KbdInteractiveAuthentication[[:space:]].*/KbdInteractiveAuthentication yes/' "${cfg}" 2>/dev/null || true
    sed -i -E 's/^[[:space:]]*#?[[:space:]]*ChallengeResponseAuthentication[[:space:]].*/ChallengeResponseAuthentication yes/' "${cfg}" 2>/dev/null || true
    sed -i -E 's/^[[:space:]]*#?[[:space:]]*AcceptEnv[[:space:]].*/AcceptEnv LANG/' "${cfg}" 2>/dev/null || true
    # 端口写回配置文件（systemctl 模式经 ssh.service 启动时没有 -p 参数）
    sed -i -E 's/^[[:space:]]*#?[[:space:]]*Port[[:space:]].*/Port '"${SSH_PORT}"'/' "${cfg}" 2>/dev/null || true
    grep -q "^Port ${SSH_PORT}$" "${cfg}" 2>/dev/null || echo "Port ${SSH_PORT}" >> "${cfg}"
    # privsep 目录：新版 OpenSSH 需要 /run/sshd 存在且权限正确，否则 sshd 直接退出
    if grep -q "^UsePrivilegeSeparation" "${cfg}" 2>/dev/null; then
        sed -i -E 's/^[[:space:]]*#?[[:space:]]*UsePrivilegeSeparation[[:space:]].*/#UsePrivilegeSeparation sandbox/' "${cfg}"
    fi
    grep -q "^Subsystem" "${cfg}" 2>/dev/null || echo "Subsystem sftp /usr/lib/openssh/sftp-server" >> "${cfg}"
    # 旧客户端兼容：仅当配置里没显式声明 HostKeyAlgorithms 时追加（不覆盖用户自定义）
    if ! grep -q '^HostKeyAlgorithms' "${cfg}" 2>/dev/null; then
        echo "HostKeyAlgorithms +ssh-rsa,rsa-sha2-256,rsa-sha2-512" >> "${cfg}"
    fi
    return 0
}

# 把密码登录 / root 登录 / 端口写入 sshd_config 及其片段（部署与每次启动共用）
ssh_config_apply()
{
    local sshd_dir="${CHROOT_DIR}/etc/ssh"
    local sshd_config="${sshd_dir}/sshd_config"
    [ -e "${sshd_config}" ] || { msg "[提示] 容器内没有 ${sshd_config}，跳过 sshd 配置"; return 0; }
    # sshd 本体缺失（安装失败/精简镜像）时明确告警：否则后续只会表现为端口不通
    if ! sshd_ready; then
        msg "[警告] 容器内未找到 sshd（$(sshd_bin)），SSH 无法启动，请重新部署或执行包管理器安装 openssh-server"
    fi
    ssh_config_file_apply "${sshd_config}"
    # Include 片段：Debian/Ubuntu 官方 openssh-server 会放 sshd_config.d/*.conf，
    # 片段在 Include 处生效且优先级更高；不处理会出现“主文件已允许密码，仍被拒绝”。
    local inc
    for inc in "${sshd_dir}"/sshd_config.d/*.conf "${sshd_dir}"/ssh_config.d/*.conf
    do
        [ -f "${inc}" ] || continue
        ssh_config_file_apply "${inc}"
    done
    # 容器内没有 systemd 的运行目录时，sshd 的 privsep 目录缺失会直接启动失败
    make_dirs "${CHROOT_DIR}/run/sshd" "${CHROOT_DIR}/var/run/sshd" "${CHROOT_DIR}/var/empty"
    chmod 755 "${CHROOT_DIR}/run/sshd" "${CHROOT_DIR}/var/run/sshd" 2>/dev/null || true
    # root 的 authorized_keys：有的发行版模板带 AuthorizedKeysFile 相对路径，
    # 统一确保 ~/.ssh 存在且权限正确（否则公钥登录/部分客户端的密钥协商会告警）
    local root_ssh="${CHROOT_DIR}/root/.ssh"
    make_dirs "${root_ssh}"
    chmod 700 "${root_ssh}" 2>/dev/null || true
    [ -f "${root_ssh}/authorized_keys" ] || : > "${root_ssh}/authorized_keys"
    chmod 600 "${root_ssh}/authorized_keys" 2>/dev/null || true
    if ! ssh_keys_ready; then
        # Alpine/Arch 的 openssh 安装后不自带 host key，必须生成；失败时明确提示
        if ! chroot_exec -u root ssh-keygen -A >/dev/null 2>&1; then
            msg "[警告] host key 生成失败（容器内缺少 ssh-keygen），sshd 可能无法启动"
        fi
    fi
    # Debian/Ubuntu 的「不启动 sshd」标记文件：存在时 ssh.service 的条件检查失败、
    # sshd 永不启动（与 ssh 是否启用无关，属发行版遗留状态）
    if [ -e "${CHROOT_DIR}/etc/ssh/sshd_not_to_be_run" ]; then
        rm -f "${CHROOT_DIR}/etc/ssh/sshd_not_to_be_run"
        msg ":: 已移除 ${CHROOT_DIR}/etc/ssh/sshd_not_to_be_run（否则 sshd 不会启动）"
    fi
    return 0
}

# 检查容器内 sshd 是否真的在监听指定端口（/proc/net/tcp 为宿主视图，端口一致）
ssh_listening()
{
    local port_hex port
    port="${SSH_PORT:-22}"
    port_hex=$(printf '%04X' "${port}" 2>/dev/null)
    [ -n "${port_hex}" ] || return 1
    if [ -r "/proc/net/tcp" ]; then
        # 找到监听该端口的 socket inode 后，反查是否为容器内 sshd 进程持有；
        # 简化判断：容器内 sshd 在运行且存在该端口的 LISTEN 记录即视为成功。
        if awk -v p=":${port_hex}" '$4=="0A" && $2 ~ p"$" {found=1} END{exit !found}' /proc/net/tcp 2>/dev/null; then
            return 0
        fi
        # 部分内核把监听记录放在 tcp6
        if [ -r "/proc/net/tcp6" ] && awk -v p=":${port_hex}" '$4=="0A" && $2 ~ p"$" {found=1} END{exit !found}' /proc/net/tcp6 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

# 指定端口是否已被监听（宿主与容器共享网络命名空间，/proc/net/tcp 即宿主全局视图）。
# 用途：多容器场景下端口被"别的容器"占用时，本容器 sshd 无法绑定，
# 而用户 ssh 却会连到占用该端口的那个容器上（现象：能登录但环境/密码不对）。
ssh_port_in_use()
{
    local port_hex
    port_hex=$(printf '%04X' "${SSH_PORT:-22}" 2>/dev/null)
    [ -n "${port_hex}" ] || return 1
    local f
    for f in /proc/net/tcp /proc/net/tcp6; do
        [ -r "${f}" ] || continue
        awk -v p=":${port_hex}" '$4=="0A" && $2 ~ p"$" {found=1; exit} END{exit !found}' "${f}" && return 0
    done
    return 1
}

do_install()
{
    msg ":: 正在安装 ${COMPONENT} ... "
    local packages="" install_rc=0
    case "${DISTRIB}:${ARCH}:${SUITE}" in
    debian:*|ubuntu:*|kali:*)
        packages="openssh-server"
        [ "${METHOD}" = "proot" ] && packages="${packages} fakechroot"
        apt_install ${packages}; install_rc=$?
    ;;
    archlinux:*)
        packages="openssh"
        pacman_install ${packages}; install_rc=$?
    ;;
    fedora:*)
        packages="openssh-server"
        dnf_install ${packages}; install_rc=$?
    ;;
    centos:*)
        packages="openssh-server"
        yum_install ${packages}; install_rc=$?
    ;;
    slackware:*)
        packages="openssh"
        slackpkg_install ${packages}; install_rc=$?
    ;;
    alpine:*)
        # Alpine 的 openssh-server 不自带 host key 与 /etc/ssh 目录结构，
        # 用 openssh（sshd 本体）更稳妥
        packages="openssh"
        apk_install ${packages}; install_rc=$?
    ;;
    esac
    # 安装命令本身失败时直接报错：早期组件不检查返回值，部署会“成功”但 SSH 不可用
    if [ "${install_rc}" -ne 0 ]; then
        msg "[错误] ${COMPONENT} 软件包安装失败（退出码 ${install_rc}，包: ${packages}）"
        return 1
    fi
    # 安装结果回读：明确区分“没装上”与“装了但路径不在预期位置”
    if ! sshd_ready; then
        msg "[错误] ${COMPONENT} 安装后未找到 sshd（$(sshd_bin)），SSH 将无法使用"
        return 1
    fi
    return 0
}

do_configure()
{
    msg ":: 正在配置 ${COMPONENT} ... "
    ssh_config_apply
    # Alpine：OpenRC 的 sshd 服务默认不随 runlevel 启动，部署时 enable；
    # 交由 init/openrc 在容器启动时按 runlevels 拉起（不在此处直接起进程）。
    case "${DISTRIB}" in
    alpine)
        if [ -x "${CHROOT_DIR}/etc/init.d/sshd" ]; then
            chroot_exec -u root rc-update add sshd default >/dev/null 2>&1 || true
            msg ":: 已将 sshd 加入 OpenRC default runlevel"
        fi
    ;;
    esac
    # 注：systemctl 模式下 ssh.service 的 enable 由 init/systemctl 组件在 start
    # 拉起 --init 前统一执行，此处不再调用 python systemctl。
    return 0
}

do_start()
{
    msg -n ":: Starting ${COMPONENT} ... "
    # 每次启动重新应用一次 sshd 配置（端口 / 密码登录 / root 登录 / 键盘交互 /
    # privsep 目录 / host key）：do_configure 只在部署时执行，历史容器、
    # 或"改了密码/端口后重启容器"的场景需要靠这里兜底。旧实现仅 systemctl
    # 模式生效，sysv/run-parts/OpenRC 下配置不刷新（表现为改了密码仍连不上）。
    ssh_config_apply >/dev/null 2>&1
    # systemctl 模式：ssh 由 systemctl 管理（ssh.service / sshd.service），CLI 不直启
    if [ "${INIT}" = "systemctl" ]; then
        msg "跳过（systemctl 模式：ssh 由 systemctl 管理，端口 ${SSH_PORT} 已写入 sshd_config）"
        return 0
    fi
    # 已由 init（sysv/run-parts/openrc）拉起的 sshd 不重复启动
    if sshd_running; then
        msg "跳过（sshd 已在运行）"
        return 0
    fi
    # 端口占用检查（多容器场景）：所有容器共享宿主网络命名空间，
    # 端口被"其它容器或宿主服务"占用时本容器 sshd 无法绑定，而用户 ssh
    # 会连到占用该端口的那个容器上（现象：能登录但环境/密码不对）。
    # 这里提前明确告警，避免用户误以为"本容器 SSH 正常"。
    if ssh_port_in_use; then
        msg "端口冲突"
        msg "[警告] SSH 端口 ${SSH_PORT} 已被监听（可能是其它容器或宿主服务）"
        msg "        本容器 sshd 无法绑定该端口；请到配置页把本容器端口改成其它值后重新启动"
        msg "        （每个容器必须使用不同端口，避免连到别的容器）"
    fi
    # OpenRC 容器：交给 rc-service 启动（能正确管理 pid 与依赖），不直接裸起 sshd
    if [ "${INIT}" = "openrc" ] && [ -x "${CHROOT_DIR}/etc/init.d/sshd" ]; then
        chroot_exec -u root rc-service sshd start >/dev/null 2>&1 || true
        if sshd_running; then
            msg "完成（OpenRC 已启动 sshd）"
            return 0
        fi
    fi
    make_dirs "${CHROOT_DIR}/run/sshd" "${CHROOT_DIR}/var/run/sshd"
    local sshd
    sshd=$(sshd_bin)
    # sysv/run-parts 模式下若 rc 脚本未启动 ssh，这里兜底直接拉起
    if [ "${METHOD}" = "proot" ]; then
        chroot_exec -u root fakechroot ${sshd} -p ${SSH_PORT} ${SSH_ARGS} &
    else
        # -D 前台运行并后台化到宿主：由 CLI 子 shell 承接，不依赖容器内 init
        chroot_exec -u root /bin/sh -c "setsid ${sshd} -D -p ${SSH_PORT} ${SSH_ARGS} </dev/null >/dev/null 2>&1 &"
    fi
    # 等待端口就绪并回读真实结果（避免“显示已完成，实际未监听”）
    local i=0
    while [ ${i} -lt 20 ]; do
        sshd_running && break
        sleep 0.5
        i=$((i+1))
    done
    if sshd_running; then
        if ssh_listening; then
            msg "完成（端口 ${SSH_PORT} 已监听）"
        else
            msg "完成（sshd 已运行，端口 ${SSH_PORT} 监听状态待确认）"
        fi
    else
        msg "失败"
        msg "[提示] sshd 未能启动：可在终端执行 ${sshd} -D -p ${SSH_PORT} 查看具体报错。"
        msg "        常见原因：host key 缺失（执行 ssh-keygen -A）、端口被占用、配置语法错误。"
    fi
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
