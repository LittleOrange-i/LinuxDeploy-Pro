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
# 5) 安卓容器内无 systemd/audit：/etc/pam.d/sshd 的 pam_loginuid 写 loginuid
#    失败，表现为“密码验证成功后连接立即被关闭/重置”（pam_open_session 中止）。
#    这里把 pam_loginuid 降级为 optional（Docker 官方镜像同款处理）。

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

# 容器内 sshd 的主版本号（如 8 / 9 / 10），取不到时输出空串。
# 用途：OpenSSH 9.8 起才把会话处理拆成独立的 sshd-session（放在
# /usr/lib/openssh 或 /usr/sbin 下），更早的版本根本没有该文件——
# 早期实现只看“sshd 存在 且 /usr/lib/openssh 存在 且 sshd-session 不存在”
# 就告警，导致 Debian 11/12、Ubuntu 20.04/22.04、Kali、Alpine、Arch、
# Fedora、CentOS、Slackware 等所有 <9.8 的发行版每次都误报“请重装
# openssh-server”，属纯噪音。
sshd_major_version()
{
    local p ver
    p=$(sshd_bin)
    [ -x "${CHROOT_DIR}${p}" ] || return 1
    # sshd -V 输出到 stderr（不同版本格式略有差异：OpenSSH_8.2p1 / OpenSSH_9.8）
    ver=$(chroot_exec "${p}" -V 2>&1 | tr '\n' ' ' | sed -n 's/.*OpenSSH_\([0-9][0-9]*\).*/\1/p' | head -1)
    [ -n "${ver}" ] || return 1
    echo "${ver}"
}

# 会话组件是否就位（仅 OpenSSH 9.8+ 需要；不同发行版放置目录不同）
ssh_session_ready()
{
    local d
    for d in /usr/lib/openssh/sshd-session /usr/libexec/openssh/sshd-session \
             /usr/sbin/sshd-session /usr/bin/sshd-session /usr/lib/ssh/sshd-session
    do
        [ -e "${CHROOT_DIR}${d}" ] && return 0
    done
    return 1
}

# sshd 配置自检：用 sshd -t 让 sshd 自己校验 host key / privsep 目录 / 配置语法。
# 比“猜某个文件缺不缺”可靠：任何发行版、任何版本的安装残缺都会在这里暴露，
# 且不会误报。仅告警不中断（容器仍可启动，用户可据此补装）。
ssh_config_selftest()
{
    sshd_ready || return 0
    local p out
    p=$(sshd_bin)
    if ! out=$(chroot_exec "${p}" -t 2>&1); then
        msg "[警告] sshd 配置自检未通过（${p} -t）："
        printf '%s\n' "${out}" | sed -n '1,5p' | while IFS= read -r _line; do
            [ -n "${_line}" ] && msg "        ${_line}"
        done
        msg "        常见原因：host key 缺失、/run/sshd 权限异常；可在容器内重装 openssh-server 修复"
    fi
    return 0
}

# OpenSSH 9.8+ 的会话组件缺失时，先在容器内就地重装一次 openssh-server；
# 仍缺失才告警（此时说明镜像源里就是残缺包，需要用户换源/手动处理）。
ssh_session_repair()
{
    sshd_ready || return 0
    local major
    major=$(sshd_major_version)
    # 取不到版本时按需要判定（宁可多做一次会话组件检查，也不能漏掉真实缺失）
    if [ -n "${major}" ] && [ "${major}" -lt 9 ]; then
        return 0
    fi
    ssh_session_ready && return 0
    msg -n ":: 未检测到 SSH 会话组件（sshd-session），正在容器内修复 ... "
    local ok=1
    case "${DISTRIB}" in
    debian|ubuntu|kali) apt_install --reinstall openssh-server && ok=0 ;;
    fedora)             dnf_install --allowerasing openssh-server && ok=0 ;;
    centos)             yum_install --allowerasing openssh-server && ok=0 ;;
    archlinux)          pacman_install openssh && ok=0 ;;
    alpine)             apk_install --force-overwrite openssh && ok=0 ;;
    slackware)          slackpkg_install openssh && ok=0 ;;
    esac
    if [ ${ok} -eq 0 ] && ssh_session_ready; then
        msg "完成"
        return 0
    fi
    msg "未修复"
    msg "[警告] 容器内缺少 SSH 会话组件 sshd-session（OpenSSH ${major:-9.8+}），自动重装后仍未找到。"
    msg "        SSH 会话可能建立失败，请在容器内执行包管理器重装 openssh-server（或更换软件源后重新部署）"
    return 1
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
    # PAM 会话加固：容器内没有 systemd/audit 子系统，Debian 系 /etc/pam.d/sshd 里的
    # `session required pam_loginuid.so` 在安卓内核上写 /proc/self/loginuid 会以
    # EPERM 失败，导致“密码验证成功后连接立即被服务端关闭/重置”
    # （sshd 在 pam_open_session 阶段中止会话，客户端表现为 Connection closed by
    #  remote host）。同类的 pam_systemd 也一并降级；且每次启动都重做一次，
    # 防止 apt 升级/重装 openssh-server 后配置被还原。
    ssh_session_harden
    # OpenSSH 9.8+ 把会话处理拆分到独立二进制 sshd-session：安装不完整时表现为
    # “TCP 能连上、甚至能输密码，但会话建立立即失败”。
    # 判定必须结合容器内 sshd 的实际版本——<9.8 的发行版（Ubuntu 20.04 的 8.2p1、
    # Debian 11/12 的 8.4/9.2、Alpine、Arch 老镜像等）本来就没有该文件，
    # 旧实现只检查文件存在性，导致所有这类容器都误报“请重装 openssh-server”。
    # 现在：版本 <9 直接跳过；≥9 才检查，缺失时先自动重装一次再告警。
    ssh_session_repair
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

# sshd 运行期会话加固（部署与每次启动共用，幂等）。
# 现象：客户端能连上、能正常输入密码（服务端已通过认证），随即被服务端关闭：
#   “Connection to x closed by remote host.”
# 说明失败发生在认证之后的会话建立阶段（pam_open_session / 写 utmp / 会话组件），
# 与密码无关。容器与真机的差异有三处，逐条兜住：
#
# 1) audit 子系统缺失：pam_loginuid 写 /proc/self/loginuid 失败，
#    `session required pam_loginuid.so` 直接让会话中止。
#    → 降级为 optional（Docker 官方 openssh 镜像同款处理）。
# 2) systemd-logind 不可用：pam_systemd 调 logind 注册会话超时/失败，
#    旧版 libpam-systemd 在容器内返回错误会让 pam_open_session 失败。
#    → 降级为 optional。
# 3) 发行版差异导致 ubuntu（含 Debian）不同版本写 pam 配置写法不同：
#    `session required pam_loginuid.so` 之外还有 `session optional pam_loginuid.so`
#    与 `@include`/`include` 公共片段，两个文件都要处理。
# 另外 sshd 非会话相关的两类失败也一并兜住：
#   - /run/sshd 与 /var/empty 权限：新版 OpenSSH 要求严格权限，否则会话建立失败；
#   - 用户登录 shell 不存在（Slackware/Alpine 精简镜像常见）：sshd 认证通过后
#     启动 shell 失败并立即断开 → 补一个可用 shell。
ssh_session_harden()
{
    # 统一用 `local 名; 名=$(...)` 的写法：mksh 下 local x=$(...) 会报
    # “typeset: ... is not an identifier” 并让变量为空（会话加固整体失效）。
    local pam_f d user home shell cand picked
    for pam_f in "${CHROOT_DIR}/etc/pam.d/sshd" "${CHROOT_DIR}"/etc/pam.d/common-session \
                 "${CHROOT_DIR}"/etc/pam.d/common-session-noninteractive
    do
        [ -f "${pam_f}" ] || continue
        # 注意：必须用 BRE（不带 -E、分组写 \( \)）改写。
        # 设备端是 Android toybox 的 sed，`-E` 下的分组/反向引用会直接报
        # “bad regex: parentheses not balanced” 且退出码非 0——旧实现把错误
        # 用 2>/dev/null 吞掉，日志里还照常打印“已降级”，实际配置完全没改，
        # 于是 SSH 认证通过后会话仍被 pam_loginuid 中止。
        # 这里去掉 -E 并把 "required/requisite" 用 BRE 分支写法匹配，
        # 替换文本也不再引用分组（保留原缩进不变）。
        if grep -Eq '^[[:space:]]*session[[:space:]]+(required|requisite)[[:space:]]+pam_loginuid\.so' "${pam_f}" 2>/dev/null; then
            sed -i 's/^\([[:space:]]*session[[:space:]][[:space:]]*\)required[[:space:]][[:space:]]*pam_loginuid\.so/\1optional pam_loginuid.so/' "${pam_f}"
            sed -i 's/^\([[:space:]]*session[[:space:]][[:space:]]*\)requisite[[:space:]][[:space:]]*pam_loginuid\.so/\1optional pam_loginuid.so/' "${pam_f}"
            msg ":: 已将 ${pam_f#"${CHROOT_DIR}"} 的 pam_loginuid 降级为 optional（容器内无 audit 子系统）"
        fi
        # pam_systemd：sshd 在认证通过后会调用 pam_setcred(PAM_ESTABLISH_CRED)，
        # 该模块尝试连接 D-Bus 注册会话，容器内没有 systemd/logind
        # （auth.log: pam_systemd(sshd:session): Failed to connect to system bus），
        # 返回错误后 sshd 打印 fatal: PAM: pam_setcred(): Failure setting user
        # credentials 并关闭连接。注意：把它降级为 optional **不够**——
        # 失败发生在 setcred 阶段，与 session 的 required/optional 无关，
        # 必须整行注释掉（容器内本就没有 logind，功能为零）。
        # 真机实测：注释后 session opened 与 session closed 正常间隔（可保持会话），
        # 不注释时 session opened/closed 出现在同一秒。
        if grep -Eq '^[[:space:]]*session[^#]*pam_systemd\.so' "${pam_f}" 2>/dev/null; then
            sed -i 's/^\([[:space:]]*session.*pam_systemd\.so.*\)$/#\1/' "${pam_f}"
            msg ":: 已禁用 ${pam_f#"${CHROOT_DIR}"} 的 pam_systemd（容器内无 D-Bus/logind）"
        fi
        # pam_selinux：sshd 在认证通过后的 setcred 阶段调用 pam_selinux，
        # 安卓容器没有 SELinux 用户态（/sys/fs/selinux 不可用、也没有
        # /etc/selinux 策略），模块返回错误 → sshd 打印
        #   PAM: pam_setcred(): Failure setting user credentials
        # 并立刻 do_cleanup，客户端表现为“密码正确但连接被重置”。
        # 真机实测（Ubuntu 20.04 + OpenSSH 8.2）：仅注释这两行即可正常登录。
        # 容器内 SELinux 本来就不生效，直接注释（幂等，已注释则跳过）。
        if grep -Eq '^[[:space:]]*session[^#]*pam_selinux\.so' "${pam_f}" 2>/dev/null; then
            sed -i 's/^\([[:space:]]*session.*pam_selinux\.so.*\)$/#\1/' "${pam_f}"
            msg ":: 已禁用 ${pam_f#"${CHROOT_DIR}"} 的 pam_selinux（容器内无 SELinux 用户态，否则 setcred 失败导致 SSH 断开）"
        fi
    done

    # ---- pam_unix 的 nullok_secure（keyboard-interactive 登录必失败的真凶）----
    # 现象：Windows/Linux 的 ssh 客户端默认优先协商 keyboard-interactive，
    # 认证阶段能通过（auth.log: Accepted keyboard-interactive/pam），紧接着
    #   fatal: PAM: pam_setcred(): Failure setting user credentials
    # 连接被断开；而 paramiko 等强制走 password 认证的客户端却正常。
    # 原因：Ubuntu/Debian 的 /etc/pam.d/common-auth 里写的是
    #   auth [success=1 default=ignore] pam_unix.so nullok_secure
    # nullok_secure 要求“空密码只允许在安全 tty 上”，模块会去读 /etc/securetty
    # 并校验 tty 名；容器里既没有 /etc/securetty，tty 又是 "ssh"，
    # 该路径在 kbdint 认证后留下坏的凭据上下文，setcred 直接返回 PAM_CRED_ERR。
    # 修复：去掉 nullok_secure（容器内 root 密码由 core/profile 设置，不需要
    # 空密码例外），并补一个最小的 /etc/securetty，双保险覆盖不同 PAM 版本。
    local ca_f
    for ca_f in "${CHROOT_DIR}/etc/pam.d/common-auth"
    do
        [ -f "${ca_f}" ] || continue
        if grep -Eq 'nullok_secure' "${ca_f}" 2>/dev/null; then
            # BRE：删掉 nullok_secure 及其前面的空白（保留 pam_unix.so 的其它参数）。
            # 注意不能假设固定几个空格：Debian/Ubuntu 模板通常写两个空格，
            # 但不同版本/用户改过的配置可能只有一个，用 [:+space:]* 更稳。
            sed -i 's/[[:space:]][[:space:]]*nullok_secure//' "${ca_f}"
            sed -i 's/nullok_secure[[:space:]]*//' "${ca_f}"
            msg ":: 已移除 ${ca_f#"${CHROOT_DIR}"} 的 nullok_secure（否则 keyboard-interactive 登录后 pam_setcred 失败）"
        fi
    done
    # /etc/securetty：pam_unix 在 nullok_secure / securetty 校验时读取；
    # 缺失会让 pam_unix 持续打印 "Couldn't open /etc/securetty"。
    if [ ! -e "${CHROOT_DIR}/etc/securetty" ]; then
        {
            echo "# linuxdeploy: 容器内允许 root 登录的 tty（pam_unix securetty 校验用）"
            echo "console"
            echo "tty1"
            echo "tty2"
            echo "pts/0"
            echo "pts/1"
            echo "pts/2"
            echo "pts/3"
            echo "ssh"
        } > "${CHROOT_DIR}/etc/securetty" 2>/dev/null || true
        chmod 644 "${CHROOT_DIR}/etc/securetty" 2>/dev/null || true
    fi

    # privsep 目录权限：sshd 对 /run/sshd 与 /var/empty 的所有者/权限有硬性要求
    # （必须 root，且不可被组/其他用户写），否则 9.x 起直接在会话阶段拒绝。
    for d in /run/sshd /var/run/sshd /var/empty
    do
        make_dirs "${CHROOT_DIR}${d}"
        chown 0:0 "${CHROOT_DIR}${d}" 2>/dev/null || true
        chmod 755 "${CHROOT_DIR}${d}" 2>/dev/null || true
    done

    # 登录 shell 兜底：sshd 认证通过后要 exec 用户的登录 shell，
    # shell 不存在或在容器内不可执行时，sshd 立即断开连接。
    user="${USER_NAME:-root}"
    home=$(user_home "${user}")
    shell=$(user_field "${user}" 7)
    picked=""
    case "${shell}" in
    ''|/bin/false|/usr/bin/false|/sbin/nologin|/usr/sbin/nologin) picked="need" ;;
    *)
        [ -x "${CHROOT_DIR}${shell}" ] || picked="need"
    ;;
    esac
    if [ "${picked}" = "need" ]; then
        for cand in /bin/bash /usr/bin/bash /bin/ash /bin/sh /usr/bin/sh
        do
            if [ -x "${CHROOT_DIR}${cand}" ]; then picked="${cand}"; break; fi
        done
        [ "${picked}" != "need" ] || picked=""
        if [ -n "${picked}" ]; then
            msg ":: ${user} 的登录 shell 为 ${shell:-空}（不可用），已修正为 ${picked}（否则 SSH 登录后立即断开）"
            chroot_exec usermod -s "${picked}" "${user}" >/dev/null 2>&1 \
                || sed -i "s|^\(${user}:.*:\)[^:]*$|\1${picked}|" "${CHROOT_DIR}/etc/passwd" 2>/dev/null || true
        fi
    fi
    # 家目录必须存在（sshd 某些配置会在登录前 chdir 到 home）
    if [ -n "${home}" ] && [ "${home}" != "/" ] && [ "${home}" != "/nonexistent" ]; then
        make_dirs "${CHROOT_DIR}${home}"
        chown -R "${user}:${user}" "${CHROOT_DIR}${home}" 2>/dev/null \
            || chown -R 0:0 "${CHROOT_DIR}${home}" 2>/dev/null || true
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
    # 配置自检：让 sshd 自己校验（host key / privsep / 语法），
    # 覆盖所有发行版，避免“装上了但起不来”拖到用户连 SSH 时才发现。
    ssh_config_selftest
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
    # 安装期确定性启用 ssh 服务（不依赖任何 systemctl 实现，幂等）：
    # 部署期组件顺序是 init/systemctl 先于 extra/ssh —— 走到这里时容器内的
    # /usr/bin/systemctl 已被换成 python 假实现，openssh-server 安装脚本里
    # deb-systemd-helper 的 `systemctl preset` 落在假实现上会返回失败
    # （实测部署日志：deb-systemd-helper: error: systemctl preset failed on
    #  ssh.service），ssh.service 在安装期没有被启用。此前唯一的兜底是“启动时
    # systemctl enable”（2>/dev/null || true，失败无任何日志），一旦失败，
    # init 的 default.target 里就没有 ssh —— 容器启动后 sshd 永不运行，
    # 表现为“部署成功但 SSH 无法登录”。这里直接落 wants 软链，
    # 让启用动作不依赖 preset/enable 命令是否可用。
    local unit unit_f
    for unit in ssh.service sshd.service; do
        unit_f=""
        if [ -e "${CHROOT_DIR}/usr/lib/systemd/system/${unit}" ]; then
            unit_f="/usr/lib/systemd/system/${unit}"
        elif [ -e "${CHROOT_DIR}/lib/systemd/system/${unit}" ]; then
            unit_f="/lib/systemd/system/${unit}"
        fi
        [ -n "${unit_f}" ] || continue
        # 仅启用声明了 WantedBy 的 unit（static 单元落链无意义）
        grep -q '^WantedBy=' "${CHROOT_DIR}${unit_f}" 2>/dev/null || continue
        make_dirs "${CHROOT_DIR}/etc/systemd/system/multi-user.target.wants"
        if [ ! -e "${CHROOT_DIR}/etc/systemd/system/multi-user.target.wants/${unit}" ]; then
            ln -sf "${unit_f}" "${CHROOT_DIR}/etc/systemd/system/multi-user.target.wants/${unit}" 2>/dev/null \
                && msg ":: 已启用 ${unit}（写入 multi-user.target.wants，安装期确定性启用）"
        fi
    done
    # 注：systemctl 模式下 ssh.service 的 enable 由 init/systemctl 组件在 start
    # 拉起 --init 前统一执行，此处不再调用 python systemctl。
    return 0
}

do_start()
{
    msg -n ":: Starting ${COMPONENT} ... "
    # 最高优先级：privsep 目录必须在“任何 sshd 进程存在性判断”之前建好。
    # /run 在容器里通常是 tmpfs，容器每次停止都会被清空；而 sshd 一启动就检查
    # `Missing privilege separation directory: /run/sshd` 并直接退出（会话阶段
    # 也会再次校验）。此前这里先做 sshd_running 判断、并在“已在运行”时提前
    # return，导致 /run/sshd 永远不被重建——表现为“能连上、输完密码被断开”。
    make_dirs "${CHROOT_DIR}/run/sshd" "${CHROOT_DIR}/var/run/sshd" "${CHROOT_DIR}/var/empty"
    chown 0:0 "${CHROOT_DIR}/run/sshd" "${CHROOT_DIR}/var/run/sshd" "${CHROOT_DIR}/var/empty" 2>/dev/null || true
    chmod 755 "${CHROOT_DIR}/run/sshd" "${CHROOT_DIR}/var/run/sshd" "${CHROOT_DIR}/var/empty" 2>/dev/null || true
    # 启动前兜底：会话组件缺失（OpenSSH 9.8+ 安装残缺/被误删）时自行修复，
    # 否则“能连上、输完密码会话立即失败”，且用户没有任何线索。
    ssh_session_repair >/dev/null 2>&1 || true
    # 每次启动重新应用一次 sshd 配置（端口 / 密码登录 / root 登录 / 键盘交互 /
    # privsep 目录 / host key / PAM 会话加固）：do_configure 只在部署时执行，
    # 历史容器、或"改了密码/端口后重启容器"的场景需要靠这里兜底。
    # 注意不能把输出丢到 /dev/null：PAM 加固失败时（例如 setcred 出错导致
    # SSH 认证后被断开）用户需要从启动日志里看到具体改了哪些文件。
    ssh_config_apply
    # systemctl 模式：ssh 由 systemctl 管理（ssh.service / sshd.service），CLI 不直启。
    # 但组件执行顺序是 init/systemctl 先拉起 sshd，本组件随后才加固 PAM——
    # 加固写进文件后已运行的 sshd 仍用旧 PAM 栈，必须让它重新加载配置。
    # 这里重启一次 ssh 服务（sshd 每次会话都会重新读 PAM 配置，重启最稳妥）；
    # 重启失败不影响后续流程（下次启动容器时仍会应用）。
    if [ "${INIT}" = "systemctl" ]; then
        local svc restarted=""
        for svc in ssh.service sshd.service; do
            if [ -e "${CHROOT_DIR}/etc/systemd/system/${svc}" ] \
               || [ -e "${CHROOT_DIR}/lib/systemd/system/${svc}" ] \
               || [ -e "${CHROOT_DIR}/usr/lib/systemd/system/${svc}" ]; then
                chroot_exec /usr/bin/systemctl restart "${svc}" >/dev/null 2>&1 || true
                restarted="${svc}"
                break
            fi
        done
        # 回读验证（修复“静默跳过”）：systemctl 模式下 sshd 由 init 拉起，此前
        # 无论是否真的启动都只打印“跳过”——init 未起、enable 失败、sshd 崩溃
        # 等情况在日志里没有任何线索，用户只能看到“部署成功但 SSH 无法登录”。
        # 这里等待并确认进程与监听口；失败时把 sshd 自检结果打到日志。
        local i=0
        while [ ${i} -lt 20 ]; do
            sshd_running && ssh_listening && break
            sleep 0.5
            i=$((i+1))
        done
        if sshd_running && ssh_listening; then
            msg "完成（systemctl 模式：${restarted:-ssh} 已拉起，端口 ${SSH_PORT} 已监听）"
        elif sshd_running; then
            msg "警告：sshd 进程在运行，但端口 ${SSH_PORT} 未监听（可能是其它容器/宿主服务占用了该端口）"
        else
            msg "失败（systemctl 模式下未检测到 sshd 进程，端口 ${SSH_PORT} 未监听）"
            msg "      可进入容器执行 /usr/bin/systemctl status ssh.service 排查；下方为 sshd 自检结果："
            ssh_config_selftest
        fi
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
    # sysv/run-parts 模式下的兜底：初始化脚本可能因缺少 sshd 的启动脚本
    # （Arch/Slackware 的 /etc/rc.d/sshd 未安装、SysV 的 rcN.d 里没有 S??ssh）
    # 而没有拉起 sshd。这里先尝试发行版自带的启动脚本，失败再直接拉起。
    sysv_runparts_sshd_start()
    {
        local f
        for f in "${CHROOT_DIR}/etc/init.d/ssh" "${CHROOT_DIR}/etc/init.d/sshd" \
                 "${CHROOT_DIR}/etc/rc.d/sshd" "${CHROOT_DIR}/etc/rc.d/rc.sshd"
        do
            [ -x "${f}" ] || continue
            chroot_exec -u root "${f#"${CHROOT_DIR}"}" start >/dev/null 2>&1 || true
            sshd_running && return 0
        done
        return 1
    }
    if [ "${INIT}" = "sysv" ] || [ "${INIT}" = "run-parts" ]; then
        if sysv_runparts_sshd_start; then
            if ssh_listening; then
                msg "完成（发行版脚本已启动 sshd，端口 ${SSH_PORT} 已监听）"
            else
                msg "完成（发行版脚本已启动 sshd）"
            fi
            return 0
        fi
    fi
    # 兜底直接拉起
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
        # 把 sshd 自己的诊断信息（含 -t 校验结果）打到部署/启动日志里，
        # 避免用户只能看到一句“失败”而无从排查。
        local _diag
        _diag=""
        _diag=$(chroot_exec "${sshd}" -t 2>&1 | sed -n '1,8p')
        if [ -n "${_diag}" ]; then
            printf '%s\n' "${_diag}" | while IFS= read -r _line; do
                [ -n "${_line}" ] && msg "        ${_line}"
            done
        fi
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
