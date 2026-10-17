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
        # unit 被 mask（软链到 /dev/null）时 enable 不生效，先解除
        local m u2
        for u2 in ${ssh_unit} ${sock}; do
            m="${CHROOT_DIR}/etc/systemd/system/${u2}"
            if [ -L "${m}" ]; then
                rm -f "${m}"
            fi
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
