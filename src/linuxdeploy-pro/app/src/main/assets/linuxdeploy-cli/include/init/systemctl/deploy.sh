#!/bin/sh
# Linux Deploy Component
# (c) Anton Skshidlevsky <meefik@gmail.com>, GPLv3
# 基于 python 版 systemctl（Guido Draheim）的 init 模式：
# 启动时以 init 服务方式拉起 `systemctl --init`（常驻），由它按序拉起
# default.target 下的服务（含 sysv-generator 转换的 init.d 脚本与 enable 的
# systemd 服务）；停止时向 systemctl 进程发 SIGTERM 触发干净停机。
# 注意：不管理 ldstatus（其位于 /usr/local/sbin，非 init.d/unit，天然隔离）。
#
# 已知注意事项（真机实测，2026-08）：
# systemctl.py 拉起服务时会把其 stdin/stdout/stderr 全部 dup2 重定向到
# journal 日志文件。服务脚本内若调用 app_process 类工具（如安卓宿主侧的
# am/app_process 等，经 unchroot 执行），binder 调用会因此失败
# （"Failed transaction"），表现为"命令执行了但无效果"。
# 规避：脚本内调用此类工具时显式重定向 stdio 并脱离进程树，例如：
#   setsid /sbin/unchroot am start <pkg>/<Activity> </dev/null >/dev/null 2>&1 &

# systemctl 常驻进程检查：读容器内 pid 文件 + /proc/<pid>/cmdline 校验进程名
systemctl_running()
{
    local s_pid
    s_pid=$(cat "${CHROOT_DIR}/run/systemctl/pid" 2>/dev/null | tr -cd '0-9')
    [ -n "${s_pid}" ] || return 1
    [ -r "/proc/${s_pid}/cmdline" ] || return 1
    tr '\0' ' ' < "/proc/${s_pid}/cmdline" | grep -q systemctl
}

# 容器内 python3 是否可用（systemctl.py 的运行依赖）
systemctl_python_ready()
{
    [ -x "${CHROOT_DIR}/usr/bin/python3" ] || [ -x "${CHROOT_DIR}/usr/bin/python3.10" ] \
        || [ -x "${CHROOT_DIR}/usr/bin/python3.9" ] || [ -x "${CHROOT_DIR}/usr/bin/python3.11" ] \
        || [ -x "${CHROOT_DIR}/usr/bin/python3.12" ]
}

# 按发行版安装 python3。Debian 系/Ubuntu/Kali 的 bootstrap 已自带 python3；
# CentOS/Fedora/Arch 等默认不带，必须在部署时补装，否则 systemctl.py 无法运行
# （表现为 init 起不来、sshd 永不启动）。
systemctl_ensure_python()
{
    systemctl_python_ready && return 0
    msg -n ":: 安装 python3（systemctl 运行依赖） ... "
    local ok=1
    case "${DISTRIB}" in
    debian|ubuntu|kali)     apt_install python3 && ok=0 ;;
    centos)                 yum_install python3 && ok=0 ;;
    fedora)                 dnf_install python3 && ok=0 ;;
    archlinux)              pacman_install python && ok=0 ;;
    alpine)                 apk_install python3 && ok=0 ;;
    slackware)              slackpkg_install python3 && ok=0 ;;
    esac
    systemctl_python_ready && ok=0
    [ ${ok} -eq 0 ] && msg "完成" || msg "失败"
    return ${ok}
}

do_install()
{
    msg ":: 正在安装 ${COMPONENT} ... "
    local src="${INCLUDE_DIR}/init/systemctl/systemctl.py"
    if [ -f "${src}" ]; then
        # 修复：make_dirs 不会自动补 CHROOT_DIR 前缀，必须写容器内路径的宿主全路径。
        # 原写法会把目录建到 Android 宿主根（宿主无 /run，静默失败），
        # 导致容器内 /run/systemctl 不存在 → init 的 pid 文件写入失败
        # （实测日志：cannot create /run/systemctl/pid: Directory nonexistent）。
        make_dirs "${CHROOT_DIR}/usr/bin" "${CHROOT_DIR}/run/systemctl"
        rm -f "${CHROOT_DIR}/usr/bin/systemctl"
        cp -f "${src}" "${CHROOT_DIR}/usr/bin/systemctl"
        chmod 755 "${CHROOT_DIR}/usr/bin/systemctl"
        is_ok "失败" "完成"
    else
        msg "[错误] 缺少打包的 systemctl.py: ${src}"
        return 1
    fi
    # python3 缺失时补装（失败不阻断部署，启动阶段会再次提示）
    systemctl_ensure_python || msg "[警告] python3 未能安装，systemctl 模式将无法启动（可改用 sysv）"
    return 0
}

# 容器运行环境适配（幂等，内容不变时不重写、不产生额外日志）
# 背景：安卓 chroot 里 PID 1 不是 systemd，发行版打包的 docker / containerd 单元
# 依赖真 systemd 的 socket 激活与 sd_notify，直接 `systemctl start docker` 会失败
# （最显眼的报错只是 systemctl.py 对 ExecReload=/bin/kill 的 WARNING，并非根因）。
# 这里只在已安装 docker/containerd 时写入 drop-in 与运行时配置：
#   1) docker.service：Type=simple、去掉 docker.socket 依赖与 -H fd://、
#      ExecReload 置空（消除 /bin/kill 告警，reload 退化为 restart）、
#      默认 vfs 存储 + 关闭 iptables/桥接（安卓常无完整 netfilter）；
#   2) containerd：SystemdCgroup=false（无 systemd 时不能用 systemd cgroup 驱动）。
# 未安装 docker 的容器不会被创建任何相关文件。
container_runtime_tune()
{
    local d
    # --- docker.service drop-in ---
    for d in "${CHROOT_DIR}/usr/lib/systemd/system" "${CHROOT_DIR}/lib/systemd/system"; do
        [ -e "${d}/docker.service" ] || continue
        make_dirs "${CHROOT_DIR}/etc/systemd/system/docker.service.d"
        local conf="${CHROOT_DIR}/etc/systemd/system/docker.service.d/container.conf"
        # 已存在时只在内容不同（如旧版本写入）时覆盖，保持幂等
        if [ ! -e "${conf}" ] || ! grep -q 'Type=simple' "${conf}" 2>/dev/null; then
            cat > "${conf}" <<CONTAINERCONF
# linuxdeploy: container runtime
[Unit]
# 无真实 systemd：去掉 socket 激活依赖，避免 docker.socket 缺失导致启动失败
Requires=
After=network-online.target

[Service]
# 不等待 sd_notify 的 READY（Type=notify 在容器内不可靠）
Type=simple
# 不使用 -H fd://（fd 传递由 systemd 提供），改为 unix socket
ExecStart=
ExecStart=/usr/sbin/dockerd -H unix:///var/run/docker.sock --iptables=false --ip6tables=false --bridge=none --storage-driver=vfs --userland-proxy-path=/usr/bin/docker-proxy
# 置空以消除 systemctl.py 对 /bin/kill 的告警；reload 时自动退化为 restart
ExecReload=
Restart=on-failure
RestartSec=3s
CONTAINERCONF
        fi
        break
    done
    # --- containerd：关闭 systemd cgroup 驱动 ---
    d="${CHROOT_DIR}/etc/containerd"
    if [ -e "${CHROOT_DIR}/usr/bin/containerd" ] || [ -e "${CHROOT_DIR}/usr/sbin/containerd" ]; then
        make_dirs "${d}"
        if [ ! -e "${d}/config.toml" ]; then
            cat > "${d}/config.toml" <<CONTAINERD
version = 2
# 无 systemd：runc 使用 cgroupfs 驱动（否则 containerd 会尝试向 systemd 申请 cgroup）
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
  SystemdCgroup = false
CONTAINERD
        elif ! grep -q 'SystemdCgroup' "${d}/config.toml" 2>/dev/null; then
            # 已有用户配置：只追加标记注释，不改动用户内容（避免破坏自定义配置）
            { echo ""; echo "# linuxdeploy: container runtime（无 systemd 时请确保 SystemdCgroup=false）"; } >> "${d}/config.toml"
        fi
    fi
    # --- docker daemon 侧：存储驱动兜底（安卓内核多用不了 overlay2） ---
    if [ -e "${CHROOT_DIR}/usr/bin/dockerd" ] || [ -e "${CHROOT_DIR}/usr/sbin/dockerd" ]; then
        make_dirs "${CHROOT_DIR}/etc/docker"
        if [ ! -e "${CHROOT_DIR}/etc/docker/daemon.json" ]; then
            cat > "${CHROOT_DIR}/etc/docker/daemon.json" <<DOCKERJSON
{
  "storage-driver": "vfs"
}
DOCKERJSON
        fi
    fi
    return 0
}

# 检查 Docker 所需的安卓内核条件，不满足时给出可读提示（只提示，不阻断容器启动）
# 真机实测（M2102K1AC / Android 11）：ROM 只挂了 blkio/cpu/cpuacct/cpuset/freezer/memory，
# 缺少 devices 与 pids 控制器，dockerd 启动必然报 "Devices cgroup isn't mounted"，
# 这不是容器配置问题，只能换内核/ROM。提前说明可避免用户反复重装排查。
container_runtime_check()
{
    # 仅当容器里装了 docker 才检查
    if [ ! -e "${CHROOT_DIR}/usr/bin/dockerd" ] && [ ! -e "${CHROOT_DIR}/usr/sbin/dockerd" ]; then
        return 0
    fi
    # 未挂载 cgroup 目录时 /sys 可能不可见，跳过（启动流程会再提示）
    [ -d "${CHROOT_DIR}/sys/fs/cgroup" ] || return 0
    local missing="" c
    for c in devices pids; do
        # v1：/sys/fs/cgroup/<控制器>；v2：统一层级 + cgroup.controllers 中列出控制器
        if [ -d "${CHROOT_DIR}/sys/fs/cgroup/${c}" ]; then
            continue
        fi
        if [ -f "${CHROOT_DIR}/sys/fs/cgroup/cgroup.controllers" ] \
            && grep -qw "${c}" "${CHROOT_DIR}/sys/fs/cgroup/cgroup.controllers" 2>/dev/null; then
            continue
        fi
        missing="${missing} ${c}"
    done
    if [ -n "${missing}" ]; then
        msg "[提示] 当前机型内核缺少 cgroup 控制器:${missing}，Docker 可能无法启动。"
        msg "        这是内核/ROM 限制（容器内配置无法弥补），数据库等服务不受影响。"
    fi
    return 0
}

do_start()
{
    if systemctl_running; then
        msg ":: 启动 ${COMPONENT} ... 已在运行"
        return 0
    fi
    msg -n ":: 启动 ${COMPONENT} ... "
    [ -x "${CHROOT_DIR}/usr/bin/systemctl" ] || { msg "失败（/usr/bin/systemctl 未安装，请重新部署）"; return 1; }
    # python3 是 systemctl.py 的运行依赖：缺失时给出可执行的原因，而不是让 init 静默失败
    if ! systemctl_ensure_python >/dev/null 2>&1 || ! systemctl_python_ready; then
        msg "失败（容器内缺少 python3，systemctl 模式无法运行）"
        msg "[提示] 可改用「SysV」初始化系统，或进入终端执行包管理器安装 python3 后重试。"
        return 1
    fi
    # 二进制刷新：容器内的 /usr/bin/systemctl 与打包脚本不一致（或不是 python 脚本，
    # 例如发行版自带的 ELF systemctl / 损坏文件）时覆盖为打包版本。
    # 目的：init 用的一定是本项目的 systemctl.py，APK 更新后"重启容器"即可生效。
    # 安全性：此处已确认 init 未运行（上面 systemctl_running 为假才走到这里），
    # 覆盖文件不会被正在运行的 python 占用。cmp 不可用时退化为无条件覆盖。
    local sysctl_src="${INCLUDE_DIR}/init/systemctl/systemctl.py"
    if [ -f "${sysctl_src}" ]; then
        local need_refresh=1
        case "$(head -c 20 "${CHROOT_DIR}/usr/bin/systemctl" 2>/dev/null)" in
        '#!'*python*) command -v cmp >/dev/null 2>&1 && cmp -s "${sysctl_src}" "${CHROOT_DIR}/usr/bin/systemctl" && need_refresh=0 ;;
        esac
        if [ "${need_refresh}" = "1" ]; then
            rm -f "${CHROOT_DIR}/usr/bin/systemctl"
            cp -f "${sysctl_src}" "${CHROOT_DIR}/usr/bin/systemctl"
            chmod 755 "${CHROOT_DIR}/usr/bin/systemctl"
            msg ":: 已刷新容器内 systemctl（与打包版本不一致）"
        fi
    fi
    # 修复：同上，pid 目录必须落在容器内，init 才能成功写 /run/systemctl/pid
    # （systemctl_running()/do_stop 都依赖该文件，缺失会导致重复拉起 init）
    make_dirs "${CHROOT_DIR}/run/systemctl"
    # docker / containerd 在无 systemd 的 chroot 内的启动适配（未安装时不做任何事）
    container_runtime_tune
    # 内核缺少 devices/pids 等控制器时提示 Docker 不可用（不影响其它服务）
    container_runtime_check
    # 拉起 init 前确保 ssh.service 已 enable：systemctl 的 default.target 才会
    # 启动 sshd（openssh 安装时未必 enable；此处兜底覆盖任何顺序/老容器）。
    # 发行版差异：debian/ubuntu/kali 用 ssh.service，centos/fedora/rhel 用 sshd.service，
    # 两套 unit 都尝试 enable，缺失时 enable 会自行跳过。
    local ssh_unit="" u
    for u in ssh.service sshd.service; do
        if [ -e "${CHROOT_DIR}/usr/lib/systemd/system/${u}" ] || [ -e "${CHROOT_DIR}/lib/systemd/system/${u}" ]; then
            ssh_unit="${u}"
            break
        fi
    done
    if [ -n "${ssh_unit}" ]; then
        # 关闭 socket 激活（Ubuntu 22.10+ 默认 enable ssh.socket 并 mask ssh.service）：
        # sshd 交给 init 的监听线程按需拉起，本项目里该线程不可靠（实测 sshd 从不启动、
        # 端口无人监听）。清掉后恢复正常由 service 拉起。
        local sock="${ssh_unit%.service}.socket"
        if [ -e "${CHROOT_DIR}/usr/lib/systemd/system/${sock}" ] || [ -e "${CHROOT_DIR}/lib/systemd/system/${sock}" ]; then
            rm -f "${CHROOT_DIR}/etc/systemd/system/sockets.target.wants/${sock}" 2>/dev/null
            rm -f "${CHROOT_DIR}/etc/systemd/system/${sock}" 2>/dev/null
        fi
        # unit 被 mask 时 enable 不生效，先解除。mask 有两种落点：
        #   1) /etc/systemd/system/xxx -> /dev/null（用户级 mask）
        #   2) /usr/lib/systemd/system/xxx -> /dev/null（发行版镜像预置，Ubuntu 24.04
        #      的 ssh.service 曾被镜像以 socket 激活方式 mask）
        # 早期只清理第 1 种，第 2 种会导致 enable 报 "Unit is masked"，sshd 永不启动。
        local m u2
        for u2 in ${ssh_unit} ${sock}; do
            for m in "${CHROOT_DIR}/etc/systemd/system/${u2}" \
                     "${CHROOT_DIR}/usr/lib/systemd/system/${u2}" \
                     "${CHROOT_DIR}/lib/systemd/system/${u2}"; do
                if [ -L "${m}" ]; then
                    # 仅解除指向 /dev/null 的 mask 链接，其他软链（正常别名）保留
                    case "$(readlink "${m}" 2>/dev/null)" in
                    /dev/null) rm -f "${m}" ;;
                    esac
                fi
            done
        done
        chroot_exec /usr/bin/systemctl enable ${ssh_unit} 2>/dev/null || true
        # 兜底加固：给 ssh unit 写 RestartSec=1s 的 drop-in。
        # 原因：未显式声明 RestartSec 时走 DefaultRestartSec="0.1"，旧版
        # time_to_seconds 会把小数误解析成 200 秒上限，sshd 崩溃后要等 3 分 20 秒
        # 才被拉起；显式写整数秒（带 s 后缀）可绕开该解析路径，并让 init 循环
        # 间隔自动降到 1 秒（restartSec>0.9 且 <loop_sleep 时自动收紧），
        # 使崩溃恢复延迟进入 1~2 秒级。每次启动幂等重写，防 apt 升级/旧容器缺失。
        make_dirs "${CHROOT_DIR}/etc/systemd/system/${ssh_unit}.d"
        cat > "${CHROOT_DIR}/etc/systemd/system/${ssh_unit}.d/restartsec.conf" <<RESTARTSEC
[Service]
RestartSec=1s
RESTARTSEC
    fi
    # 看门狗随 init 启动：ldwatchdog.service 由 core/unchroot 组件注入，这里兜底 enable
    # （enable 后 --init 会在 default.target 里拉起看门狗；看门狗反向监视 init 存活，
    #  init 异常消失时经 unchroot 触发宿主侧 cli.sh restart）
    if [ -e "${CHROOT_DIR}/etc/systemd/system/ldwatchdog.service" ]; then
        chroot_exec /usr/bin/systemctl enable ldwatchdog.service 2>/dev/null || true
    fi
    # 以 init 服务方式拉起并常驻：setsid 脱离宿主会话；--init 进入 init 模式
    # （拉起 default.target 服务 → 阻塞 init 循环收僵尸、等 SIGTERM/SIGINT 干净停机）。
    # pid 由 setsid 子 shell 写入容器 /run/systemctl/pid（容器磁盘，跨挂载命名空间可见）。
    # 注意：必须先注入容器登录级环境（HOME/PATH/USER 等）——systemctl 会把自身环境
    # 原样传给其拉起的全部服务，CLI 侧 HOME 指向临时目录、PATH 为宿主路径，
    # 会导致 KDE 等读取无效 HOME（加载默认配置）、unchroot 等命令找不到。
    chroot_exec /bin/sh -c 'export HOME=/root USER=root LOGNAME=root SHELL=/bin/bash PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; setsid /bin/sh -c '\''echo $$ > /run/systemctl/pid; exec /usr/bin/systemctl --init'\'' </dev/null >/dev/null 2>&1 &'
    # 确认 init 真的起来了：pid 文件写入 + 进程名校验。
    # 原实现只看 chroot_exec 的退出码（后台 & 恒为 0），init 启动失败时日志照样
    # 显示"完成"，容器内 sshd 等全部服务因此从未被拉起（表现为 UI 显示运行中、
    # 本机 22 端口无人监听）。
    local i=0
    while [ ${i} -lt 20 ] && ! systemctl_running; do
        sleep 0.5
        i=$((i+1))
    done
    if ! systemctl_running; then
        msg "失败（初始化系统未启动）"
        msg "[提示] systemctl --init 未能启动，容器内服务（ssh 等）不会自动运行。"
        msg "        可打开终端执行 /usr/bin/systemctl --init 查看报错，或重新部署。"
        return 1
    fi
    is_ok "失败" "完成"
    return 0
}

do_stop()
{
    msg -n ":: 停止 ${COMPONENT} ... "
    local s_pid
    s_pid=$(cat "${CHROOT_DIR}/run/systemctl/pid" 2>/dev/null | tr -cd '0-9')
    if [ -n "${s_pid}" ] && [ -r "/proc/${s_pid}/cmdline" ]; then
        # SIGTERM → init 循环执行干净停机（停止全部已拉起的服务）
        kill -TERM "${s_pid}" 2>/dev/null
        local i=0
        while [ ${i} -lt 20 ] && [ -d "/proc/${s_pid}" ]; do
            sleep 0.5
            i=$((i+1))
        done
        [ -d "/proc/${s_pid}" ] && kill -9 "${s_pid}" 2>/dev/null
        rm -f "${CHROOT_DIR}/run/systemctl/pid"
    fi
    is_ok "失败" "完成"
    return 0
}

do_status()
{
    msg -n ":: ${COMPONENT} ... "
    if systemctl_running; then
        msg "运行中"
        return 0
    fi
    msg "已停止"
    return 1
}

do_help()
{
cat <<EOF
   无参数：启动容器时以 init 模式拉起 systemctl（--init），
   自动按序启动 default.target 下的服务（init.d / enable 的 systemd 服务）。
EOF
}
