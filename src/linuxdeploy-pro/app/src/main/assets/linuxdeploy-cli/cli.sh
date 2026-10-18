#!/bin/bash
################################################################################
#
# Linux Deploy CLI 4.1.20
# 维护：GanYu256
# 说明：本版本为全面重构，命令层重设计、无配置锁（统一 -c 指定配置）、全中文注释与日志。
# 基线：app 锁定版 79924f593556（原 VERSION 2.5.1）
#
################################################################################

VERSION="4.1.20"

################################################################################
# 公共工具
################################################################################

# 输出消息（统一入口，便于前端解析与日志落盘）
# 当 LOG_FILE 非空时，所有消息同步追加到日志文件（带时间戳），供前端轮询读取
msg()
{
    if [ "${1}" = "-n" ]; then
        shift
        echo -n "$@"
        if [ -n "${LOG_FILE}" ]; then
            # 日志按行落盘：继续行（msg -n 后的"完成/失败"）单独成行，
            # 避免与上一条带时间戳的记录黏在一起难以阅读
            printf '%s %s\n' "$(date '+%F %T')" "$@" >> "${LOG_FILE}"
        fi
    else
        echo "$@"
        if [ -n "${LOG_FILE}" ]; then
            printf '%s %s\n' "$(date '+%F %T')" "$@" >> "${LOG_FILE}"
        fi
    fi
}

# 组件依赖解析专用提示：component_depends 运行在 $(...) 命令替换内，
# stdout 会混进组件列表、stderr 在非 debug 模式被 exec 2>/dev/null 丢弃，
# 因此提示直接写入日志文件（部署日志可见）；debug 模式下 stderr 同步输出。
msg_depends()
{
    if [ -n "${LOG_FILE}" ]; then
        printf '%s %s\n' "$(date '+%F %T')" "$*" >> "${LOG_FILE}"
    fi
    if [ "${DEBUG_MODE}" = "true" ]; then
        echo "[提示] $*" >&2
    fi
    return 0
}

# 原始输出流式处理：逐行实时回显，并同步写入当前日志文件
# 用于 debootstrap / apt 等直接向 stdout 输出原始文本的环节。
# 注意：管道会吞掉退出码，需配合 log_exec 或在外部自行捕获。
log_stream()
{
    local line
    while IFS= read -r line || [ -n "${line}" ]
    do
        # 去掉回车符（debootstrap 进度条用 \r 刷新行）
        line=$(printf '%s' "${line}" | tr -d '\r')
        echo "${line}"
        if [ -n "${LOG_FILE}" ]; then
            printf '%s %s\n' "$(date '+%F %T')" "${line}" >> "${LOG_FILE}"
        fi
    done
    return ${PIPESTATUS[0]}  # 返回真实退出码（防止被管道吞掉）
}

# 归一化软件包列表：兼容空格 / 半角逗号 / 全角逗号 / 顿号 / 分号分隔，统一转成空格。
normalize_packages()
{
    local raw="$1" out
    [ -n "${raw}" ] || { echo ""; return 0; }
    out=$(printf '%s' "${raw}" | tr ',;' ' ')
    out=$(printf '%s' "${out}" | tr '，、；' ' ')
    out=$(printf '%s' "${out}" | tr -s ' ')
    out=${out# }
    out=${out% }
    printf '%s' "${out}"
}

# 组件脚本内的日志：组件运行在子 shell 中，msg 的提示只写 debug 通道，
# 这里同时写进当前日志文件。LOG_FILE 在 log_open 后已 export，子 shell 可继承。
# 注意：会修改日志文件（追加），因此不能放进 $(...) 命令替换里调用。
log_note()
{
    if [ -n "${LOG_FILE}" ]; then
        printf '%s %s\n' "$(date '+%F %T')" "$*" >> "${LOG_FILE}" 2>/dev/null
    fi
    return 0
}

# 在子 shell 中执行命令，输出经 log_stream 实时回显并写入日志，
# 返回原命令的真实退出码（解决管道吞退出码问题）
log_exec()
{
    local rc_file rc
    # 显式模板：安卓的 mktemp 不认 TMPDIR，裸 mktemp 会往不存在的 /tmp 写并失败
    mkdir -p "${TEMP_DIR}" 2>/dev/null || true
    rc_file=$(mktemp "${TEMP_DIR}/ld-log.XXXXXX") || return 1
    # 在子 shell 内设置 EXIT trap 清理临时文件：子 shell 的 trap 仅作用于自身，
    # 不会覆盖调用方（部署流程的 deploy_cleanup 等）已注册的 EXIT trap，
    # 避免部署失败时漏卸载残留挂载。
    (
        trap 'rm -f "${rc_file}"' EXIT
        (
            "$@" 2>&1
            echo $? > "${rc_file}"
        ) | log_stream
        rc=$(cat "${rc_file}" 2>/dev/null)
        rm -f "${rc_file}"
        [ -n "${rc}" ] || rc=0
        return ${rc}
    )
}

# 安全变量赋值（替代 eval 直接赋值，杜绝值中的命令注入）
# 本项目运行环境只有两种 shell，分别采用无二次解析的赋值方式：
#   bash 用 declare 直接赋值；mksh 用 nameref 别名赋值
#   两者都不会执行值中的变量引用、反引号、引号、分号。
# 入参：1 为变量名（调用方须已校验仅含大写字母数字下划线），2 为值
ld_set_var()
{
    case "${LD_VAR_BACKEND:-bash}" in
    mksh)
        nameref ld_ref="$1" 2>/dev/null
        ld_ref="$2"
    ;;
    *)
        declare -g "$1=$2" 2>/dev/null
    ;;
    esac
}

# 安全读取变量值（替代 eval 间接展开），值输出到 stdout
ld_get_var()
{
    case "${LD_VAR_BACKEND:-bash}" in
    mksh)
        nameref ld_ref="$1" 2>/dev/null
        printf '%s' "${ld_ref:-}"
    ;;
    *)
        declare -n ld_ref="$1" 2>/dev/null
        printf '%s' "${ld_ref:-}"
    ;;
    esac
}

# shell 后端探测（仅执行一次）：bash 走 declare，其余按 mksh 处理。
# 说明：Android 的 /system/bin/sh 即 mksh，minSdk 28 起均支持 nameref。
# nameref 是 mksh 保留字，只能在函数内使用，且不得作为 case 标签，否则解析报错。
if [ -n "${BASH_VERSION:-}" ]; then
    LD_VAR_BACKEND="bash"
else
    LD_VAR_BACKEND="mksh"
fi

# JSON 字符串转义（--json 模式输出安全字段）
json_escape()
{
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\r//g'
}

# 输出一行 JSON 键值（--json 模式使用）
json_kv()
{
    printf '  "%s": "%s"' "$1" "$(json_escape "$2")"
}

# 打开操作日志（部署/启停/导入导出等），前端可轮询读取
# 用法: log_open [配置名]
log_open()
{
    local name="${1:-default}"
    LOG_DIR="${LOG_DIR:-${BUILD_DIR}/logs}"
    mkdir -p "${LOG_DIR}" 2>/dev/null || {
        # 日志目录不可写时退到容器同级目录（避免整条命令因日志失败而中止）
        LOG_DIR="$(dirname "${CHROOT_DIR%/}")/linuxdeploy-logs"
        mkdir -p "${LOG_DIR}" 2>/dev/null || { msg "[错误] 无法创建日志目录：${LOG_DIR}"; return 1; }
    }
    # 时间戳命名（配置名-日期-时分秒）：每次操作独立日志文件，前端按最新文件尾随展示。
    LOG_FILE="${LOG_DIR}/${name}-$(date '+%Y%m%d-%H%M%S').log"
    : > "${LOG_FILE}" || { msg "[错误] 无法创建日志文件：${LOG_FILE}"; return 1; }
    # 导出让组件子 shell 内的 log_note 能追加日志
    export LOG_FILE
    # 日志文件 chown 给应用，使其可读取/删除
    if [ -n "${APP_UID}" ]; then
        if ! chown "${APP_UID}" "${LOG_FILE}" 2>/dev/null; then
            msg "[警告] chown ${APP_UID} ${LOG_FILE}失败"
        fi
        if ! chown "${APP_UID}" "${LOG_DIR}" 2>/dev/null; then
            msg "[警告] chown ${APP_UID} ${LOG_DIR}失败"
        fi
    fi
    msg "日志文件: ${LOG_FILE}"
}

# 检查上一条命令结果，并输出指定消息
is_ok()
{
    if [ $? -eq 0 ]; then
        if [ -n "$2" ]; then
            msg "$2"
        fi
        return 0
    else
        if [ -n "$1" ]; then
            msg "$1"
        fi
        return 1
    fi
}

# 获取平台类型（安卓 arm64 映射为 arm_64）
get_platform()
{
    local arch="$1"
    if [ -z "${arch}" ]; then
        arch=$(uname -m)
    fi
    case "${arch}" in
    arm64|aarch64)
        echo "arm_64"
    ;;
    arm*)
        echo "arm"
    ;;
    x86_64|amd64)
        echo "x86_64"
    ;;
    i[3-6]86|x86)
        echo "x86"
    ;;
    *)
        echo "unknown"
    ;;
    esac
}

# 生成 UUID（用于隔离目录命名）
get_uuid()
{
    cat /proc/sys/kernel/random/uuid
}

# 检查 binfmt_misc 是否可用
multiarch_support()
{
    if [ -d "/proc/sys/fs/binfmt_misc" ]; then
        return 0
    else
        return 1
    fi
}

# 检查 SELinux 是否关闭
selinux_inactive()
{
    if [ -e "/sys/fs/selinux/enforce" ]; then
        return $(cat /sys/fs/selinux/enforce)
    else
        return 0
    fi
}

# 检查 loop 设备是否可用
loop_support()
{
    [ -e "/dev/loop-control" ] || [ -e "/dev/loop0" ]
}

# 在容器 /etc/passwd 中按用户名取字段（$1=用户名 $2=字段号）
# 注意：必须读容器内 passwd——宿主（Android）没有 getent，原实现
# `getent passwd` 在宿主上恒为空，导致 profile 组件的 chown 目标变成空字符串，
# 所有发行版都会踩到（不只是 Alpine）。
user_field()
{
    local user="$1" field="${2:-6}" passwd
    [ -n "${user}" ] || user="root"
    passwd="${CHROOT_DIR}/etc/passwd"
    if [ -r "${passwd}" ]; then
        awk -F: -v u="${user}" -v f="${field}" '$1==u {print $f; exit}' "${passwd}"
    fi
}

# 获取指定用户的 home 目录（容器内路径）
user_home()
{
    local home
    home=$(user_field "$1" 6)
    # 容器内无该用户时按约定回退（root 必为 /root）
    [ -n "${home}" ] || home="/root"
    echo "${home}"
}

# 获取指定用户的登录 shell（容器内路径）
user_shell()
{
    local shell
    shell=$(user_field "$1" 7)
    [ -n "${shell}" ] || shell="/bin/sh"
    echo "${shell}"
}

# 判断路径是否已挂载
# realpath 解析结果按进程内缓存：同一路径重复查询（如容器启动时的多点位
# 轮询）只 fork 一次 readlink，避免频繁调用时的重复解析开销。
# 注意：只缓存"路径→realpath"映射（稳定），挂载状态始终实时读 /proc/mounts。
# 匹配同时兼容两种写法：目标路径后带 "/"（子挂载，如 /dev/pts/）与不带。
# 早期只匹配 " <路径> "，而 /proc/mounts 中根挂载常写成 "/data/local/tmp/x /"，
# 子挂载写成 "/data/local/tmp/x/dev/pts /dev/pts ..."（路径后紧跟 "/"），
# 导致已挂载的 /dev/pts 被判为“未挂载”，apt 安装时反复报
# “E: Can not write log (Is /dev/pts mounted?) - posix_openpt (19: No such device)”。
is_mounted()
{
    local target="$1" real
    [ -n "${target}" ] || return 1
    if [ "${_LD_MNT_KEY:-}" = "${target}" ]; then
        real="${_LD_MNT_REAL:-}"
    else
        real=$(readlink -f "${target}" 2>/dev/null)
        _LD_MNT_KEY="${target}"
        _LD_MNT_REAL="${real}"
    fi
    [ -n "${real}" ] || real="${target}"
    grep -q -e " ${real} " -e " ${real%/}/" /proc/mounts 2>/dev/null
}

# 判断路径是否位于共享存储（/storage/emulated/0、/sdcard 这类 FUSE/sdcardfs 视图）。
# 共享存储的挂载标志固定 noexec/nosuid/nodev 且被内核锁定：目录型容器 bind 进来后
# 无法运行任何程序，remount 也无法修正。返回 0 = 位于共享存储。
is_shared_storage()
{
    local p="$1" fs
    [ -n "${p}" ] || return 1
    p=$(readlink -f "${p}" 2>/dev/null) || p="$1"
    [ -n "${p}" ] || p="$1"
    # 常见共享存储前缀快速判定（覆盖绝大多数设备）
    case "${p}" in
    /storage/emulated/*|/storage/sdcard*|/sdcard|/sdcard/*|/mnt/sdcard/*|/mnt/media_rw/*|/mnt/runtime/*)
        return 0
    ;;
    /storage/*)
        # /storage/<UUID>（如 /storage/0000-0000，外置卡/OTG）同为共享存储视图
        local seg="${p#/storage/}"
        seg="${seg%%/*}"
        case "${seg}" in
        emulated|self|scratch) return 0 ;;
        # 4 位数字开头的十六进制卷 UUID 段
        [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]*) return 0 ;;
        esac
    ;;
    esac
    # 兜底：沿路径向父级回溯，匹配 /proc/mounts 中的 FUSE 类挂载
    # （覆盖 ROM 自定义的共享存储挂载位置）
    local tmp="${p%/}"
    while : ; do
        [ -z "${tmp}" ] && tmp="/"
        fs=$(awk -v m="${tmp}" '$2==m{print $3; exit}' /proc/mounts 2>/dev/null)
        case "${fs}" in
        fuse|fuse.*|sdcardfs|esdfs|davfs2|ncfs) return 0 ;;
        esac
        [ "${tmp}" = "/" ] && break
        case "${tmp}" in
        */*) tmp="${tmp%/*}" ;;
        *) tmp="/" ;;
        esac
    done
    return 1
}

# 判断路径是否为归档文件
is_archive()
{
    local file="$1"
    case "${file}" in
    *tar|*tar.gz|*tgz|*tar.bz2|*tbz2|*tar.xz|*txz|*tar.zst|*tzst|*gz|*bz2|*xz|*zst)
        return 0
    ;;
    esac
    return 1
}

# 获取容器内运行的进程 PID 列表
# 逐个 readlink /proc/<pid>/root 匹配容器目录：不依赖 ls -l 的输出格式
# （locale/列宽变化会破坏 grep/sed 解析），也不必一次性物化全部进程的长列表
get_pids()
{
    local pid_dir pid target
    target="${CHROOT_DIR%/}"
    [ -n "${target}" ] || return 0
    for pid_dir in /proc/[0-9]*
    do
        [ -e "${pid_dir}/root" ] || continue
        pid="${pid_dir#/proc/}"
        if [ "$(readlink "${pid_dir}/root" 2>/dev/null)" = "${target}" ]; then
            echo "${pid}"
        fi
    done
    return 0
}

# 判断容器是否已启动（存在相关进程）
is_started()
{
    [ -n "$(get_pids)" ]
}

# 判断容器是否已停止
is_stopped()
{
    [ -z "$(get_pids)" ]
}

# 读取 ldstatus 锚点 pid：配置侧锚点（<配置名>.ldstatus，任何命名空间可读）优先，
# 回退容器内 /run/ldstatus/pid（兼容未写锚点的旧容器）。
ldstatus_pid()
{
    local anchor
    if [ -n "${CURRENT_CONF}" ]; then
        anchor="${CONFIG_DIR}/${CURRENT_CONF}.ldstatus"
        local ld_pid
        ld_pid=$(cat "${anchor}" 2>/dev/null | tr -cd '0-9')
        [ -n "${ld_pid}" ] && { echo "${ld_pid}"; return 0; }
    fi
    cat "${CHROOT_DIR}/run/ldstatus/pid" 2>/dev/null | tr -cd '0-9'
}

# 判断容器内 sshd 是否在运行：遍历 /proc/<pid>/root 指向容器的进程，判断 argv[0]。
# 不依赖容器当前命名空间可见（容器常运行在独立 mount ns 里，本进程看不到其挂载）。
# 必须按 argv[0]（或 -D 绝对路径）精确判断：
#   - 早期实现用 “cmdline 含 sshd”，会把 sshd-session、sshd-auth 这类会话子进程
#     也算作“正在监听”，容器重启后残留的会话进程会让 UI 误报 SSH 运行中；
#   - 只认 sshd / */sshd / *sshd -D 这类主进程形态，保证状态与真实端口一致。
sshd_running()
{
    local pid_dir pid target a0 a1
    target="${CHROOT_DIR%/}"
    [ -n "${target}" ] || return 1
    for pid_dir in /proc/[0-9]*
    do
        [ -r "${pid_dir}/cmdline" ] || continue
        pid="${pid_dir#/proc/}"
        [ "$(readlink "${pid_dir}/root" 2>/dev/null)" = "${target}" ] || continue
        a0=$(tr '\0' '\n' < "${pid_dir}/cmdline" 2>/dev/null | head -1)
        case "${a0}" in
        sshd|*/sshd) return 0 ;;
        esac
        # 部分发行版以 “sshd -D ...”（a0=sshd 已覆盖）或被重命名的方式启动，
        # 再按参数兜底一次（避免把 -session/-auth 子进程算进来）
        a1=$(tr '\0' '\n' < "${pid_dir}/cmdline" 2>/dev/null | head -2 | tail -1)
        case "${a1}" in
        -D|-[Dd]*|--daemon) case "${a0}" in *sshd*|-sshd|*/sshd*) return 0 ;; esac ;;
        esac
    done
    return 1
}

# 取宿主局域网 IPv4（Wi-Fi/移动网络），供前端直接显示容器访问地址。
# 优先 ip route 的出接口地址，其次 ip addr 里的全局地址，最后 hostname -I。
# 过滤回环、链路本地与虚拟接口（docker/veth/tun），只保留可被局域网访问的地址。
host_ipv4()
{
    local ip="" iface
    if command -v ip >/dev/null 2>&1; then
        # 默认路由所在接口的地址最可靠（多网卡时就是当前上网那张）；
        # 平板/热点等场景可能没有 default 路由，退化为第一条非本地网段路由的出接口
        iface=$(ip route 2>/dev/null | awk '
            $1=="default"{print $5; exit}
            $1 ~ /^[0-9]+\./ { for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit} }')
        if [ -n "${iface}" ]; then
            ip=$(ip -4 addr show dev "${iface}" 2>/dev/null | awk '/inet /{sub(/\/.*/,"",$2); print $2; exit}')
        fi
        if [ -z "${ip}" ]; then
            ip=$(ip -4 addr 2>/dev/null | awk '
                /^[0-9]+: /{ iface=$2; sub(/:$/,"",iface) }
                /inet /{
                    addr=$2; sub(/\/.*/,"",addr)
                    if (iface ~ /^(lo|docker|veth|tun|rmnet_ipa|dummy)/) next
                    if (addr ~ /^127\./) next
                    if (addr ~ /^169\.254\./) next
                    print addr; exit
                }')
        fi
    fi
    if [ -z "${ip}" ] && command -v hostname >/dev/null 2>&1; then
        ip=$(hostname -I 2>/dev/null | tr ' ' '\n' | awk '/^[0-9]+\./ && !/^127\./ && !/^169\.254\./{print; exit}')
    fi
    printf '%s' "${ip}"
}

# 清除配置侧 ldstatus 锚点（容器已停止时调用，见 container_umount）
remove_ldstatus_anchor()
{
    [ -n "${CURRENT_CONF}" ] || return 0
    rm -f "${CONFIG_DIR}/${CURRENT_CONF}.ldstatus" 2>/dev/null
    return 0
}

# 容器启动信息文件：App 每次执行 su -c 都处于独立的挂载命名空间，
# 当前命名空间通常“看不到”容器挂载，直接读 CHROOT_DIR 会得到空目录或旧内容，
# 导致 status 报 mounted=false、ssh_running=false，与界面/SSH 实际状态不一致。
# 这里在容器启动（能看见挂载的一方）时把设备号与网络信息落盘，
# status 在其余命名空间里据此还原，保证 UI 显示与真实 SSH 一致。
ldinfo_file()
{
    [ -n "${CURRENT_CONF}" ] || return 1
    echo "${CONFIG_DIR}/${CURRENT_CONF}.ldinfo"
}

# 写入启动信息（container_start 成功后调用）
ldinfo_write()
{
    local f dev
    f=$(ldinfo_file) || return 0
    dev=$(stat -c %d "${CHROOT_DIR}" 2>/dev/null)
    {
        echo "DEV=${dev}"
        echo "MOUNTS=$(is_mounted "${CHROOT_DIR}" && echo 1 || echo 0)"
        echo "IPV4=$(host_ipv4)"
        echo "AT=$(date '+%s')"
    } > "${f}.tmp" 2>/dev/null && mv -f "${f}.tmp" "${f}" 2>/dev/null
    chmod 644 "${f}" 2>/dev/null || true
    return 0
}

# 读取启动信息字段（$1=键名），输出值；文件不存在输出空
ldinfo_get()
{
    local f
    f=$(ldinfo_file) || return 0
    sed -n "s/^$1=//p" "${f}" 2>/dev/null | head -1
}

# 校验“记录的容器目录”确实是本次启动的容器：比较设备号。
# 设备号不同说明配置改过 CHROOT_DIR（或目录被重建），旧信息不可信。
ldinfo_valid()
{
    local f rec cur
    f=$(ldinfo_file) || return 1
    [ -s "${f}" ] || return 1
    rec=$(ldinfo_get DEV)
    [ -n "${rec}" ] || return 1
    cur=$(stat -c %d "${CHROOT_DIR}" 2>/dev/null)
    [ -n "${cur}" ] && [ "${rec}" = "${cur}" ]
}

# 检查 ldstatus 标记进程是否存活：锚点 pid + 进程名校验。
# 名称校验读 /proc/<pid>/cmdline 的 argv[0]（ldstatus 以 exec -a 改名）。
ldstatus_running()
{
    local ld_pid
    ld_pid=$(ldstatus_pid)
    [ -n "${ld_pid}" ] || return 1
    [ -r "/proc/${ld_pid}/cmdline" ] || return 1
    tr '\0' ' ' < "/proc/${ld_pid}/cmdline" | grep -q ldstatus
}

# 结束进程列表：入参为 pid 或 pid 文件路径（自动读取文件内数字 pid）。
# 先 TERM，等 1 秒，再对残留进程 KILL。
kill_pids()
{
    local items
    items="$@"
    local item pid killed=0
    local failed_pids=""
    # 第一轮：对所有存活 pid 发 TERM（不逐进程 sleep）
    for item in ${items}
    do
        [ -n "${item}" ] || continue
        pid="${item}"
        # pid 文件路径 → 读取文件内数字 pid（兼容 ssh do_stop 的调用方式）
        if [ -f "${item}" ]; then
            pid=$(head -1 "${item}" 2>/dev/null | tr -cd '0-9')
        fi
        [ -n "${pid}" ] || continue
        if kill -0 "${pid}" 2>/dev/null; then
            if kill "${pid}" 2>/dev/null; then
                killed=$((killed+1))
            else
                failed_pids="${failed_pids} ${pid}"
            fi
        fi
    done
    # 统一等 1 秒（不是每进程 1 秒，避免 N 进程 N 秒），再对仍未退出的发 KILL
    sleep 1
    for item in ${items}
    do
        [ -n "${item}" ] || continue
        pid="${item}"
        if [ -f "${item}" ]; then
            pid=$(head -1 "${item}" 2>/dev/null | tr -cd '0-9')
        fi
        [ -n "${pid}" ] || continue
        if kill -0 "${pid}" 2>/dev/null; then
            if kill -9 "${pid}" 2>/dev/null; then
                killed=$((killed+1))
            else
                failed_pids="${failed_pids} ${pid}"
            fi
        fi
    done
    # 终止失败的 pid 明确告警并计入返回值（原实现恒返回 0，
    # 且告警语句位于 return 之后不可达，失败完全不可见）
    [ -n "${failed_pids}" ] && msg "[警告] 以下进程终止失败:${failed_pids}"
    # 清理是尽力而为：进程本就不存在不算失败；无失败项即成功
    [ -z "${failed_pids}" ] && return 0 || return 1
}

# 删除文件列表
remove_files()
{
    local files
    files="$@"
    file
    for file in ${files}
    do
        rm -f "${file}"
    done
}

# 创建目录列表
make_dirs()
{
    local dirs
    dirs="$@"
    local dir
    for dir in ${dirs}
    do
        [ -d "${dir}" ] || mkdir -p "${dir}"
    done
}

################################################################################
# 容器内执行
################################################################################

# 构建期 statx 兼容层：LD_PRELOAD shim（statx_shim.c）拦截 libc statx()，
# 为缺少 STATX_MNT_ID 的旧内核补齐该掩码位。只影响构建期子进程，
# 部署结束后从容器中移除。
# 判断当前内核是否需要 statx 兼容层（仅 arm64 + 内核 < 5.8）
kernel_need_statx_shim()
{
    # 本项目只维护 arm64，shim 也只针对 arm64 容器验证
    [ "${ARCH}" = "arm64" ] || return 1
    local ver major minor
    ver=$(uname -r 2>/dev/null | cut -d. -f1-2)
    [ -n "${ver}" ] || return 1
    major=${ver%%.*}
    minor=${ver#*.}
    minor=${minor%%.*}
    if [ "${major}" -lt 5 ] || { [ "${major}" -eq 5 ] && [ "${minor}" -lt 8 ]; }; then
        return 0
    fi
    return 1
}

# 编译 statx 兼容层到临时目录（幂等，编译产物可跨部署复用）
statx_shim_ensure_compiled()
{
    [ -n "${STATX_SHIM_SO}" ] && [ -f "${STATX_SHIM_SO}" ] && return 0
    # 预编译兜底 1：构建机无 gcc 时，可直接把 statx_shim.so 放进 TEMP_DIR
    # （对应编译失败时的错误提示；此前该逃生通道未实现，放入不会被采纳）
    if [ -f "${TEMP_DIR}/statx_shim.so" ]; then
        STATX_SHIM_SO="${TEMP_DIR}/statx_shim.so"
        return 0
    fi
    # 预编译兜底 2：随 assets 分发的 glibc/arm64 预编译产物，无 gcc 环境开箱即用
    if [ -f "${ENV_DIR}/statx_shim.so" ]; then
        cp -f "${ENV_DIR}/statx_shim.so" "${TEMP_DIR}/statx_shim.so" 2>/dev/null || true
        if [ -f "${TEMP_DIR}/statx_shim.so" ]; then
            STATX_SHIM_SO="${TEMP_DIR}/statx_shim.so"
            return 0
        fi
    fi
    local src="${ENV_DIR}/statx_shim.c"
    if [ ! -f "${src}" ]; then
        msg "[跳过] 缺少 statx 兼容层源码: ${src}"
        return 1
    fi
    if ! command -v gcc >/dev/null 2>&1; then
        msg "[跳过] 宿主未安装 gcc，无法编译 statx 兼容层（旧内核 + systemd≥260 时 Kali 等构建可能失败）"
        return 1
    fi
    local out="${TEMP_DIR}/statx_shim.so"
    if ! gcc -shared -fPIC -O2 -Wall -o "${out}" "${src}" 2>"${TEMP_DIR}/statx_shim_build.log"; then
        msg "[警告] statx 兼容层编译失败，详情见 ${TEMP_DIR}/statx_shim_build.log（构建将继续，systemd≥260 的发行版可能失败）"
        return 1
    fi
    STATX_SHIM_SO="${out}"
    return 0
}

# 把 statx 兼容层装入当前容器（幂等，可在子 shell 中调用）
# 注意：component_exec 的每个组件都跑在子 shell 里，环境变量传不出去，
# 因此这里以"容器内存在 shim 文件"作为 chroot_exec 的注入开关，
# 而不是用 shell 变量。
statx_shim_install()
{
    kernel_need_statx_shim || return 1
    [ -d "${CHROOT_DIR}" ] || return 1
    statx_shim_ensure_compiled || return 1
    # 仅注入 glibc 容器：shim 按 glibc ABI 编译，musl（Alpine）无法加载
    if ! find "${CHROOT_DIR}" -maxdepth 3 -name "ld-linux-*.so*" 2>/dev/null | grep -q .; then
        msg "[跳过] 容器内未检测到 glibc（ld-linux），无需 statx 兼容层"
        return 1
    fi
    mkdir -p "${CHROOT_DIR}/usr/lib/linuxdeploy"
    cp -f "${STATX_SHIM_SO}" "${CHROOT_DIR}/usr/lib/linuxdeploy/statx-shim.so"
    chmod 755 "${CHROOT_DIR}/usr/lib/linuxdeploy/statx-shim.so"
    msg "[通过] 已启用 statx 兼容层（内核 $(uname -r | cut -d. -f1-2) < 5.8，为 systemd≥260 补齐 STATX_MNT_ID）"
    return 0
}

# 部署结束后移除 shim，避免污染运行时容器
statx_shim_cleanup()
{
    local shim_path="${CHROOT_DIR}/usr/lib/linuxdeploy/statx-shim.so"
    if [ -f "${shim_path}" ]; then
        rm -f "${shim_path}"
        rmdir "${CHROOT_DIR}/usr/lib/linuxdeploy" 2>/dev/null || true
        msg "[完成] 已移除构建期 statx 兼容层"
    fi
}

# 部署入口：编译兼容层；若容器已存在（重部署/导入 rootfs）则直接启用
statx_shim_prepare()
{
    kernel_need_statx_shim || return 0
    # 内核需要 shim 但编译失败时明确失败（fail-fast）：
    # 旧内核 + 无 gcc + 无预编译 shim 时若静默继续，部署会拖到 debootstrap
    # 阶段才因缺少 STATX_MNT_ID 报错，用户难以定位。此处提前中断并给出解法。
    if ! statx_shim_ensure_compiled; then
        msg "[错误] 当前内核（$(uname -r 2>/dev/null | cut -d. -f1-2)）缺少 STATX_MNT_ID，需要 statx 兼容层，但编译失败。"
        msg "       解决：安装 gcc 后重试，或把预编译的 statx_shim.so 放到 ${TEMP_DIR}/statx_shim.so。"
        return 1
    fi
    statx_shim_install || true
    return 0
}

# 错误捕获：CLI 顶层在非调试模式执行 exec 2>/dev/null，组件内命令的英文报错
# 只到 stderr，既不进 UI 也不进日志文件，最终只剩一句“部署失败”，用户无从排查。
# 这里在 stderr 上挂一份副本，统一加 "[错误]" 前缀写入日志文件；
# 部署失败收尾时由 ld_log_tail_errors 把最后几条回显到 stdout（UI 日志页可见）。
ld_capture_errors()
{
    [ -n "${LOG_FILE}" ] || return 0
    # 实现方式：把 stderr 接到临时文件（不依赖进程替换，任何 POSIX shell 可用），
    # 部署收尾时由 ld_collect_errors 把内容追加进日志并按需回显。
    LD_ERR_CAPTURE="${TEMP_DIR}/ld-stderr.$$"
    mkdir -p "${TEMP_DIR}" 2>/dev/null || return 0
    : > "${LD_ERR_CAPTURE}" 2>/dev/null || { LD_ERR_CAPTURE=""; return 0; }
    exec 2>>"${LD_ERR_CAPTURE}"
    return 0
}

# 收集 stderr 捕获内容：写入日志文件（带 [错误] 前缀），并输出最近 $1 行到 stdout
ld_collect_errors()
{
    local n="${1:-6}" errs
    [ -n "${LD_ERR_CAPTURE}" ] && [ -s "${LD_ERR_CAPTURE}" ] || return 0
    # 过滤常见噪音：无 tty 提示、dpkg 的 crontab/fonts 警告等不影响结果的行
    errs=$(grep -v -e 'not a tty' -e 'debconf: unable to initialize frontend' \
        -e 'No such file or directory$' "${LD_ERR_CAPTURE}" 2>/dev/null | tail -n "${n}")
    [ -n "${errs}" ] || errs=$(tail -n "${n}" "${LD_ERR_CAPTURE}" 2>/dev/null)
    if [ -n "${LOG_FILE}" ] && [ -n "${errs}" ]; then
        printf '%s\n' "${errs}" | while IFS= read -r _ld_line; do
            printf '%s [错误] %s\n' "$(date '+%F %T')" "${_ld_line}" >> "${LOG_FILE}"
        done
    fi
    [ -n "${errs}" ] && printf '%s\n' "${errs}"
    return 0
}

# 清理 stderr 捕获状态（恢复默认 stderr 并删除临时文件）
ld_capture_cleanup()
{
    [ -n "${LD_ERR_CAPTURE}" ] || return 0
    exec 2>/dev/null
    rm -f "${LD_ERR_CAPTURE}" 2>/dev/null
    LD_ERR_CAPTURE=""
    return 0
}

# 把日志文件里最近的错误行输出到 stdout（$1=条数，默认 5）
ld_log_tail_errors()
{
    local n="${1:-5}" line
    [ -s "${LOG_FILE}" ] || return 0
    grep '\[错误\]' "${LOG_FILE}" 2>/dev/null | tail -n "${n}" | while IFS= read -r line; do
        # 去掉日志行首的 "YYYY-MM-DD HH:MM:SS " 时间戳，避免与 UI 自身时间戳重复
        echo "${line#* * }"
    done
}

################################################################################
# 容器内包管理器（统一入口）
################################################################################
#
# 背景：这些安装函数最初只定义在 bootstrap/<发行版>/deploy.sh 里。
# 部署流程分两段执行（先 bootstrap 生成 rootfs，再执行 core/extra/init 等组件），
# 两段各自在独立子 shell 中运行，函数不会跨段保留。因此 core/hostname、
# extra/ssh、desktop/*、init/systemctl 等组件调用 apt_install 时，
# 会直接报 “apt_install: inaccessible or not found”（4.1.20 实测：
# Debian 部署在 extra/ssh 安装阶段失败）。
# 这里把安装函数下沉到 CLI 公共层，任何组件在任何阶段都能调用；
# bootstrap 组件内的同名定义已删除，避免两处实现不一致。

# Debian 系（debian/ubuntu/kali）：apt-get 更新索引并安装
apt_install()
{
    local packages
    packages="$@"
    [ -n "${packages}" ] || return 1
    (set -e
        log_exec chroot_exec -u root apt-get update -yq
        log_exec chroot_exec -u root "DEBIAN_FRONTEND=noninteractive apt-get install -yfq --no-install-recommends ${packages}"
        log_exec chroot_exec -u root apt-get clean
    exit 0)
    return $?
}

# Arch Linux：pacman 同步索引并安装（覆盖已有文件以避免包冲突中断）
pacman_install()
{
    local packages
    packages="$@"
    [ -n "${packages}" ] || return 1
    (set -e
        chroot_exec -u root pacman -Syq --overwrite="*" --noconfirm ${packages}
        rm -f "${CHROOT_DIR}"/var/cache/pacman/pkg/* || true
    exit 0)
    return $?
}

# Alpine：apk 更新索引并安装
apk_install()
{
    local packages
    packages="$@"
    [ -n "${packages}" ] || return 1
    (set -e
        chroot_exec -u root apk update || true
        chroot_exec -u root apk add --no-progress ${packages}
    exit 0)
    return $?
}

# Fedora：dnf 安装
dnf_install()
{
    local packages
    packages="$@"
    [ -n "${packages}" ] || return 1
    (set -e
        chroot_exec -u root dnf -y install ${packages}
    exit 0)
    return $?
}

# CentOS：yum 安装
yum_install()
{
    local packages
    packages="$@"
    [ -n "${packages}" ] || return 1
    (set -e
        chroot_exec -u root yum install ${packages} --nogpgcheck --skip-broken -y
        chroot_exec -u root yum clean all
    exit 0)
    return $?
}

# Slackware：slackpkg 安装
slackpkg_install()
{
    local packages
    packages="$@"
    [ -n "${packages}" ] || return 1
    (set -e
        chroot_exec -u root "yes | slackpkg -checkgpg=off -batch=on -default_answer=y update" || true
        chroot_exec -u root "yes | slackpkg -checkgpg=off -batch=on -default_answer=y install ${packages}"
    exit 0)
    return $?
}

# 把参数按 POSIX 单引号规则转义，供容器内 sh -c 安全还原。
# 用法：shell_quote "a b" → 'a b'；单引号写成 '\''
shell_quote()
{
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# 在 chroot 容器内执行命令
# 用法：chroot_exec [-u 用户] 命令 [参数...]
chroot_exec()
{
    # 清理可能干扰容器执行的环境变量
    unset TMP TEMP TMPDIR LD_DEBUG
    local path="${PATH}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    local username=""
    # 构建期 statx 兼容层注入开关：仅当部署流程把 shim 装进容器后才生效。
    # 注意：LD_PRELOAD 必须作用在"容器内被执行的程序"上，绝不能 export 给
    # 宿主侧 chroot 进程本身——宿主动态链接器会去解容器内路径的库，
    # 且 shim 依赖容器内的 libpthread，宿主上必然 "CANNOT LINK EXECUTABLE"。
    # 因此这里改为在容器内用 sh -c 显式带上环境变量前缀。
    local shim_lib="/usr/lib/linuxdeploy/statx-shim.so"
    local shim_preload=""
    if [ -e "${CHROOT_DIR}${shim_lib}" ]; then
        shim_preload="LD_PRELOAD=${shim_lib}"
    fi
    if [ "$1" = "-u" ]; then
        username="$2"
        shift 2
    fi
    # 本项目固定使用 chroot 方式（unshare 暂不支持）。
    # 所有 chroot 子进程统一关闭继承的 fd3（CLI exec 3>&1 保存的原始 stdout），
    # 防止容器内后台化且不主动关 fd 的常驻进程（ldstatus 等）攥住调用方管道。
    if [ -n "${username}" ]; then
        if [ $# -gt 0 ]; then
            if [ -n "${shim_preload}" ]; then
                # su 登录 shell 会清空环境变量，需在命令串里显式赋值
                chroot ${METHOD_OPTIONS} "${CHROOT_DIR}" /bin/su - ${username} -c "${shim_preload} $*" 3>&-
            else
                chroot ${METHOD_OPTIONS} "${CHROOT_DIR}" /bin/su - ${username} -c "$*" 3>&-
            fi
        else
            chroot ${METHOD_OPTIONS} "${CHROOT_DIR}" /bin/su - ${username} 3>&-
        fi
    else
        if [ -n "${shim_preload}" ]; then
            # 由容器内的 /bin/sh 解释命令串，LD_PRELOAD 只作用于其子进程。
            # 命令参数用 "sh -c '前缀 + 原命令'" 方式传递，保持原有参数边界。
            local cmd=""
            local a
            for a in "$@"; do
                cmd="${cmd} $(shell_quote "${a}")"
            done
            PATH="${path}" chroot ${METHOD_OPTIONS} "${CHROOT_DIR}" /bin/sh -c "${shim_preload}${cmd}" 3>&-
            return $?
        fi
        # 用 "$@" 保持参数边界，避免命令串被二次解析。
        PATH="${path}" chroot ${METHOD_OPTIONS} "${CHROOT_DIR}" "$@" 3>&-
    fi
}

################################################################################
# 参数系统
################################################################################

# 从配置文件读取参数到当前环境（KEY="value" 形式）
params_read()
{
    local conf_file="$1"
    [ -e "${conf_file}" ] || return 1
    local item key val
    while read item
    do
        # 仅接受全大写字母、数字、下划线的键名，防止注入
        key=$(echo "${item}" | grep -o '^[0-9A-Z_]\{1,32\}')
        val=${item#${key}=}
        # 剥掉值外层的一对引号：兼容 params_write 生成的 KEY="value" 格式
        # 与手写配置的单引号形式（原 eval 版本靠 eval 解析副作用剥引号，
        # 安全赋值后需显式处理，保证读入的值与配置文本一致）
        val=${val#\"}
        val=${val%\"}
        val=${val#\'}
        val=${val%\'}
        if [ -n "${key}" ]; then
            # 安全赋值：declare/nameref，值不再被二次解析（原 eval ${key}="${val}"
            # 在值含 $()、反引号、引号时可执行任意命令）
            ld_set_var "${key}" "${val}"
            if [ -n "${OPTLST##* ${key} *}" ]; then
                OPTLST="${OPTLST}${key} "
            fi
        fi
    done < "${conf_file}"
}

# 将当前环境中的参数写回配置文件
params_write()
{
    local conf_file="$1"
    [ -n "${conf_file}" ] || return 1
    # 原子写：先写临时文件，再 mv 覆盖目标。
    local tmp="${conf_file}.tmp.$$"
    local key val
    {
        echo "# ${conf_file##*/} $(date '+%F %R')"
        for key in ${OPTLST}
        do
            # 安全间接读取（替代 eval "val=\$${key}"）
            val=$(ld_get_var "${key}")
            if [ -n "${key}" ] && [ -n "${val}" ]; then
                echo "${key}=\"${val}\""
            fi
        done
    } > "${tmp}"
    mv -f "${tmp}" "${conf_file}"
}

# 解析命令行参数：--key=value 或 --key（布尔）
params_parse()
{
    OPTIND=1
    if [ $# -gt 0 ]; then
        local item key val
        for item in "$@"
        do
            key=$(expr "${item}" : '--\([0-9a-z-]\{1,32\}=\{0,1\}\)' | sed 'y/-abcdefghijklmnopqrstuvwxyz/_ABCDEFGHIJKLMNOPQRSTUVWXYZ/')
            if [ -n "${key##*=*}" ]; then
                val="true"
            else
                key=${key%*=}
                val=$(expr "${item}" : '--[0-9a-z-]\{1,32\}=\(.*\)')
            fi
            if [ -n "${key}" ]; then
                # 安全赋值：值含引号/命令替换也按字面处理（原 eval ${key}=\"${val}\"
                # 在值含 "、$() 等字符时可执行任意命令）
                ld_set_var "${key}" "${val}"
                OPTIND=$((OPTIND+1))
                if [ -n "${OPTLST##* ${key} *}" ]; then
                    OPTLST="${OPTLST}${key} "
                fi
            fi
        done
    fi
}

# 检查必填参数是否齐全
params_check()
{
    local params_list
    params_list="$@"
    local key val params_lost
    for key in ${params_list}
    do
        # 安全间接读取（替代 eval "val=\$${key}"）
        val=$(ld_get_var "${key}")
        if [ -z "${val}" ]; then
            params_lost="${params_lost} ${key}"
        fi
    done
    if [ -n "${params_lost}" ]; then
        msg "缺少必要参数:${params_lost}"
        return 1
    fi
    return 0
}

################################################################################
# 配置系统（4.1：无配置锁，统一 -c <配置名> 指定）

# 配置必需检查（无 -c 时容器操作命令拒绝执行）
require_config()
{
    [ -n "${CURRENT_CONF}" ] || { msg "请用 -c <配置名> 指定操作配置（config list/create 等配置管理命令除外）"; exit 1; }
}

# 校验配置名并返回配置文件路径
# 名称不含 / 时拼接 CONFIG_DIR；含 / 时按完整路径透传（高级用法），
# 但一律拒绝路径遍历（.. / ./ 分量），防止 ../../etc/passwd.conf 之类注入
config_file_of()
{
    local name="$1"
    [ -n "${name}" ] || return 1
    if [ -n "${name##*/*}" ]; then
        echo "${CONFIG_DIR}/${name}.conf"
    else
        case "/${name}/" in
        */../*|*/./*)
            msg "非法的配置路径（含路径遍历）: ${name}"
            return 1
        ;;
        esac
        echo "${name}"
    fi
}

# 配置是否存在
config_exists()
{
    conf_file
    local conf_file=$(config_file_of "$1")
    [ -e "${conf_file}" ]
}

# 获取当前配置的 CHROOT_DIR 默认值（隔离目录）
# 注意：默认值必须是“设备端”可写且可执行的系统目录 /data/local/tmp。
# 早期默认放在 BUILD_DIR（见下方 BUILD_DIR 定义），而 BUILD_DIR 会按
# ENV_DIR 推导成 /data/data/<包名>/files/builds —— 该目录对 root 虽然可写，
# 但在部分 ROM 上受应用数据目录权限/SELinux 约束，容器内服务（sshd 等）
# 读取 host key 与 /etc/shadow 时出现 EACCES，表现为“能启动但 SSH 不接受密码”。
# 与 App 推荐路径（StorageValidator）保持一致，均为 /data/local/tmp/<配置名>。
config_default_chroot_dir()
{
    echo "${LINUX_DEPLOY_DATA_DIR:-/data/local/tmp}/$1"
}

# 列出全部配置
config_list()
{
    local conf
    local count=0
    # --json 模式：输出机器可读列表（前端解析用）
    if [ "${JSON_MODE}" = "true" ]; then
        local first="true"
        local name distrib arch suite chroot_dir target_type
        printf '{\n'
        printf '  "configs": [\n'
        for conf in "${CONFIG_DIR}"/*.conf; do
            [ -e "${conf}" ] || continue
            # .conf 行形如 KEY="value"（前端/CLI 写入）或 KEY=value（手写），
            # 统一去掉 KEY= 前缀与可选引号（cut -d'"' 对无引号值会输出整行）
            name=$(basename "${conf}" .conf)
            distrib=$(grep '^DISTRIB=' "${conf}" | head -1 | sed -e 's/^[^=]*=//' -e 's/^"//' -e 's/"$//')
            arch=$(grep '^ARCH=' "${conf}" | head -1 | sed -e 's/^[^=]*=//' -e 's/^"//' -e 's/"$//')
            suite=$(grep '^SUITE=' "${conf}" | head -1 | sed -e 's/^[^=]*=//' -e 's/^"//' -e 's/"$//')
            chroot_dir=$(grep '^CHROOT_DIR=' "${conf}" | head -1 | sed -e 's/^[^=]*=//' -e 's/^"//' -e 's/"$//')
            target_type=$(grep '^TARGET_TYPE=' "${conf}" | head -1 | sed -e 's/^[^=]*=//' -e 's/^"//' -e 's/"$//')
            if [ "${first}" = "true" ]; then first="false"; else printf ',\n'; fi
            printf '    {"name": "%s", "distrib": "%s", "arch": "%s", "suite": "%s", "chroot_dir": "%s", "target_type": "%s"}' \
                "$(json_escape "${name}")" "$(json_escape "${distrib}")" "$(json_escape "${arch}")" \
                "$(json_escape "${suite}")" "$(json_escape "${chroot_dir}")" "$(json_escape "${target_type}")"
        done
        printf '\n  ]\n}\n'
        return 0
    fi
    msg "配置列表:"
    msg "--------------------------------------------------------------"
    msg "名称              发行版      架构      代号      容器目录"
    for conf in "${CONFIG_DIR}"/*.conf; do
        [ -e "${conf}" ] || continue
        count=$((count+1))
        # 参数化读取展示字段（不用 . "${conf}" source：配置文件可被用户/前端
        # 写入，source 会执行其中任意 shell 代码；与 --json 分支保持一致）
        local name distrib arch suite chroot_dir
        name=$(basename "${conf}" .conf)
        distrib=$(grep '^DISTRIB=' "${conf}" | head -1 | sed -e 's/^[^=]*=//' -e 's/^"//' -e 's/"$//')
        arch=$(grep '^ARCH=' "${conf}" | head -1 | sed -e 's/^[^=]*=//' -e 's/^"//' -e 's/"$//')
        suite=$(grep '^SUITE=' "${conf}" | head -1 | sed -e 's/^[^=]*=//' -e 's/^"//' -e 's/"$//')
        chroot_dir=$(grep '^CHROOT_DIR=' "${conf}" | head -1 | sed -e 's/^[^=]*=//' -e 's/^"//' -e 's/"$//')
        msg "$(printf "%-18s %-10s %-8s %-8s %s" "${name}" "${distrib}" "${arch}" "${suite}" "${chroot_dir}")"
    done
    msg "--------------------------------------------------------------"
    msg "共 ${count} 个配置"
}

# 显示配置详情（名称取参数或 -c 指定配置）
config_show()
{
    local name="${1:-${CURRENT_CONF}}"
    if [ -z "${name}" ]; then
        msg "用法: config show [配置名称]（或用 -c <配置名> config show）"
        return 1
    fi
    conf_file
    local conf_file=$(config_file_of "${name}")
    [ -e "${conf_file}" ] || { msg "配置不存在: ${name}"; return 1; }
    # --json 模式：输出配置键值对（前端解析用）
    if [ "${JSON_MODE}" = "true" ]; then
        local first="true"
        local line key val
        printf '{\n'
        printf '  "name": "%s",\n' "$(json_escape "${name}")"
        printf '  "config": {\n'
        while read line
        do
            case "${line}" in
            \#*|"") continue ;;
            esac
            key=$(echo "${line}" | grep -o '^[0-9A-Z_]\{1,32\}')
            [ -n "${key}" ] || continue
            val=${line#${key}=}
            val=${val#\"}
            val=${val%\"}
            if [ "${first}" = "true" ]; then first="false"; else printf ',\n'; fi
            printf '    "%s": "%s"' "${key}" "$(json_escape "${val}")"
        done < "${conf_file}"
        printf '\n  }\n}\n'
        return 0
    fi
    msg "配置名称: ${name}"
    msg "配置文件: ${conf_file}"
    msg "----------------------------------------"
    cat "${conf_file}"
    msg "----------------------------------------"
}

# 新建配置
# 用法: config create <名称> [--key=value ...]
config_create()
{
    local name="$1"
    [ -n "${name}" ] || { msg "用法: config create <配置名称> [--key=value ...]"; return 1; }
    # 名称合法性检查：仅允许字母数字下划线连字符
    case "${name}" in
    *[!a-zA-Z0-9_-]*)
        msg "配置名称只能包含字母、数字、下划线和连字符: ${name}"
        return 1
    ;;
    esac
    local conf_file
    conf_file=$(config_file_of "${name}")
    [ -e "${conf_file}" ] && { msg "配置已存在: ${name}"; return 1; }

    # 重置全部配置键，避免继承当前配置的旧值
    unset DISTRIB ARCH SUITE INCLUDE METHOD CHROOT_DIR TARGET_PATH SOURCE_PATH USER_NAME USER_PASSWORD EXTRA_PACKAGES USER_GROUPS MOUNTS SSH_PORT GRAPHICS TARGET_TYPE DISK_SIZE FS_TYPE DNS LOCALE HOST_NAME INIT INIT_LEVEL INIT_PATH
    # 先解析用户传入的参数（进入当前变量与 OPTLST）
    local OPTLST=" "
    params_parse "$@"
    # 记录用户是否显式指定了容器目录（此时仅命令行参数会写入 CHROOT_DIR）
    local user_chroot_dir="${CHROOT_DIR:-}"

    # 确保默认键都在参数表中（用户传入的键已存在）
    local key
    for key in DISTRIB ARCH SUITE INCLUDE METHOD CHROOT_DIR TARGET_PATH USER_NAME USER_PASSWORD USER_GROUPS MOUNTS SSH_PORT GRAPHICS TARGET_TYPE DISK_SIZE FS_TYPE INIT INIT_LEVEL
    do
        if [ -n "${OPTLST##* ${key} *}" ]; then
            OPTLST="${OPTLST}${key} "
        fi
    done

    # 默认参数（仅当用户未指定时生效）
    DISTRIB="${DISTRIB:-debian}"
    ARCH="${ARCH:-arm64}"
    SUITE="${SUITE:-trixie}"
    # 默认 INCLUDE 含 init 组件：启动容器时执行初始化脚本（默认 SysV，见 INIT 键）
    INCLUDE="${INCLUDE:-bootstrap init}"
    METHOD="${METHOD:-chroot}"
    # 初始化系统默认：Debian 系用 SysV（/etc/rc3.d），其余发行版用 run-parts
    # （/etc/rc.d，见主流程 INIT 兜底说明：非 Debian 系没有 rcN.d 布局）
    case "${DISTRIB}" in
    debian|ubuntu|kali) INIT="${INIT:-sysv}" ;;
    *) INIT="${INIT:-run-parts}" ;;
    esac
    INIT_LEVEL="${INIT_LEVEL:-3}"
    [ -n "${INIT_PATH}" ] || INIT_PATH="/etc/rc.d"
    USER_NAME="${USER_NAME:-root}"
    USER_PASSWORD="${USER_PASSWORD:-changeme}"
    USER_GROUPS="${USER_GROUPS:-aid_inet aid_sdcard_rw aid_graphics}"
    MOUNTS="${MOUNTS:-}"
    SSH_PORT="${SSH_PORT:-22}"
    GRAPHICS="${GRAPHICS:-}"
    # 安装方式：directory（目录）/ file（镜像文件）/ ram / partition。
    # 前端"镜像安装"映射为 file；FS_TYPE 默认 ext4（与前端"ext4 镜像"文案一致）。
    TARGET_TYPE="${TARGET_TYPE:-directory}"
    DISK_SIZE="${DISK_SIZE:-}"
    FS_TYPE="${FS_TYPE:-ext4}"
    # 未显式指定容器目录时，自动分配独立隔离目录（防止共享目录事故）
    if [ -z "${user_chroot_dir}" ]; then
        CHROOT_DIR=$(config_default_chroot_dir "${name}")
    fi
    # TARGET_PATH 默认与容器目录一致（rootfs 组件依赖此检查）
    TARGET_PATH="${TARGET_PATH:-${CHROOT_DIR}}"
    params_write "${conf_file}"

    msg "已创建配置: ${name}"
    msg "容器目录: ${CHROOT_DIR}"
    msg "提示: 后续操作请用 -c ${name} 指定该配置。"
}

# 编辑 -c 指定配置参数
# 用法: cli.sh -c <配置名> config edit [--key=value ...]
config_edit()
{
    local name="${CURRENT_CONF}"
    [ -n "${name}" ] || { msg "请用 -c <配置名> 指定要编辑的配置"; return 1; }
    conf_file
    local conf_file=$(config_file_of "${name}")
    [ -e "${conf_file}" ] || { msg "配置文件缺失: ${conf_file}"; return 1; }

    # 保存编辑前的配置备份
    cp "${conf_file}" "${conf_file}.bak"

    # 读取现有配置，再合并新参数
    local OPTLST=" "
    params_read "${conf_file}"
    params_parse "$@"
    params_write "${conf_file}"

    msg "已更新配置: ${name}"
}

# 复制配置
# 用法: config copy <源名称> <新名称>
config_copy()
{
    local src="$1"
    local dst="$2"
    [ -n "${src}" ] && [ -n "${dst}" ] || { msg "用法: config copy <源名称> <新名称>"; return 1; }
    config_exists "${src}" || { msg "源配置不存在: ${src}"; return 1; }
    config_exists "${dst}" && { msg "目标配置已存在: ${dst}"; return 1; }
    src_file dst_file
    local src_file=$(config_file_of "${src}")
    local dst_file=$(config_file_of "${dst}")
    cp "${src_file}" "${dst_file}"
    msg "已复制配置: ${src} -> ${dst}"
}

# 删除配置
# 用法: config delete <名称> [--purge]
# 默认仅删除配置；--purge 连同容器目录一起删除（需二次确认）
config_delete()
{
    local name="$1"
    [ -n "${name}" ] || { msg "用法: config delete <配置名称> [--purge]"; return 1; }
    config_exists "${name}" || { msg "配置不存在: ${name}"; return 1; }
    local purge="false"
    if [ "$2" = "--purge" ]; then
        purge="true"
    fi

    # 读取该配置的容器目录（参数化解析，不用 eval：
    # 配置文件若被植入 CHROOT_DIR=x; rm -rf / 之类内容会直接执行）
    conf_file chroot_dir
    local conf_file=$(config_file_of "${name}")
    local chroot_dir=""
    if [ -e "${conf_file}" ]; then
        chroot_dir=$(grep '^CHROOT_DIR=' "${conf_file}" | head -1 | sed -e 's/^[^=]*=//' -e 's/^"//' -e 's/"$//')
    fi

    msg "即将删除配置: ${name}"
    msg "配置文件: ${conf_file}"
    if [ "${purge}" = "true" ]; then
        msg "警告: --purge 将连同容器目录一起删除: ${chroot_dir}"
        confirm_yes "确认删除配置及容器目录？" || { msg "已取消。"; return 1; }
        if [ -n "${chroot_dir}" ] && [ -d "${chroot_dir}" ]; then
            rm -rf "${chroot_dir}"
            msg "已删除容器目录: ${chroot_dir}"
        fi
    else
        confirm_yes "确认删除该配置（容器目录数据保留）？" || { msg "已取消。"; return 1; }
    fi
    rm -f "${conf_file}" "${CONFIG_DIR}/${name}.ldstatus" "${CONFIG_DIR}/${name}.ldinfo"
    msg "已删除配置: ${name}"
}

# 导出 -c 指定配置到文件
# 用法: cli.sh -c <配置名> config export <文件>
config_export()
{
    local out_file="$1"
    [ -n "${out_file}" ] || { msg "用法: config export <导出文件>"; return 1; }
    local name="${CURRENT_CONF}"
    [ -n "${name}" ] || { msg "请用 -c <配置名> 指定要导出的配置"; return 1; }
    local conf_file=$(config_file_of "${name}")
    [ -e "${conf_file}" ] || { msg "配置文件缺失: ${conf_file}"; return 1; }
    cp "${conf_file}" "${out_file}"
    msg "已导出配置 ${name} 到: ${out_file}"
}

# 导入配置（从文件或已有配置名复制）
# 用法: config import <文件|名称>
config_import()
{
    local src="$1"
    local dst="$2"
    [ -n "${src}" ] || { msg "用法: config import <配置文件|配置名称> [新名称]"; return 1; }

    src_file
    if [ -f "${src}" ]; then
        src_file="${src}"
    elif config_exists "${src}"; then
        src_file=$(config_file_of "${src}")
    else
        msg "导入源不存在: ${src}"
        return 1
    fi

    # 目标名称：显式指定，或从文件名推导
    if [ -z "${dst}" ]; then
        dst=$(basename "${src_file}" .conf)
    fi
    dst_file
    local dst_file=$(config_file_of "${dst}")
    [ -e "${dst_file}" ] && { msg "目标配置已存在: ${dst}"; return 1; }

    # 复制并确保容器目录隔离
    cp "${src_file}" "${dst_file}"
    # 若导入的配置未指定 CHROOT_DIR 或与已有配置冲突，重新分配独立目录
    local imported_dir
    local imported_dir=$(grep '^CHROOT_DIR=' "${dst_file}" | head -1 | sed -e 's/^[^=]*=//' -e 's/^"//' -e 's/"$//')
    if [ -z "${imported_dir}" ]; then
        sed -i "s|^CHROOT_DIR=.*|CHROOT_DIR=\"$(config_default_chroot_dir "${dst}")\"|" "${dst_file}"
        imported_dir=$(config_default_chroot_dir "${dst}")
        msg "容器目录: ${imported_dir}"
    fi

    msg "已导入配置: ${dst}"
    msg "提示: 后续操作请用 -c ${dst} 指定该配置。"
}

################################################################################
# 组件系统
################################################################################

# 判断组件是否与当前发行版/架构/代号兼容
component_is_compatible()
{
    local target
    target="$@"
    [ -n "${target}" ] || return 0
    local item
    for item in ${target}
    do
        case "${DISTRIB}:${ARCH}:${SUITE}" in
        ${item})
            return 0
        ;;
        esac
    done
    return 1
}

# 判断组件是否被排除（deploy -n 指定）
component_is_exclude()
{
    local component="$1"
    [ -n "${component}" ] || return 1
    local item
    for item in ${EXCLUDE_COMPONENTS}
    do
        case "${component}" in
        ${item}*)
            return 0
        ;;
        esac
    done
    return 1
}

# 展开组件名中的参数引用（如 init/${INIT}）。
# 组件依赖解析是参数化读取、不做二次展开，DEPENDS 里写 init/${INIT} 会被当成
# 字面目录名"init/${INIT}"而跳过——曾导致初始化系统（systemctl/sysv）从不执行。
# 这里按当前配置参数补齐：未定义的变量剥掉一行（init/${INIT} → init），
# 下文再按"参数指向的子组件存在则用子组件"处理。
component_expand_name()
{
    local item raw var value out=""
    for item in $*
    do
        raw="${item}"
        while : ; do
            case "${raw}" in
            *'${'*'}'*)
                var="${raw#*\$\{}"
                var="${var%%\}*}"
                value=$(eval "printf '%s' \"\${${var}}\"")
                # 前面部分 + 变量值（未定义则为空）+ 后面部分
                raw="$(printf '%s' "${raw%%\$\{*}")${value}$(printf '%s' "${raw#*\$\{${var}\}}")"
            ;;
            *) break ;;
            esac
        done
        # 变量未定义时可能留下尾部斜杠（init/${INIT} → init/），去掉后即父目录
        [ -n "${raw}" ] && [ "${raw%/}" != "${raw}" ] && raw="${raw%/}"
        out="${out} ${raw}"
    done
    echo ${out}
}

# 递归解析组件依赖，按依赖顺序输出组件列表
component_depends()
{
    # 注意：必须写成 "local components" 后再单独赋值，不能写 local components="$@"。
    # mksh 的 local 即 typeset，会把展开后的每个词当作变量名处理：
    # "typeset: bootstrap/ubuntu: is not an identifier" 报错并中断本次递归，
    # 导致解析到 bootstrap 就停下，bootstrap/ubuntu、init、extra/ssh 全部丢失
    # （脚本按 bash 写、设备端用 mksh 跑，本地复现不出来）。
    local components
    components="$@"
    [ -n "${components}" ] || return 0
    # 递归解析必须全部用 local，否则内层调用会覆盖外层循环变量 component
    local component conf_file TARGET DEPENDS
    for component in ${components}
    do
        component="${component%/}"
        # 展开参数引用（如 init/${INIT} → init/systemctl）：DEPENDS 原样解析不展开，
        # 不处理会被当成字面目录名而静默跳过（初始化系统从不执行、本机 ssh 起不来）。
        case "${component}" in
        *'${'*)
            component=$(component_expand_name "${component}")
            [ -n "${component}" ] || continue
        ;;
        esac
        # 防止循环依赖
        [ -z "${IGNORE_DEPENDS##* ${component} *}" ] && continue
        IGNORE_DEPENDS="${IGNORE_DEPENDS}${component} "
        # 组件必须存在：缺失时明确提示（组件名拼错/conf 丢失最常见）。
        # 本函数运行在 $(...) 命令替换内（component_exec 依赖解析），提示
        # 必须写 stderr，否则会混进组件列表被当作组件名执行。
        conf_file="${INCLUDE_DIR}/${component}/deploy.conf"
        if [ ! -e "${conf_file}" ]; then
            msg_depends "组件 ${component} 不存在，已跳过（找不到 ${conf_file}）"
            continue
        fi
        # 读取组件声明（参数化解析，不用 eval $(grep ...)：
        # 组件配置文件若被篡改可执行任意命令）
        # 末尾的 "|| true" 不可省略：多数组件 conf 不写 TARGET=（grep 返回 1），
        # 而依赖解析处于命令替换中、继承调用方的 set -e——grep 失败会直接中断
        # 整棵递归树，后续组件（如 bootstrap/ubuntu、init、extra/ssh）被静默丢弃，
        # 表现为“执行计划只有 core 和 bootstrap、rootfs 从不安装”。
        TARGET=$(grep '^TARGET=' "${conf_file}" | head -1 | sed -e 's/^[^=]*=//' -e 's/^"//' -e 's/"$//') || true
        DEPENDS=$(grep '^DEPENDS=' "${conf_file}" | head -1 | sed -e 's/^[^=]*=//' -e 's/^"//' -e 's/"$//') || true
        # 参数化解析不会二次展开值内变量：DEPENDS 里写 ${DISTRIB} 之类
        # 会被当成字面目录名而静默跳过（历史上 bootstrap/${DISTRIB} 即栽在
        # 这里，导致发行版引导组件从不安装）。这里按当前配置参数展开；
        # 仍残留（变量未定义）时剥掉该段，降级为父目录（init/${INIT} → init）。
        case "${DEPENDS}" in
        *'${'*)
            DEPENDS=$(component_expand_name ${DEPENDS})
            case "${DEPENDS}" in
            *'${'*) DEPENDS=$(echo "${DEPENDS}" | sed -e 's#/\$[{][^}]*}##g' -e 's#[$][{][^}]*}##g') ;;
            esac
        ;;
        esac
        case "${TARGET}" in
        *'${'*) TARGET=$(component_expand_name ${TARGET}) ;;
        esac
        # 兼容性检查
        if [ "${WITHOUT_CHECK}" != "true" ]; then
            # 不兼容时写明原因：设备端曾出现"组件被静默跳过"反复排查困难，
            # 这里把组件名、TARGET 与当前的 发行版:架构:代号 一并写入日志。
            if ! component_is_compatible ${TARGET}; then
                msg_depends "组件 ${component} 与 ${DISTRIB}:${ARCH}:${SUITE} 不兼容，已跳过（TARGET=${TARGET:-空}）"
                continue
            fi
        fi
        if [ "${REVERSE_DEPENDS}" = "true" ]; then
            # 反向依赖模式（帮助场景）
            echo ${component}
            component_depends ${DEPENDS}
        else
            # 先处理依赖，再输出自身（拓扑顺序）
            component_depends ${DEPENDS}
            echo ${component}
        fi
    done
}

# 执行组件动作（安装/配置/启动/停止/状态）
component_exec()
{
    local components
    components="$@"
    if [ "${WITHOUT_DEPENDS}" != "true" ]; then
        components=$(IGNORE_DEPENDS=" " component_depends ${components})
    fi
    [ -n "${components}" ] || return 1
    (set -e
        for COMPONENT in ${components}
        do
            COMPONENT_DIR="${INCLUDE_DIR}/${COMPONENT}"
            [ -d "${COMPONENT_DIR}" ] || { msg_depends "组件目录不存在，跳过: ${COMPONENT_DIR}"; continue; }
            # 逐组件进度写日志：组件脚本在 set -e 下中途退出时，最后一条
            # "执行组件 X" 就是出错点，避免只看到前面几条配置日志就断了。
            log_note "执行组件 ${COMPONENT} (${DO_ACTION})"
            # 重置组件声明变量
            unset NAME DESC TARGET PARAMS DEPENDS EXTENDS
            TARGET='*:*:*'
            # 读取组件配置
            . "${COMPONENT_DIR}/deploy.conf"
            # 提供空动作默认实现
            do_install() { return 0; }
            do_configure() { return 0; }
            do_start() { return 0; }
            do_stop() { return 0; }
            do_status() { return 0; }
            do_help() { return 0; }
            # 加载组件自身及扩展脚本
            for component in ${EXTENDS} ${COMPONENT}
            do
                if [ -e "${INCLUDE_DIR}/${component}/deploy.sh" ]; then
                    . "${INCLUDE_DIR}/${component}/deploy.sh"
                fi
            done
            # 排除检查
            component_is_exclude ${COMPONENT} && continue
            # 参数完整性检查
            [ "${WITHOUT_CHECK}" != "true" ] && params_check ${PARAMS}
            # 执行动作
            [ "${DEBUG_MODE}" = "true" ] && msg "## ${COMPONENT} : ${DO_ACTION}"
            # DO_ACTION 白名单校验：仅允许预定义组件动作（含部署复合动作）。
            # 白名单之外的任何值一律拒绝，从机制上杜绝经 eval 执行任意代码。
            case "${DO_ACTION}" in
            'do_install && do_configure'|do_install|do_configure|do_start|do_stop|do_status|do_help)
                ;;
            *)
                msg "[错误] 非法的组件动作: ${DO_ACTION}"
                exit 1
            ;;
            esac
            set +e
            eval ${DO_ACTION} || exit 1
            set -e
        done
    exit 0)
    is_ok || return 1
}

# 列出组件（默认仅当前发行版兼容的）
component_list()
{
    local components
    components="$@"
    local component output DESC
    if [ -z "${components}" ]; then
        components=$(cd "${INCLUDE_DIR}" && find . -type f -name "deploy.conf" | while read f
            do
                component="${f%/*}"
                component="${component#*/}"
                echo "${component}"
            done)
    fi
    local components=$(IGNORE_DEPENDS=" " component_depends ${components} | sort)
    for component in $components
    do
        DESC=''
        # 参数化读取组件描述（不用 eval $(grep '^DESC=' ...)）
        DESC=$(grep '^DESC=' "${INCLUDE_DIR}/${component}/deploy.conf" | head -1 | sed -e 's/^[^=]*=//' -e 's/^"//' -e 's/"$//')
        output=$(printf "%-30s %.49s\n" "${component}" "${DESC}")
        msg "${output}"
    done
}

# 返回组件所在目录
component_dir()
{
    echo "${INCLUDE_DIR}/$1"
}

################################################################################
# 容器系统
################################################################################

# 判断容器是否已挂载
container_mounted()
{
    is_mounted "${CHROOT_DIR}"
}

# 挂载容器内 /sys/fs/cgroup（docker / containerd 的必要条件）
# 背景：安卓宿主的 cgroup 层级通常未挂载、只挂了部分子系统，或已被系统的
#       init 占用。容器内没有可用 cgroup 时 dockerd 直接启动失败。
# 策略：优先复用宿主已有的 cgroup 挂载（bind，避免破坏安卓自身的层级），
#       宿主完全没有时再在容器内自行挂一个 tmpfs + 各子系统（v1）或 cgroup2（v2）。
#       仅 chroot 方式、且 /sys 已挂载（否则容器内看不到 /sys/fs）时处理。
container_mount_cgroup()
{
    [ "${METHOD}" = "chroot" ] || return 0
    local cg_dir="${CHROOT_DIR}/sys/fs/cgroup"
    is_mounted "${CHROOT_DIR}/sys" || return 0
    if is_mounted "${cg_dir}"; then
        return 0
    fi
    [ -d "${cg_dir}" ] || mkdir -p "${cg_dir}"

    # 宿主已有 cgroup 挂载：整体 bind 进容器（只读层级也可用，容器只写自己的子树）
    if is_mounted "/sys/fs/cgroup"; then
        if ! mount -o bind "/sys/fs/cgroup" "${cg_dir}" 2>/dev/null; then
            msg "[提示] 无法挂载 cgroup（宿主 /sys/fs/cgroup 不可 bind），Docker 可能无法启动"
        fi
        return 0
    fi

    # 宿主没有 cgroup：v2（cgroup.controllers 存在表示内核已启用 v2）
    if [ -e "/sys/fs/cgroup/cgroup.controllers" ]; then
        mount -t cgroup2 none "${cg_dir}" 2>/dev/null && return 0
    fi
    # v1 兜底：统一挂 tmpfs 再按子系统分别挂载，失败项忽略（内核未编译该子系统）
    if mount -t tmpfs -o uid=0,gid=0,mode=0755 cgroup "${cg_dir}" 2>/dev/null; then
        local ctrl
        for ctrl in cpu cpuset cpuacct memory devices freezer net_cls net_prio blkio pids hugetlb perf_event; do
            [ -d "/sys/fs/cgroup/${ctrl}" ] || mkdir -p "${cg_dir}/${ctrl}"
            mount -t cgroup -o "${ctrl}" cgroup "${cg_dir}/${ctrl}" 2>/dev/null || true
        done
    fi
    # 挂载失败不算容器启动失败：仅 docker 受限，数据库等其它服务不受影响
    return 0
}

# 文件系统检查（仅对 file/partition 类型的容器有效）
fs_check()
{
    if is_mounted "${CHROOT_DIR}"; then
        return 1
    fi
    local checkfs=$(which e2fsck)
    if [ -z "${checkfs}" ]; then
        return 1
    fi
    case "${TARGET_TYPE}" in
    file|partition)
        ${checkfs} -p "${TARGET_PATH}" >/dev/null
        return 0
    ;;
    esac
    return 1
}

# 解析大小字符串为字节数（支持整数 K/M/G/T，不区分大小写）
# 用法: parse_size_bytes 4G → 4294967296；解析失败返回非 0
parse_size_bytes()
{
    local s="$1" num unit
    [ -n "${s}" ] || return 1
    s=$(printf '%s' "${s}" | tr '[:lower:]' '[:upper:]')
    case "${s}" in
    *K) num="${s%K}"; unit=1024 ;;
    *M) num="${s%M}"; unit=$((1024*1024)) ;;
    *G) num="${s%G}"; unit=$((1024*1024*1024)) ;;
    *T) num="${s%T}"; unit=$((1024*1024*1024*1024)) ;;
    *) num="${s}"; unit=1 ;;
    esac
    # 只保留整数部分（4.5G 这类小数暂不支持，直接截断）
    num=$(printf '%s' "${num}" | tr -cd '0-9')
    [ -n "${num}" ] && [ "${num}" -gt 0 ] 2>/dev/null || return 1
    echo $(( num * unit ))
}

# 调整 ext2/3/4 磁盘镜像大小（仅支持 TARGET_TYPE=file 的镜像安装）
# 流程：停止容器并卸载 → e2fsck 检查 → 扩容(先扩文件再扩文件系统)/
# 缩容(先缩文件系统再裁剪文件) → 复检 → 同步写回配置 DISK_SIZE。
# 用法: image_resize <新大小>，例如 8G / 512M
image_resize()
{
    local new_size="$1" new_bytes cur_bytes new_mb
    new_bytes=$(parse_size_bytes "${new_size}")
    if [ -z "${new_bytes}" ]; then
        msg "无法解析大小: ${new_size}（示例: 512M / 8G）"
        return 1
    fi
    if [ "${TARGET_TYPE}" != "file" ]; then
        msg "当前配置不是镜像安装（TARGET_TYPE=${TARGET_TYPE:-未设置}），无需调整镜像大小"
        return 1
    fi
    if [ ! -f "${TARGET_PATH}" ]; then
        msg "镜像文件不存在: ${TARGET_PATH}（部署后才会生成）"
        return 1
    fi
    cur_bytes=$(stat -c %s "${TARGET_PATH}" 2>/dev/null)
    if [ -z "${cur_bytes}" ]; then
        msg "无法读取镜像大小: ${TARGET_PATH}"
        return 1
    fi
    if [ "${cur_bytes}" -eq "${new_bytes}" ]; then
        msg "镜像大小已是 ${new_size}，无需调整"
        return 0
    fi

    # 调整前先停止容器并卸载挂载（避免文件系统忙）
    if container_mounted; then
        msg "正在停止容器并卸载挂载 ..."
        container_stop || return 1
    fi

    # 调整前检查文件系统
    local fsck_ok="false"
    msg -n "正在检查文件系统 ... "
    if command -v e2fsck >/dev/null 2>&1; then
        if e2fsck -fy "${TARGET_PATH}" >/dev/null 2>&1; then
            msg "完成"
            fsck_ok="true"
        else
            msg "失败（文件系统异常，建议先手动修复）"
            return 1
        fi
    else
        msg "跳过（未找到 e2fsck）"
    fi

    # resize2fs 裸数字按"块"解释，统一换算成 MB 后缀，避免歧义
    new_mb=$(( new_bytes / 1048576 ))
    [ "${new_mb}" -gt 0 ] || { msg "新大小过小（至少 1M）"; return 1; }

    if [ "${new_bytes}" -gt "${cur_bytes}" ]; then
        # 扩容：先扩大镜像文件，再扩大文件系统
        msg -n "正在扩容镜像文件 ... "
        truncate -s "${new_bytes}" "${TARGET_PATH}" || { msg "失败"; return 1; }
        msg "完成"
        msg -n "正在扩容文件系统 ... "
        resize2fs "${TARGET_PATH}" "${new_mb}M" || { msg "失败"; return 1; }
        msg "完成"
    else
        # 缩容：先缩小文件系统，再裁剪镜像文件。
        # 缩容是高危操作：e2fsck 不可用时无法验证文件系统一致性，
        # 一旦有未整理的数据分布在将被裁掉的区域，直接造成数据损坏——
        # 此时明确拒绝执行，而不是带着风险继续。
        if [ "${fsck_ok}" != "true" ]; then
            msg "[错误] 未找到 e2fsck，无法在缩容前校验文件系统，已中止（避免数据损坏）"
            msg "       请确认内置工具链完整（${TOOLS_DIR}）后重试。"
            return 1
        fi
        msg "[警告] 缩容有数据丢失风险：请确认已备份，且文件系统刚通过 e2fsck -f 整理。"
        msg -n "正在缩小文件系统 ... "
        resize2fs "${TARGET_PATH}" "${new_mb}M" || { msg "失败"; return 1; }
        msg "完成"
        msg -n "正在裁剪镜像文件 ... "
        truncate -s "${new_bytes}" "${TARGET_PATH}" || { msg "失败"; return 1; }
        msg "完成"
    fi

    # 调整后复检
    msg -n "正在复检文件系统 ... "
    if command -v e2fsck >/dev/null 2>&1; then
        if e2fsck -fy "${TARGET_PATH}" >/dev/null 2>&1; then
            msg "完成"
        else
            msg "警告（文件系统异常，请尽快备份数据）"
        fi
    else
        msg "跳过（未找到 e2fsck）"
    fi

    # 同步写回配置，避免下次部署按旧大小重建镜像
    params_parse --disk-size=${new_mb}
    params_write "${CONF_FILE}"
    msg "镜像已调整为: ${new_size}（${new_mb} MB）"
    return 0
}

# 挂载单个分区/虚拟文件系统
mount_part()
{
    case "$1" in
    root)
        msg -n "/ ... "
        if ! is_mounted "${CHROOT_DIR}" ; then
            # 目录型容器强制挂载源=容器目录：历史配置可能残留旧 TARGET_PATH
            # （如先建镜像后改目录、或旧版本未同步该字段），bind 挂旧路径会把
            # 空目录盖在部署内容上，表现为"部署成功但容器内一片空白"。
            if [ "${TARGET_TYPE}" = "directory" ] && [ "${TARGET_PATH}" != "${CHROOT_DIR}" ]; then
                msg "[提示] 目录安装的挂载源(${TARGET_PATH})与容器目录(${CHROOT_DIR})不一致，已按容器目录处理。"
                TARGET_PATH="${CHROOT_DIR}"
            fi
            # 防御拦截：目录型容器不允许放在共享存储（/storage/emulated/0、/sdcard 等）。
            # 共享存储禁止把文件当程序运行（noexec 被内核锁定），挂上后容器内所有命令
            # 都会 Permission denied；提前拦截并给出小白可读的修正指引。
            if [ -d "${TARGET_PATH}" ] && is_shared_storage "${TARGET_PATH}"; then
                msg "失败"
                msg "[提示] 容器路径在手机共享存储（/storage/emulated/0、/sdcard 这类放相册和下载的地方）。"
                msg "        系统规定共享存储里的文件不能当作程序运行，目录方式放这里会无法启动。"
                msg "        两个解决办法（改一下配置就好）："
                msg "          ① 把容器路径换成系统目录，如 /data/local/tmp/${CURRENT_CONF:-linux}；"
                msg "          ② 把安装方式改成「镜像（ext4 镜像文件）」——镜像文件放共享存储没问题。"
                return 1
            fi
            [ -d "${CHROOT_DIR}" ] || mkdir -p "${CHROOT_DIR}"
            local mnt_opts
            # 目录型容器使用 bind 挂载，文件型容器直接挂载
            [ -d "${TARGET_PATH}" ] && mnt_opts="bind" || mnt_opts="rw,relatime"
            if mount -o ${mnt_opts} "${TARGET_PATH}" "${CHROOT_DIR}"; then
                if mount -o remount,exec,suid,dev "${CHROOT_DIR}"; then
                    is_ok "失败" "完成"
                else
                    # remount 失败必须回滚：残留挂载会让状态查询误报"运行中"
                    umount "${CHROOT_DIR}" 2>/dev/null
                    msg "失败"
                    if [ "${mnt_opts}" = "bind" ]; then
                        msg "[提示] 挂载完成但无法开启「运行程序」权限，已自动撤销挂载。"
                        msg "        容器路径所在的存储不允许运行程序（如共享存储、部分外置存储卡）。"
                        msg "        请更换容器路径（如 /data/local/tmp/xxx）或改用镜像方式安装。"
                    else
                        msg "[提示] 无法开启「运行程序」权限，已自动撤销挂载，请检查容器路径所在的存储。"
                    fi
                    return 1
                fi
            else
                msg "失败"
                msg "[提示] 无法挂载容器路径: ${TARGET_PATH}"
                msg "        请确认路径以 / 开头（绝对路径）且真实存在。"
                return 1
            fi
        else
            msg "跳过"
        fi
    ;;
    proc)
        msg -n "/proc ... "
        local target="${CHROOT_DIR}/proc"
        if ! is_mounted "${target}" ; then
            [ -d "${target}" ] || mkdir -p "${target}"
            mount -t proc proc "${target}"
            is_ok "失败" "完成" || return 1
        else
            msg "跳过"
        fi
    ;;
    sys)
        msg -n "/sys ... "
        local target="${CHROOT_DIR}/sys"
        if ! is_mounted "${target}" ; then
            [ -d "${target}" ] || mkdir -p "${target}"
            mount -t sysfs sys "${target}"
            is_ok "失败" "完成" || return 1
        else
            msg "跳过"
        fi
    ;;
    dev)
        msg -n "/dev ... "
        local target="${CHROOT_DIR}/dev"
        if ! is_mounted "${target}" ; then
            [ -d "${target}" ] || mkdir -p "${target}"
            mount -o bind /dev "${target}"
            is_ok "失败" "完成" || return 1
        else
            msg "跳过"
        fi
    ;;
    shm)
        msg -n "/dev/shm ... "
        if ! is_mounted "/dev/shm" ; then
            [ -d "/dev/shm" ] || mkdir -p /dev/shm
            mount -o rw,nosuid,nodev,mode=1777 -t tmpfs tmpfs /dev/shm
        fi
        local target="${CHROOT_DIR}/dev/shm"
        if ! is_mounted "${target}" ; then
            mount -o bind /dev/shm "${target}"
            is_ok "失败" "完成" || return 1
        else
            msg "跳过"
        fi
    ;;
    pts)
        msg -n "/dev/pts ... "
        local pts_target="${CHROOT_DIR}/dev/pts"
        if ! is_mounted "${pts_target}" ; then
            # devpts 已挂载（宿主或上一次容器会话）时直接 bind；
            # 否则先在容器内挂一份 devpts，失败再退回 bind 宿主 /dev/pts
            if ! is_mounted "/dev/pts" ; then
                [ -d "/dev/pts" ] || mkdir -p /dev/pts
                mount -o rw,nosuid,noexec,gid=5,mode=620,ptmxmode=000 -t devpts devpts "${pts_target}" 2>/dev/null || true
            fi
            if ! is_mounted "${pts_target}" ; then
                [ -d "${pts_target}" ] || mkdir -p "${pts_target}"
                mount -o bind /dev/pts "${pts_target}"
            fi
            is_ok "失败" "完成" || return 1
        else
            msg "跳过"
        fi
    ;;
    fd)
        if [ ! -e "/dev/fd" -o ! -e "/dev/stdin" -o ! -e "/dev/stdout" -o ! -e "/dev/stderr" ]; then
            msg -n "/dev/fd ... "
            [ -e "/dev/fd" ] || ln -s /proc/self/fd /dev/
            [ -e "/dev/stdin" ] || ln -s /proc/self/fd/0 /dev/stdin
            [ -e "/dev/stdout" ] || ln -s /proc/self/fd/1 /dev/stdout
            [ -e "/dev/stderr" ] || ln -s /proc/self/fd/2 /dev/stderr
            is_ok "失败" "完成"
        fi
    ;;
    tty)
        if [ ! -e "/dev/tty0" ]; then
            msg -n "/dev/tty ... "
            ln -s /dev/null /dev/tty0
            is_ok "失败" "完成"
        fi
    ;;
    tun)
        if [ ! -e "/dev/net/tun" ]; then
            msg -n "/dev/net/tun ... "
            [ -d "/dev/net" ] || mkdir -p /dev/net
            mknod /dev/net/tun c 10 200
            is_ok "失败" "完成"
        fi
    ;;
    binfmt_misc)
        # 支持跨架构时挂载 binfmt_misc
        multiarch_support || return 0
        local binfmt_dir="/proc/sys/fs/binfmt_misc"
        if ! is_mounted "${binfmt_dir}" ; then
            msg -n "${binfmt_dir} ... "
            mount -t binfmt_misc binfmt_misc "${binfmt_dir}"
            is_ok "失败" "完成"
        fi
    ;;
    esac

    return 0
}

# 挂载容器（默认挂载全部虚拟文件系统）
container_mount()
{
    [ "${METHOD}" = "chroot" ] || return 0

    if [ $# -eq 0 ]; then
        container_mount root proc sys dev shm pts fd tty tun binfmt_misc
        local rc=$?
        # cgroup 依赖 /sys 已挂载，单独处理且失败不阻断容器启动
        container_mount_cgroup
        return ${rc}
    fi

    params_check TARGET_PATH || return 1

    msg -n "检查文件系统 ... "
    fs_check
    is_ok "跳过" "完成"

    msg "正在挂载容器: "
    local item
    for item in $*
    do
        mount_part ${item} || return 1
    done

    return 0
}

# 卸载容器
container_umount()
{
    params_check TARGET_PATH || return 1
    container_mounted || { msg "容器未挂载。" ; return 0; }

    msg -n "释放资源 ... "
    # 结束容器内全部进程：get_pids 按 /proc/<pid>/root 匹配容器目录，不依赖
    # lsof（安卓普遍没有 lsof；原实现仅在 lsof 存在时取列表，于是默认什么都不杀，
    # 容器进程一直占着挂载点，umount 连续重试也失败）。
    local pids
    pids=$(get_pids)
    kill_pids ${pids}; is_ok "失败" "完成"
    # 进程已结束：清掉配置侧 ldstatus 锚点与启动信息，避免 status 继续判定"运行中"
    remove_ldstatus_anchor
    [ -n "${CURRENT_CONF}" ] && rm -f "${CONFIG_DIR}/${CURRENT_CONF}.ldinfo" 2>/dev/null

    msg "正在卸载分区: "
    local is_mnt=0
    # 必须按挂载层级从深到浅卸载（先 /proc、/dev/pts 等，最后容器根本身）。
    # 按字符串倒序不够：/dev/shm 与 /dev/pts 的先后无保证；一旦先卸掉根挂载，
    # 剩余子挂载会变成 "Invalid argument" 无法卸载，残留的 /proc /dev 让
    # 状态判定一直为"运行中"（表现为停止后 UI 仍显示运行中）。
    # 同一挂载点在 /proc/mounts 里可能重复出现，去重后再处理。
    local parts=$(awk -v base="${CHROOT_DIR%/}" '$2==base || index($2, base"/")==1 {print $2}' /proc/mounts \
        | awk '!seen[$0]++ { n=split($0, a, "/"); print n"\t"$0 }' | sort -rn | cut -f2)
    local part
    for part in ${parts}
    do
        local part_name=$(echo ${part} | sed "s|^${CHROOT_DIR%/}/*|/|g")
        [ -n "${part_name}" ] || part_name="/"
        msg -n "${part_name} ... "
        local i
        for i in 1 2 3
        do
            # 用 -l 懒卸载：仍有进程占用时先脱离挂载点再回收，减少残留
            umount -l ${part} 2>/dev/null && break
            umount ${part} && break
            sleep 1
        done
        is_ok "失败" "完成"
        is_mnt=1
    done
    [ "${is_mnt}" -eq 1 ]; is_ok " ...没有已挂载分区"

    # 兜底复检：仍有残留时再循环卸载几轮（进程退出/懒卸载回收有延迟）
    local round
    for round in 1 2 3
    do
        container_mounted || break
        grep -q "${CHROOT_DIR%/}" /proc/mounts || break
        sleep 1
        for part in $(awk -v base="${CHROOT_DIR%/}" '$2==base || index($2, base"/")==1 {print $2}' /proc/mounts \
            | awk '!seen[$0]++ { n=split($0, a, "/"); print n"\t"$0 }' | sort -rn | cut -f2)
        do
            umount -l ${part} 2>/dev/null || true
        done
    done

    # 释放 loop 设备
    local loop
    if command -v losetup >/dev/null 2>&1; then
        loop=$(losetup -a | grep "${TARGET_PATH%/}" | awk -F: '{print $1}')
        if [ -n "${loop}" ]; then
            msg -n "解除 loop 设备关联 ... "
            losetup -d "${loop}"
            is_ok "失败" "完成"
        fi
    fi

    return 0
}

# 查找可用的 nsenter：依次尝试 PATH、/system/bin、/system/xbin、打包 busybox。
# 输出可直接执行的 nsenter 命令串；找不到返回非 0。
nsenter_bin()
{
    local c
    if command -v nsenter >/dev/null 2>&1; then
        command -v nsenter
        return 0
    fi
    for c in /system/bin/nsenter /system/xbin/nsenter "${ENV_DIR}/tools/busybox"; do
        if [ -x "${c}" ]; then
            if [ "${c##*/}" = "busybox" ]; then
                echo "${c} nsenter"
            else
                echo "${c}"
            fi
            return 0
        fi
    done
    return 1
}

# 跨命名空间执行容器命令：当前命名空间看不到容器挂载且 ldstatus 存活时，
# 经 nsenter 切入 ldstatus 所在挂载命名空间，重新执行本命令。
# 前置判定：ldstatus 存活（pid+进程名校验）确认容器确在运行才切入。
# LD_NSENTER=1 防递归（切入后的实例不再切入）。
container_nsenter_run()
{
    [ "${LD_NSENTER}" = "1" ] && return 1    # 已切入，防递归
    ldstatus_running || return 1             # 容器必须确认为运行中
    local ld_pid ns_bin
    ld_pid=$(ldstatus_pid)
    [ -n "${ld_pid}" ] || return 1
    ns_bin=$(nsenter_bin) || { msg "[警告] 容器运行在其它挂载命名空间，但未找到可用的 nsenter"; return 1; }
    msg "统一命名空间操作：经 ldstatus（pid ${ld_pid}）切入容器命名空间执行 ..."
    # 以 sh 显式解释器执行（直接 exec 时脚本 shebang 在目标命名空间不可解析）；
    # -c 显式指定当前配置名。
    LD_NSENTER=1 ${ns_bin} -t ${ld_pid} -m -- sh "${ENV_DIR}/cli.sh" -c "${CURRENT_CONF}" "$@" </dev/null
    return $?
}

# 启动容器：自动挂载系统文件（proc/sys/dev 等）后执行组件启动。
# 自定义挂载点（MOUNTS 的 "源:目标"）由 core/mnt 组件的 do_start 负责挂载，
# 因此 start 一步到位，不需要像原版那样先手动 mount。
container_start()
{
    # 未挂载则自动挂载；根已挂载但 /proc 缺失时补齐（如部署后直接 start）
    if ! container_mounted; then
        # 挂载不可见但 ldstatus 存活：容器运行在其它命名空间，跳过启动（stop 会自动切入）
        if ldstatus_running; then
            msg "[提示] 容器运行在其它挂载命名空间中，启动已跳过；请执行 stop 停止（将自动切入命名空间）"
            return 0
        fi
        container_mount || return 1
    elif ! is_mounted "${CHROOT_DIR}/proc"; then
        container_mount >/dev/null 2>&1 || true
    else
        # 已挂载（如部署后直接 start）：补上可能缺失的 cgroup
        container_mount_cgroup
    fi

    local DO_ACTION='do_start'
    if [ $# -gt 0 ]; then
        component_exec "$@" || msg "[警告] 部分组件启动失败（容器已启动，可进入终端检查）"
    else
        component_exec "${INCLUDE}" || msg "[警告] 部分组件启动失败（容器已启动，可进入终端检查）"
    fi
    # 启动信息落盘：供其它命名空间下的 status 还原运行/网络状态（UI 与 SSH 一致）
    ldinfo_write
    return 0
}

# 停止容器：执行组件停止后自动卸载全部挂载，一步到位。
# 与"服务器关机"对齐：停止 = 关掉容器里跑的东西 + 撤掉挂载，容器磁盘内容原样保留。
# 因此下面两步都做尽力而为，任一步失败只告警、不阻断另一步，也不让 stop 整体失败——
# 否则组件 do_stop 出点小错（或 init 组件按发行版参数化、模板未展开）就会"点停止没反应"。
container_stop()
{
    # 统一命名空间操作：锚点有效（容器运行中）一律切入容器命名空间执行 stop，
    # 只取真正的停止结果；切入本身失败（组件报错）不提前返回。
    if [ "${LD_NSENTER}" != "1" ]; then
        container_nsenter_run stop "$@" && return 0
    fi
    if ! container_mounted; then
        msg "容器未挂载，无需停止。"
        return 0
    fi

    local DO_ACTION='do_stop'
    # 组件显式传入时按其顺序执行；默认全部组件一次执行完再卸载。
    # ldstatus 兜底放在最后，保证容器内服务先从容退出、常驻进程最后才被强杀。
    local rc=0
    if [ $# -gt 0 ]; then
        component_exec "$@" || rc=1
        component_exec core/ldstatus >/dev/null 2>&1 || true
    else
        component_exec "${INCLUDE}" || rc=1
        # 兜底：组件执行中途失败时 ldstatus 可能没轮到，显式补一次
        ldstatus_running && { component_exec core/ldstatus >/dev/null 2>&1 || true; }
    fi
    [ ${rc} -ne 0 ] && msg "[警告] 部分组件停止失败，继续结束容器进程并卸载挂载"

    # 停止后自动卸载（不学原版的分步复杂化）
    if container_mounted >/dev/null 2>&1; then
        msg "正在卸载容器挂载 ..."
        container_umount
    fi

    return ${rc}
}

# 重启容器：停止 → 等待 3 秒 → 启动。
# 用途：容器内 reboot 接管脚本（经 unchroot 在宿主侧调用）与手动 cli.sh restart。
# 设计（2026-09 讨论后定案）：直接复用既有的 stop / start 全流程，不自研"清进程重拉"半套逻辑。
# 原因是 mount namespace 的生存规则因设备而异：
#   - k30p 这类是全局挂载：容器挂载在全局 ns 里，清进程不会掉挂载；
#   - 另一类是独立（每会话）命名空间：容器内进程一旦清空，ns 即被回收，挂载随之消失，
#     此时重新启动本来就必须重新 mount。
# 两种形态下 stop + start 都成立，通用不出错；且 stop 会顺带清掉长期运行累积的
# 挂载叠加层，状态最干净。
# 命名空间要点：整段（停止 + 重新挂载 + 组件重拉）必须在同一个 ns 内完成，
# 因此容器运行中先经锚点切入它自己的 ns 再执行（该 ns 正是当初挂载发生的地方，
# 具备挂载能力）；容器未运行则直接走 start。
container_restart()
{
    # 统一命名空间操作：锚点有效（容器运行中）先切入容器 mount ns 再执行；未运行则直接启动
    if [ "${LD_NSENTER}" != "1" ] && container_nsenter_run restart "$@"; then
        return 0
    fi

    params_check TARGET_PATH || return 1

    msg "正在重启容器：停止 → 等待 3 秒 → 启动 ..."
    container_stop "$@" || msg "[警告] 停止阶段有失败项，继续执行启动"
    sleep 3
    container_start "$@"
    return $?
}

# 进入容器 shell
container_shell()
{
    # 已挂载（运行中）的容器直接进入，不重复挂载、不重复启动组件；
    # 未挂载才挂载 root 并启动 core 组件（用户要求：先启动系统再直接 chroot 登录）
    if ! container_mounted; then
        container_mount || return 1
        local DO_ACTION='do_start'
        component_exec core
    fi

    local USER="root"
    # 按真实文件探测容器内 shell（排除符号链接），缺失则退回 sh/ash。
    local SHELL=""
    local candidate
    for candidate in /bin/bash /usr/bin/bash /bin/sh /usr/bin/sh /bin/dash /usr/bin/dash /bin/ash /usr/bin/ash
    do
        if [ -f "${CHROOT_DIR}${candidate}" ] && [ ! -L "${CHROOT_DIR}${candidate}" ] && [ -x "${CHROOT_DIR}${candidate}" ]; then
            SHELL="${candidate}"
            break
        fi
    done
    if [ -z "${SHELL}" ]; then
        msg "[错误] 容器内未找到可用 shell（bash/sh 均缺失），容器不完整，请重新部署"
        return 1
    fi
    # 动态链接 shell 依赖动态链接器（ld-linux），缺失则判定容器不完整
    local ld_found=""
    local ld_cand
    for ld_cand in "${CHROOT_DIR}"/lib/ld-linux* "${CHROOT_DIR}"/usr/lib/ld-linux* "${CHROOT_DIR}"/lib64/ld-linux*
    do
        [ -e "${ld_cand}" ] && ld_found="yes" && break
    done
    if [ -z "${ld_found}" ]; then
        msg "[错误] 容器内缺少动态链接器（ld-linux），bash 无法执行，请重新部署"
        return 1
    fi
    local HOME="$(user_home ${USER})"
    [ -n "${TERM}" ] || TERM="linux"
    [ -n "${PS1}" ] || PS1="\u@\h:\w\\$ "
    export USER SHELL HOME TERM PS1

    if [ -e "${CHROOT_DIR}/etc/motd" ]; then
        msg $(cat "${CHROOT_DIR}/etc/motd")
    fi

    # 支持 shell -c "命令"：chroot 本身不识别 -c，需显式转交给容器内 shell
    if [ "${1}" = "-c" ]; then
        shift
        chroot_exec "${SHELL}" -c "$*" 2>&1
    else
        chroot_exec "${SHELL}" 2>&1
    fi

    return $?
}

################################################################################
# rootfs 导入 / 导出
################################################################################

# 导入 rootfs 归档到当前容器
# 支持格式：tar, tar.gz, tar.bz2, tar.xz, tar.zst
rootfs_import()
{
    local rootfs_file="$1"
    [ -n "${rootfs_file}" ] || { msg "用法: import <归档文件|URL>"; return 1; }

    container_mounted || container_mount root || return 1

    msg -n "正在导入 rootfs ... "
    local ok="false"
    case "${rootfs_file}" in
    *tar|*tar.gz|*tgz|*tar.bz2|*tbz2|*tar.xz|*txz|*tar.zst|*tzst)
        if [ -e "${rootfs_file}" ]; then
            tar axf "${rootfs_file}" -C "${CHROOT_DIR}" && ok="true"
        elif [ -z "${rootfs_file##http*}" ]; then
            wget -q -O - "${rootfs_file}" | tar ax -C "${CHROOT_DIR}" && ok="true"
        fi
    ;;
    *gz)
        if [ -e "${rootfs_file}" ]; then
            tar axf "${rootfs_file}" -C "${CHROOT_DIR}" && ok="true"
        elif [ -z "${rootfs_file##http*}" ]; then
            wget -q -O - "${rootfs_file}" | tar xz -C "${CHROOT_DIR}" && ok="true"
        fi
    ;;
    *bz2)
        if [ -e "${rootfs_file}" ]; then
            tar axf "${rootfs_file}" -C "${CHROOT_DIR}" && ok="true"
        elif [ -z "${rootfs_file##http*}" ]; then
            wget -q -O - "${rootfs_file}" | tar xj -C "${CHROOT_DIR}" && ok="true"
        fi
    ;;
    *xz)
        if [ -e "${rootfs_file}" ]; then
            tar axf "${rootfs_file}" -C "${CHROOT_DIR}" && ok="true"
        elif [ -z "${rootfs_file##http*}" ]; then
            wget -q -O - "${rootfs_file}" | tar xJ -C "${CHROOT_DIR}" && ok="true"
        fi
    ;;
    *zst)
        if [ -e "${rootfs_file}" ]; then
            tar axf "${rootfs_file}" -C "${CHROOT_DIR}" && ok="true"
        elif [ -z "${rootfs_file##http*}" ]; then
            wget -q -O - "${rootfs_file}" | tar x --zstd -C "${CHROOT_DIR}" && ok="true"
        fi
    ;;
    *)
        msg "失败"
        msg "不支持的文件格式，仅支持 tar/tar.gz/tar.bz2/tar.xz/tar.zst。"
        return 1
    ;;
    esac

    if [ "${ok}" = "true" ]; then
        msg "完成"
        return 0
    else
        msg "失败"
        return 1
    fi
}

# 导出当前容器为 rootfs 归档
# 支持格式：gz, bz2, xz, zst
rootfs_export()
{
    local rootfs_file="$1"
    [ -n "${rootfs_file}" ] || { msg "用法: export <归档文件>"; return 1; }

    container_mounted || container_mount root || return 1

    msg -n "正在导出 rootfs ... "
    local ok="false"
    case "${rootfs_file}" in
    *gz)
        tar acf "${rootfs_file}" --exclude='./dev' --exclude='./sys' --exclude='./proc' -C "${CHROOT_DIR}" . >/dev/null && ok="true"
    ;;
    *bz2)
        tar acf "${rootfs_file}" --exclude='./dev' --exclude='./sys' --exclude='./proc' -C "${CHROOT_DIR}" . >/dev/null && ok="true"
    ;;
    *xz)
        tar acf "${rootfs_file}" --exclude='./dev' --exclude='./sys' --exclude='./proc' -C "${CHROOT_DIR}" . >/dev/null && ok="true"
    ;;
    *zst)
        tar acf "${rootfs_file}" --exclude='./dev' --exclude='./sys' --exclude='./proc' -C "${CHROOT_DIR}" . >/dev/null && ok="true"
    ;;
    *)
        msg "失败"
        msg "不支持的文件格式，仅支持 gz/bz2/xz/zst。"
        return 1
    ;;
    esac

    if [ "${ok}" = "true" ]; then
        msg "完成"
        return 0
    else
        msg "失败"
        return 1
    fi
}

################################################################################
# 容器状态
################################################################################

# 显示容器与系统状态
container_status()
{
    # --json 模式：输出机器可读状态（前端解析用）
    if [ "${JSON_MODE}" = "true" ]; then
        local model="" android="" arch="" kernel=""
        local mem_total=0 mem_used=0 swap_total=0 swap_used=0
        local selinux=false loop=false binfmt=false mounted=false running=false
        local installed="未知" supported_fs="" ipv4=""
        if command -v getprop >/dev/null 2>&1; then
            model=$(getprop ro.product.model 2>/dev/null)
            android=$(getprop build.version.release 2>/dev/null)
            [ -n "${android}" ] || android=$(getprop ro.build.version.release 2>/dev/null)
        fi
        arch=$(uname -m)
        kernel=$(uname -r)
        mem_total=$(grep ^MemTotal /proc/meminfo | awk '{print $2}')
        mem_total=$(( ${mem_total:-0}/1024 ))
        mem_used=$(( mem_total - $(grep ^MemFree /proc/meminfo | awk '{print $2}')/1024 ))
        swap_total=$(grep ^SwapTotal /proc/meminfo | awk '{print $2}')
        swap_total=$(( ${swap_total:-0}/1024 ))
        swap_used=$(( swap_total - $(grep ^SwapFree /proc/meminfo | awk '{print $2}')/1024 ))
        selinux_inactive || selinux=true
        loop_support && loop=true
        multiarch_support && binfmt=true
        supported_fs=$(printf '%s ' $(grep -v nodev /proc/filesystems | sort))
        # running 判定：ldstatus 标记进程（跨命名空间）为主，挂载兜底（旧容器无标记）
        container_mounted >/dev/null 2>&1 && mounted=true
        [ "${mounted}" = "true" ] && running=true
        ldstatus_running && running=true
        # App 每次 su -c 都在独立挂载命名空间：当前命名空间通常看不到容器挂载，
        # 直接用 CHROOT_DIR 读 os-release / 遍历进程都会得到错误结果
        # （UI 显示“已停止/SSH 未运行”，但容器实际在跑、SSH 也能连）。
        # 启动时已把容器设备号与网络信息写入 ${CONFIG_DIR}/<配置名>.ldinfo，
        # 这里优先据此判定 mounted / ipv4，保证 UI 与真实状态一致。
        if ldinfo_valid; then
            [ "$(ldinfo_get MOUNTS)" = "1" ] && mounted=true
            running=true
            [ -n "${ipv4}" ] || ipv4=$(ldinfo_get IPV4)
        fi
        if [ -r "${CHROOT_DIR}/etc/os-release" ]; then
            # 参数化读取 PRETTY_NAME（不用 . source：os-release 来自导入的
            # rootfs，内容外部可控，source 会执行其中任意 shell 代码）
            installed=$(grep '^PRETTY_NAME=' "${CHROOT_DIR}/etc/os-release" | head -1 | sed -e 's/^[^=]*=//' -e 's/^"//' -e 's/"$//')
            [ -n "${installed}" ] || installed="未知"
        fi
        [ -n "${ipv4}" ] || ipv4=$(host_ipv4)
        # ssh 独立判定（供前端显示/排障：容器运行但 sshd 未起时能直接看出来）
        local ssh_enabled=false ssh_running=false
        case " ${INCLUDE:-} " in *" extra/ssh "*) ssh_enabled=true ;; esac
        sshd_running && ssh_running=true
        ipv4=$(host_ipv4)
        printf '{\n'
        printf '  "model": "%s",\n' "$(json_escape "${model}")"
        printf '  "android": "%s",\n' "$(json_escape "${android}")"
        printf '  "arch": "%s",\n' "$(json_escape "${arch}")"
        printf '  "kernel": "%s",\n' "$(json_escape "${kernel}")"
        printf '  "mem_used_mb": %d,\n' "${mem_used}"
        printf '  "mem_total_mb": %d,\n' "${mem_total}"
        printf '  "swap_used_mb": %d,\n' "${swap_used}"
        printf '  "swap_total_mb": %d,\n' "${swap_total}"
        printf '  "selinux": %s,\n' "${selinux}"
        printf '  "loop": %s,\n' "${loop}"
        printf '  "binfmt": %s,\n' "${binfmt}"
        printf '  "fs": "%s",\n' "$(json_escape "${supported_fs}")"
        printf '  "installed": "%s",\n' "$(json_escape "${installed}")"
        printf '  "chroot_dir": "%s",\n' "$(json_escape "${CHROOT_DIR}")"
        printf '  "ipv4": "%s",\n' "$(json_escape "${ipv4}")"
        printf '  "mounted": %s,\n' "${mounted}"
        printf '  "running": %s,\n' "${running}"
        printf '  "ssh_enabled": %s,\n' "${ssh_enabled}"
        printf '  "ssh_running": %s\n' "${ssh_running}"
        printf '}\n'
        return 0
    fi
    local model=$(which getprop >/dev/null 2>&1 && getprop ro.product.model)
    if [ -n "${model}" ]; then
        msg -n "设备型号: "
        msg "${model}"
    fi

    local android=$(which getprop >/dev/null 2>&1 && getprop ro.build.version.release)
    if [ -n "${android}" ]; then
        msg -n "Android 版本: "
        msg "${android}"
    fi

    msg -n "系统架构: "
    msg "$(uname -m)"

    msg -n "内核版本: "
    msg "$(uname -r)"

    msg -n "内存: "
    local mem_total=$(grep ^MemTotal /proc/meminfo | awk '{print $2}')
    mem_total=$((mem_total/1024))
    local mem_free=$(grep ^MemFree /proc/meminfo | awk '{print $2}')
    mem_free=$((mem_free/1024))
    msg "${mem_free}/${mem_total} MB"

    msg -n "Swap: "
    local swap_total=$(grep ^SwapTotal /proc/meminfo | awk '{print $2}')
    swap_total=$((swap_total/1024))
    local swap_free=$(grep ^SwapFree /proc/meminfo | awk '{print $2}')
    swap_free=$((swap_free/1024))
    msg "${swap_free}/${swap_total} MB"

    msg -n "SELinux: "
    selinux_inactive && msg "关闭" || msg "开启"

    msg -n "Loop 设备: "
    loop_support && msg "可用" || msg "不可用"

    msg -n "binfmt_misc 支持: "
    multiarch_support && msg "支持" || msg "不支持"

    msg -n "支持的挂载文件系统: "
    local supported_fs=$(printf '%s ' $(grep -v nodev /proc/filesystems | sort))
    msg "${supported_fs}"

    msg -n "已安装系统: "
    # 参数化读取 PRETTY_NAME（不用 . source os-release，理由同上）
    local linux_version="未知"
    if [ -r "${CHROOT_DIR}/etc/os-release" ]; then
        linux_version=$(grep '^PRETTY_NAME=' "${CHROOT_DIR}/etc/os-release" | head -1 | sed -e 's/^[^=]*=//' -e 's/^"//' -e 's/"$//')
        [ -n "${linux_version}" ] || linux_version="未知"
    fi
    msg "${linux_version}"

    msg -n "运行状态: "
    local running=false mounted=false
    container_mounted >/dev/null 2>&1 && mounted=true
    [ "${mounted}" = "true" ] && running=true
    ldstatus_running && running=true
    # 命名空间不可见时按启动信息还原（见 container_status --json 分支说明）
    if ldinfo_valid; then
        running=true
    fi
    [ "${running}" = "true" ] && msg "运行中" || msg "已停止"
    msg -n "局域网 IPv4: "
    local lan_ip=$(host_ipv4)
    [ -n "${lan_ip}" ] || lan_ip=$(ldinfo_get IPV4)
    [ -n "${lan_ip}" ] && msg "${lan_ip}" || msg "未连接网络"
    case " ${INCLUDE:-} " in
    *" extra/ssh "*)
        msg -n "SSH 服务: "
        sshd_running && msg "运行中（端口 ${SSH_PORT:-22}）" || msg "未运行（本机端口不可连接）"
    ;;
    esac

    msg "组件状态: "
    local DO_ACTION='do_status'
    component_exec "${INCLUDE}"

    msg "已挂载分区: "
    local item
    for item in $(grep "${CHROOT_DIR%/}" /proc/mounts | awk '{print $2}' | sed "s|${CHROOT_DIR%/}/*|/|g")
    do
        msg "* ${item}"
    done
}

################################################################################
# 安全护栏与自检
################################################################################

# 交互确认（--yes 跳过）
# 用法: confirm_yes "提示文本" [默认值]
confirm_yes()
{
    local prompt="$1"
    local def="${2:-n}"
    [ "${YES}" = "true" ] && return 0
    [ "${def}" = "y" ] && local hint="[Y/n]" || local hint="[y/N]"
    msg -n "${prompt} ${hint} "
    local ans
    read ans
    case "${ans}" in
    y|Y|yes|YES|Yes) return 0 ;;
    n|N|no|NO|No) return 1 ;;
    "")
        [ "${def}" = "y" ] && return 0 || return 1
    ;;
    *) return 1 ;;
    esac
}

# 部署安全护栏：目标目录存在且非空时返回 1
check_target_dir()
{
    if [ -d "${CHROOT_DIR}" ] && [ -n "$(ls -A "${CHROOT_DIR}" 2>/dev/null)" ]; then
        msg "安全护栏: 目标目录非空，可能已存在系统文件: ${CHROOT_DIR}"
        return 1
    fi
    return 0
}

# 自检：环境、配置、依赖、目录权限
do_check()
{
    local fail=0
    local warn=0

    # 运行身份
    if [ "$(id -u)" = "0" ]; then
        msg "[通过] 运行身份: root"
    else
        msg "[失败] 运行身份: 非 root（需要 root 权限）"
        fail=$((fail+1))
    fi

    # 核心工具
    local tool_list="wget curl ar tar xz zstd dpkg-deb getprop"
    local missing=""
    for tool in ${tool_list}; do
        if ! command -v "${tool}" >/dev/null 2>&1; then
            missing="${missing} ${tool}"
        fi
    done
    if [ -z "${missing}" ]; then
        msg "[通过] 核心工具齐全"
    else
        msg "[警告] 缺少工具:${missing}（部分功能将不可用）"
        warn=$((warn+1))
    fi

    # wget 可用性：应指向内置静态 wget1（busybox wget applet 段错误、GNU
    # Wget2 动态版部分 ROM 异常，均不可靠）。顺带做一次连通性探测。
    local wget_bin
    wget_bin=$(command -v wget 2>/dev/null)
    if [ -n "${wget_bin}" ]; then
        msg "[通过] wget 可用: ${wget_bin}"
        if "${wget_bin}" -T 8 -t 1 -q -O /dev/null https://mirrors.ustc.edu.cn/ 2>/dev/null; then
            msg "[通过] wget 连通性正常（mirrors.ustc.edu.cn）"
        else
            msg "[警告] wget 网络连通性异常（不影响自检，请检查网络与镜像站）"
            warn=$((warn+1))
        fi
    else
        msg "[失败] 缺少 wget（下载功能不可用）"
        fail=$((fail+1))
    fi

    # debootstrap 完整性
    local db_dir="${INCLUDE_DIR}/bootstrap/debian/debootstrap"
    if [ -f "${db_dir}/debootstrap" ] && [ -f "${db_dir}/functions" ] && [ -d "${db_dir}/scripts" ]; then
        msg "[通过] debootstrap 文件完整（官方 debootstrap）"
    else
        msg "[失败] debootstrap 文件缺失: ${db_dir}"
        fail=$((fail+1))
    fi

    # debootstrap 关键依赖：pkgdetails（静态编译，必须可执行）
    local pkgdetails="${db_dir}/pkgdetails"
    if [ -x "${pkgdetails}" ]; then
        msg "[通过] pkgdetails 可执行（debootstrap 解包关键依赖）"
    elif [ -f "${pkgdetails}" ]; then
        msg "[失败] pkgdetails 存在但缺少执行权限: ${pkgdetails}"
        fail=$((fail+1))
    else
        msg "[失败] pkgdetails 缺失: ${pkgdetails}"
        fail=$((fail+1))
    fi

    # 内置工具链（busybox / e2fsck / resize2fs / mke2fs）
    local tool_missing=""
    for tool in busybox e2fsck resize2fs mke2fs; do
        [ -x "${TOOLS_DIR}/${tool}" ] || tool_missing="${tool_missing} ${tool}"
    done
    if [ -z "${tool_missing}" ]; then
        msg "[通过] 内置工具链齐全: ${TOOLS_DIR}"
    else
        msg "[警告] 内置工具缺失:${tool_missing}（镜像功能将不可用）"
        warn=$((warn+1))
    fi

    # 工具链是否已生效（busybox applet 软链 + PATH）
    if [ -x "${TOOLS_DIR}/busybox" ]; then
        case ":${PATH}:" in
        *":${TOOLS_DIR}:"*)
            msg "[通过] 工具链已加入 PATH（${TOOLS_DIR}）"
        ;;
        *)
            msg "[警告] 工具链目录未在 PATH 中，部分命令可能仍缺失"
            warn=$((warn+1))
        ;;
        esac
    fi

    # 操作配置（-c 指定）
    if [ -n "${CURRENT_CONF}" ]; then
        msg "[通过] 操作配置: ${CURRENT_CONF}"
    else
        msg "[警告] 未指定操作配置（可用 -c <配置名> 指定；check 为环境自检，不阻塞）"
        warn=$((warn+1))
    fi

    # 配置目录权限
    if [ -d "${CONFIG_DIR}" ] && [ -w "${CONFIG_DIR}" ]; then
        msg "[通过] 配置目录可写: ${CONFIG_DIR}"
    else
        msg "[失败] 配置目录不可写: ${CONFIG_DIR}"
        fail=$((fail+1))
    fi

    # 容器目录
    if [ -n "${CHROOT_DIR}" ]; then
        # 目录型容器不允许放在共享存储（与启动拦截一致，部署前提前诊断）
        if [ "${TARGET_TYPE:-directory}" = "directory" ] && is_shared_storage "${TARGET_PATH:-${CHROOT_DIR}}"; then
            msg "[失败] 容器路径在共享存储（/storage/emulated/0、/sdcard 这类放相册和下载的地方），共享存储不允许运行程序，目录方式放这里会无法启动"
            msg "       请把容器路径换成系统目录（如 /data/local/tmp/xxx），或把安装方式改成「镜像（ext4 镜像文件）」"
            fail=$((fail+1))
        elif [ -d "${CHROOT_DIR}" ]; then
            if [ -n "$(ls -A "${CHROOT_DIR}" 2>/dev/null)" ]; then
                msg "[警告] 容器目录非空（可能已部署）: ${CHROOT_DIR}"
                warn=$((warn+1))
            else
                msg "[通过] 容器目录存在且为空: ${CHROOT_DIR}"
            fi
        else
            msg "[通过] 容器目录不存在（部署时将创建）: ${CHROOT_DIR}"
        fi
    else
        msg "[失败] 容器目录未设置"
        fail=$((fail+1))
    fi

    # 挂载能力
    if [ -r /proc/mounts ]; then
        msg "[通过] 可读取挂载表"
    else
        msg "[失败] 无法读取 /proc/mounts"
        fail=$((fail+1))
    fi

    # SELinux
    if selinux_inactive; then
        msg "[通过] SELinux 未强制（permissive/关闭）"
    else
        msg "[警告] SELinux 强制模式，容器内操作可能受限"
        warn=$((warn+1))
    fi

    # 汇总
    msg "----------------------------------------"
    if [ "${fail}" -eq 0 ] && [ "${warn}" -eq 0 ]; then
        msg "[通过] 自检全部通过"
        return 0
    elif [ "${fail}" -eq 0 ]; then
        msg "[通过] 自检通过（${warn} 项警告）"
        return 0
    else
        msg "[失败] 自检未通过（${fail} 项失败，${warn} 项警告）"
        return 1
    fi
}

################################################################################
# 帮助
################################################################################

helper()
{
    printf '%s\n' \
"Linux Deploy CLI ${VERSION}"
    printf '%s\n' \
"维护：GanYu256 | 全中文日志 | 无配置锁，统一 -c 指定配置"
    printf '%s\n' \
"" \
"用法: ${0##*/} [选项] 命令 [参数]" \
"" \
"选项:" \
"  -d            调试模式（输出详细日志）" \
"  -t            跟踪模式（set -x）" \
"  -j, --json    JSON 输出模式（供前端解析）" \
"  -c <配置名>   指定操作配置（容器操作命令必需）" \
"  -h, --help    显示本帮助" \
"" \
"配置命令:" \
"  config list                    列出全部配置" \
"  config show [名称]             显示配置详情（名称或 -c 指定）" \
"  config create <名称> [--k=v]   新建配置（自动隔离容器目录）" \
"  config edit [--k=v ...]        修改 -c 指定配置参数" \
"  config copy <源> <新名称>      复制配置" \
"  config delete <名称> [--purge] 删除配置（--purge 连同容器目录删除）" \
"  config export <文件>           导出 -c 指定配置" \
"  config import <文件|名称>      导入配置（自动隔离容器目录）" \
"" \
"容器命令:" \
"  deploy [--dry-run] [--yes] [--k=v]  部署 -c 指定配置（含安全护栏与确认）" \
"  start  [--mount]                启动容器" \
"  stop   [--umount]               停止容器" \
"  restart                         重启容器（停止后重新启动，等价 stop + 3 秒 + start）" \
"  status                          查看容器状态" \
"  shell  [-u 用户] [命令]         进入容器（默认 /bin/bash）" \
"  check                           自检环境与配置" \
"  resize <大小>                   调整镜像大小（如 8G / 512M，仅镜像安装）" \
"" \
"rootfs 命令:" \
"  import <归档|URL>               导入 rootfs 到 -c 指定容器" \
"  export <归档>                   导出 -c 指定容器为 rootfs 归档" \
"  mount                           挂载容器" \
"  umount                          卸载容器" \
"  ip                              显示宿主局域网 IPv4（容器访问地址）" \
"" \
"常用部署参数（--key=value 形式，写入 -c 指定配置）:" \
"  --distrib=debian|ubuntu|kali|alpine|archlinux" \
"  --arch=arm64                    目标架构（本项目只维护 arm64）" \
"  --suite=trixie                  发行版代号" \
"  --source-path=URL               软件源（可覆盖为镜像源）" \
"  --chroot-dir=路径               容器目录（部署前确认）" \
"  --include=组件                  包含的组件列表（如 core extra/ssh）" \
"  --extra-packages=包名           额外安装的软件包" \
"  --user-name=用户名              容器用户名（默认 root）" \
"  --user-password=密码            用户密码（默认 changeme）" \
"  --user-groups=组名列表          辅助组，空格分隔（默认 aid_inet aid_sdcard_rw aid_graphics）" \
"  --mounts=源:目标                安卓目录挂载到容器，空格分隔多个" \
"  --ssh-port=端口                 SSH 端口（配合 extra/ssh 组件使用，默认 22）" \
"  --graphics=子系统               图形子系统（预留，暂未启用）"
}

################################################################################
# 主流程
################################################################################
# 主流程
################################################################################

# 基础环境设置
umask 0022
unset LANG

# 定位环境目录（兼容 app 生成的入口脚本：入口软链接指向本脚本所在目录）
if [ -z "${ENV_DIR}" ]; then
    ENV_DIR=$(dirname "$(readlink -f "$0")")
fi
# 项目根目录（ENV_DIR 为 <项目根>/src/linuxdeploy-cli）与构建目录：
# 容器部署产物统一放在 builds 下，与源码、缓存、日志分离。
# 注意：BUILD_DIR 仅用于日志/临时文件；容器目录默认值见 LINUX_DEPLOY_DATA_DIR
# 的说明（必须是设备端系统目录，不能落在应用数据目录）。
PROJECT_ROOT=$(dirname "$(dirname "${ENV_DIR}")")
if [ -z "${BUILD_DIR}" ]; then
    # 安卓宿主 /data/data/<包名>/... 不可用时退回到设备公共目录
    case "${ENV_DIR}" in
    /data/data/*|/data/user/*|/data/user_de/*) BUILD_DIR="/data/local/tmp/linuxdeploy/builds" ;;
    *) BUILD_DIR="${PROJECT_ROOT}/builds" ;;
    esac
fi
# 读取环境全局配置（可覆盖以下默认目录）
if [ -e "${ENV_DIR}/cli.conf" ]; then
    . "${ENV_DIR}/cli.conf"
fi
# 目录默认值
if [ -z "${CONFIG_DIR}" ]; then
    CONFIG_DIR="${ENV_DIR}/config"
fi
if [ -z "${INCLUDE_DIR}" ]; then
    INCLUDE_DIR="${ENV_DIR}/include"
fi
if [ -z "${TEMP_DIR}" ]; then
    TEMP_DIR="${ENV_DIR}/tmp"
fi
# 容器目录默认值（新配置创建时会自动分配独立目录）
if [ -z "${CHROOT_DIR}" ]; then
    CHROOT_DIR="${ENV_DIR}/mnt"
fi
if [ -z "${METHOD}" ]; then
    METHOD="chroot"
fi

# 全局选项解析：把 --json/--help/-j/-h 提升到参数最前（命令前或命令后均可）。
# 用换行分隔重建位置参数（POSIX，不用 bash 数组）。
# 命令自身参数（deploy --yes、config create --k=v 等）原样保留。
opt_head=""
opt_rest=""
for arg in "$@"
do
    case "${arg}" in
    --json) opt_head="${opt_head}-j
" ;;
    --help) opt_head="${opt_head}-h
" ;;
    -j|-h)  opt_head="${opt_head}${arg}
" ;;
    *)      opt_rest="${opt_rest}${arg}
" ;;
    esac
done
oldifs="${IFS}"
set -f
IFS='
'
set -- ${opt_head}${opt_rest}
IFS="${oldifs}"
set +f

# 解析全局选项（-d 调试 / -t 跟踪 / -j JSON / -h 帮助 / -c 指定配置）
# -c <配置名>：唯一指定操作配置的方式（无配置锁）。
# 前端 app 直读 config/ 目录 + 用 -c 指定配置执行命令，不触碰锁文件。
OPTIND=1
while getopts :djtc:h FLAG
do
    case "${FLAG}" in
    d)
        DEBUG_MODE="true"
    ;;
    j)
        JSON_MODE="true"
    ;;
    t)
        TRACE_MODE="true"
    ;;
    h)
        helper
        exit 0
    ;;
    c)
        OPT_CONF_NAME="${OPTARG}"
    ;;
    *)
        # 未知选项：停止选项解析，交给命令分发处理。
        break
    ;;
    esac
done
shift $((OPTIND-1))

# 日志级别：默认隐藏错误输出，调试模式显示
exec 3>&1
if [ "${DEBUG_MODE}" != "true" ] && [ "${TRACE_MODE}" != "true" ]; then
    exec 2>/dev/null
fi
if [ "${TRACE_MODE}" = "true" ]; then
    set -x
fi

# 确保基础目录存在
[ -d "${CONFIG_DIR}" ] || mkdir -p "${CONFIG_DIR}"
[ -d "${INCLUDE_DIR}" ] || mkdir -p "${INCLUDE_DIR}"
[ -d "${TEMP_DIR}" ] || mkdir -p "${TEMP_DIR}"

# ===== 内置工具链初始化 =====
# 目录：ENV_DIR/tools，存放面向安卓宿主的内置工具：
#   busybox   —— 提供 ar/xz/zstd 等 applet（宿主缺失时启用）
#   tar.gnu   —— GNU tar 1.35（静态编译，含 gzip/xz/zstd 支持）
#   wget      —— 动态链接 wget（bionic，走 Android 系统 DNS）
#   e2fsck    —— ext2/3/4 文件系统检查
#   resize2fs —— 镜像扩容 / 缩容
#   mke2fs    —— 创建 ext2/3/4 磁盘镜像
# pkgdetails 放在 debootstrap 目录内，供官方 debootstrap 直接执行。
TOOLS_DIR="${ENV_DIR}/tools"

# 修正内置脚本与二进制的执行权限（assets 解压丢失 exec 位，首次补齐）。
env_fix_permissions()
{
    if [ ! -x "${INCLUDE_DIR}/bootstrap/debian/debootstrap/debootstrap" ]; then
        find "${INCLUDE_DIR}" -type f \( -name "*.sh" -o -name "debootstrap" \) \
            -exec chmod 755 {} + 2>/dev/null || true
    fi
    if [ ! -x "${TOOLS_DIR}/busybox" ]; then
        chmod 755 "${TOOLS_DIR}"/* 2>/dev/null || true
    fi
    chmod 755 "${INCLUDE_DIR}/bootstrap/debian/debootstrap/pkgdetails" 2>/dev/null || true
}

# 保证宿主 /tmp 可用。
# 安卓根文件系统没有 /tmp；debootstrap 等第三方脚本在 chroot 内/外会裸调用
# mktemp（且自身 unset 了 TMPDIR），失败即被 set -e 中断，表现为部署在
# "正在安装 bootstrap/xxx" 后无输出地退出。这里优先使用已有的 /tmp，
# 否则在 /tmp 指向可写的 /data/local/tmp（不可创建时退化为 TEMP_DIR）。
env_ensure_tmp()
{
    [ -d /tmp ] && return 0
    local t="/data/local/tmp"
    [ -d "${t}" ] || t="${TEMP_DIR}"
    [ -d "${t}" ] || return 0
    ln -s "${t}" /tmp 2>/dev/null || true
}

# 生成 HTTPS 用的 CA 证书包（PEM），输出路径到 stdout；失败不输出。
# 背景：宿主 wget（GNU Wget2）不读安卓系统证书库 /system/etc/security/cacerts，
# 直接访问 https 源会报 "Certificate error"。debootstrap 支持
# --ca-certificate=FILE，把系统证书合并成单个 PEM 交给它即可在保持证书校验
# 的前提下使用 https 源（而不是用 --no-check-certificate 关闭校验）。
# 合并结果缓存在 TEMP_DIR，超过 7 天或证书目录更新时重建。
env_ca_bundle()
{
    local bundle="${TEMP_DIR}/ca-bundle.pem"
    local cacert_dir="/system/etc/security/cacerts"
    [ -d "${cacert_dir}" ] || return 1
    if [ -s "${bundle}" ]; then
        # 交叉 /proc/uptime 与文件时间不可比，这里用简单时效：7 天（604800 秒）
        local age
        age=$(stat -c %Y "${bundle}" 2>/dev/null || echo 0)
        if [ "${age}" -gt 0 ] 2>/dev/null; then
            local now
            now=$(date +%s 2>/dev/null || echo 0)
            if [ "${now}" -gt 0 ] && [ $((now - age)) -lt 604800 ]; then
                echo "${bundle}"
                return 0
            fi
        fi
    fi
    mkdir -p "${TEMP_DIR}" 2>/dev/null || return 1
    local tmp="${bundle}.tmp.$$"
    : > "${tmp}" 2>/dev/null || return 1
    local f
    for f in "${cacert_dir}"/*; do
        [ -f "${f}" ] || continue
        cat "${f}" >> "${tmp}" 2>/dev/null || true
    done
    if [ -s "${tmp}" ]; then
        mv -f "${tmp}" "${bundle}" 2>/dev/null || { rm -f "${tmp}"; return 1; }
        echo "${bundle}"
        return 0
    fi
    rm -f "${tmp}"
    return 1
}

# 组件脚本在子 shell 中执行，需要显式把 wget 的工作目录变量传下去：
# wget2 会往 $HOME/.local/share/wget、$XDG_DATA_HOME/wget 写 HSTS/OCSP 缓存，
# 变量缺失时会往根目录 "//.local/..." 写并报 Failed to open tmpfile。
env_wget_vars()
{
    printf 'HOME=%s XDG_DATA_HOME=%s' "${TEMP_DIR}" "${TEMP_DIR}/xdg"
}

# 补齐宿主缺失的工具软链并加入 PATH。
# 安卓 toybox 没有 ar，镜像解包与 .deb 读取依赖它。
env_init_tools()
{
    env_fix_permissions
    [ -x "${TOOLS_DIR}/busybox" ] || return 0
    # 只补齐宿主缺失的关键 applet（ar/xz/zstd/dpkg-deb），
    # 清掉旧软链后按需重建，不覆盖系统命令。
    find "${TOOLS_DIR}" -maxdepth 1 -type l -delete >/dev/null 2>&1 || true
    local app
    for app in ar xz xzcat unxz lzma unlzma lzcat dpkg-deb
    do
        if ! command -v "${app}" >/dev/null 2>&1; then
            ln -sf busybox "${TOOLS_DIR}/${app}" 2>/dev/null || true
        fi
    done
    for app in unzstd zstdcat zstdmt
    do
        ln -sf zstd "${TOOLS_DIR}/${app}" 2>/dev/null || true
    done
    # 用 GNU tar（tools/tar.gnu → tools/tar），支持 --exclude/--zstd 等扩展。
    if [ -f "${TOOLS_DIR}/tar.gnu" ] && [ ! -f "${TOOLS_DIR}/tar" ]; then
        cp "${TOOLS_DIR}/tar.gnu" "${TOOLS_DIR}/tar"
        chmod 755 "${TOOLS_DIR}/tar"
    fi
    case ":${PATH}:" in
    *":${TOOLS_DIR}:"*) ;;
    *) PATH="${TOOLS_DIR}:${PATH}" ;;
    esac
    export PATH
    # HOME/TMPDIR 指向应用 tmp（安卓宿主没有 /tmp）。
    # 注意：debootstrap 脚本开头会 unset TMP/TEMP/TMPDIR，随后内部裸调用
    # mktemp，会退回不存在的 /tmp 并失败（"mktemp: Failed to create file
    # /tmp/tmp.xxx"），在 set -e 下中断整个部署。因此这里额外把 /tmp 兜底
    # 指向宿主可写的临时目录；脚本内的 mktemp 也统一带显式模板。
    mkdir -p "${TEMP_DIR}" 2>/dev/null || true
    export HOME="${TEMP_DIR}"
    export TMPDIR="${TEMP_DIR}"
    export TMP="${TEMP_DIR}"
    env_ensure_tmp
    mkdir -p "${TEMP_DIR}/xdg/wget" 2>/dev/null || true
    export XDG_DATA_HOME="${TEMP_DIR}/xdg"
}
env_init_tools

# 确定操作配置：仅由 -c <配置名> 指定（无配置锁）
if [ -n "${OPT_CONF_NAME}" ]; then
    if config_exists "${OPT_CONF_NAME}"; then
        CURRENT_CONF="${OPT_CONF_NAME}"
    else
        msg "指定配置不存在: ${OPT_CONF_NAME}"
        exit 1
    fi
else
    CURRENT_CONF=""
fi

# 读取操作配置参数
OPTLST=" " # 首字符必须为空格
if [ -n "${CURRENT_CONF}" ]; then
    CONF_FILE=$(config_file_of "${CURRENT_CONF}")
    params_read "${CONF_FILE}"
else
    CONF_FILE=""
fi

# 固定启动方式为 chroot（unshare 暂不支持，4.0 目标）
METHOD="chroot"

# 初始化系统兜底：旧配置可能无 INIT 键。
# - Debian 系（debian/ubuntu/kali）默认 sysv（/etc/rcN.d 布局）；
# - 非 Debian 系必须默认 run-parts（/etc/rc.d，与 Ubuntu 模板的标准脚本一致）：
#   Alpine 没有 /etc/rcN.d，Arch/Slackware 的服务脚本都在 /etc/rc.d；
#   若沿用 sysv，启动时 “/etc/rc3.d 不存在” 直接跳过，sshd 永远不会被拉起，
#   表现为“容器显示运行中，但 SSH 连不上”（沿用 Ubuntu 上验证过的修复方式）。
# INCLUDE 含 init 组件时组件依赖解析依赖 INIT 值，缺省会直接报"缺少必要参数"。
if [ -z "${INIT}" ]; then
    case "${DISTRIB}" in
    debian|ubuntu|kali) INIT="sysv" ;;
    *) INIT="run-parts" ;;
    esac
fi
INIT_LEVEL="${INIT_LEVEL:-3}"
if [ "${INIT}" = "run-parts" ] && [ -z "${INIT_PATH}" ]; then
    INIT_PATH="/etc/rc.d"
fi

# 常驻显示操作配置（--json 模式隐藏横幅，避免污染机器可读输出）
if [ "${JSON_MODE}" != "true" ]; then
    msg "=========================================="
    msg " Linux Deploy CLI ${VERSION} | 操作配置: ${CURRENT_CONF:-未指定}"
    msg " 容器目录: ${CHROOT_DIR}"
    msg "=========================================="
fi

# 解析命令（无参数时 helper 会给出用法；shift 前须确认有参数可移，
# 否则 mksh 对特殊内建 shift 的错误会直接终止脚本且 stderr 已被丢弃）
OPTCMD="${1:-}"
[ $# -gt 0 ] && shift
case "${OPTCMD}" in

config)
    # 配置管理子命令
    sub="$1"; shift
    case "${sub}" in
    list)
        config_list
        exit $?
    ;;
    show)
        config_show "$1"
        exit $?
    ;;
    create)
        config_create "$@"
        exit $?
    ;;
    edit)
        config_edit "$@"
        exit $?
    ;;
    copy)
        config_copy "$1" "$2"
        exit $?
    ;;
    delete)
        config_delete "$@"
        exit $?
    ;;
    export)
        config_export "$1"
        exit $?
    ;;
    import)
        config_import "$@"
        exit $?
    ;;
    *)
        helper
        exit 1
    ;;
    esac
;;

deploy)
    require_config
    # 部署 -c 指定配置
    log_open "${CURRENT_CONF:-deploy}"
    # 组件内部命令的 stderr 副本写入日志（失败收尾时回显，T13 修复失败不可见问题）
    ld_capture_errors
    dry_run="false"
    yes_mode="false"
    mount_flag="false"
    keep_mounted="false"
    DO_ACTION='do_install && do_configure'
    deploy_params=""

    # 解析部署选项
    for arg in "$@"
    do
        case "${arg}" in
        --dry-run)
            dry_run="true"
        ;;
        --yes|-y)
            yes_mode="true"
            YES="true"   # confirm_yes 依赖全局 YES；不置位则 --yes 无法跳过最终确认
        ;;
        --mount|-m)
            mount_flag="true"
        ;;
        --keep-mounted)
            # 部署成功后保留挂载（默认部署完成自动卸载，更安全）
            keep_mounted="true"
        ;;
        --install|-i)
            DO_ACTION='do_install'
        ;;
        --configure|-c)
            DO_ACTION='do_configure'
        ;;
        --exclude=*)
            EXCLUDE_COMPONENTS="${EXCLUDE_COMPONENTS} ${arg#--exclude=}"
        ;;
        *)
            deploy_params="${deploy_params}${arg}
"
        ;;
        esac
    done

    # 合并部署参数（--key=value 写入当前配置）；换行分隔重建位置参数（POSIX，无数组）
    if [ -n "${deploy_params}" ]; then
        oldifs="${IFS}"
        set -f
        IFS='
'
        set -- ${deploy_params}
        IFS="${oldifs}"
        set +f
        params_parse "$@"
        params_write "${CONF_FILE}"
    fi

    # 部署计划摘要
    msg "部署计划:"
    msg "  发行版: ${DISTRIB:-未设置}"
    msg "  架构: ${ARCH:-未设置}"
    msg "  发行代号: ${SUITE:-未设置}"
    msg "  安装源: ${SOURCE_PATH:-默认}"
    msg "  容器目录: ${CHROOT_DIR}"
    msg "  包含组件: ${INCLUDE:-bootstrap}"
    msg "  排除组件: ${EXCLUDE_COMPONENTS:-无}"
    extra_pkgs_summary=$(normalize_packages "${EXTRA_PACKAGES}")
    [ -n "${extra_pkgs_summary}" ] || extra_pkgs_summary="无"
    msg "  额外软件包: ${extra_pkgs_summary}"

    # 演练模式：只展示计划
    if [ "${dry_run}" = "true" ]; then
        msg "演练模式（--dry-run）: 以上为执行计划，未执行任何操作。"
        exit 0
    fi

    # 安全护栏：目标目录非空检查（防止覆盖已有工作环境）
    if [ -d "${CHROOT_DIR}" ] && [ -n "$(ls -A "${CHROOT_DIR}" 2>/dev/null)" ]; then
        if [ "${yes_mode}" = "true" ]; then
            msg "安全护栏: 目标目录非空，强制部署将清空后全新安装: ${CHROOT_DIR}"
        else
            confirm_yes "目标目录非空，部署将清空该目录后全新安装（残留数据/半截缓存会丢失），是否继续？" || { msg "已取消部署。"; exit 1; }
        fi
        # 清空目录内容（保留目录本身）：清除半截 debootstrap 缓存/残留，
        # 避免脏目录复用损坏缓存导致"光速报错"（强制部署 = 清空后全新部署）
        if [ -n "${CHROOT_DIR}" ] && [ "${CHROOT_DIR}" != "/" ]; then
            msg "正在清空目标目录: ${CHROOT_DIR}"
            find "${CHROOT_DIR}" -mindepth 1 -delete 2>/dev/null || {
                rm -rf "${CHROOT_DIR:?}/"* "${CHROOT_DIR:?}/".[!.]* 2>/dev/null || true
            }
        fi
    fi

    # 部署前确认
    confirm_yes "确认开始部署？" || { msg "已取消部署。"; exit 1; }

    # 挂载容器（可选）
    if [ "${mount_flag}" = "true" ]; then
        container_mount || exit 1
    fi

    # 构建期 statx 兼容层：编译并（容器已存在时）启用；部署结束自动清理。
    # 内核需要 shim 而编译失败时 fail-fast 退出（明确错误 + 解法），
    # 不把问题拖到 debootstrap 阶段。
    statx_shim_prepare || exit 1
    # 部署收尾：无论成败都清理构建期 shim；
    # 失败时顺带卸载组件残留的挂载，避免容器目录被占用、无法重建
    # 成功时默认自动卸载（可用 --keep-mounted 保留），状态干净、避免误操作
    deploy_cleanup()
    {
        local rc=$?
        statx_shim_cleanup
        if [ "${rc}" -ne 0 ]; then
            if container_mounted >/dev/null 2>&1; then
                msg "部署失败，正在卸载残留挂载 ..."
                container_umount >/dev/null 2>&1 || true
            fi
            # 失败原因回显：组件内命令的报错原本只走 stderr（UI 看不到），
            # 这里把捕获到的 stderr 写入日志并回显到输出末尾，UI 日志页可直接定位。
            _ld_errs=$(ld_collect_errors 6)
            if [ -n "${_ld_errs}" ]; then
                msg "部署失败，最近的错误信息："
                printf '%s\n' "${_ld_errs}"
            fi
            ld_capture_cleanup
            msg "部署未完成（退出码 ${rc}），完整日志: ${LOG_FILE}"
        elif [ "${keep_mounted}" != "true" ] && container_mounted >/dev/null 2>&1; then
            msg "部署完成，正在卸载容器挂载（可用 start 启动）..."
            ld_capture_cleanup
            container_umount >/dev/null 2>&1 || true
        else
            ld_capture_cleanup
        fi
        return ${rc}
    }
    trap 'deploy_cleanup' EXIT

    # 执行安装与配置。
    # 显式把 bootstrap 放在最前：bootstrap 依赖 core，组件拓扑排序会
    # 自动先跑 core 再跑 bootstrap，避免"core 配置先于容器部署"的顺序错误。
    # bootstrap/${DISTRIB} 必须在调用处展开：组件 conf 的 DEPENDS 经
    # grep/sed 参数化解析（不经 eval，防注入），值内的 ${DISTRIB} 永远
    # 不会二次展开，写在 conf 里会让 bootstrap/ubuntu|debian 被静默跳过、
    # rootfs 从未安装（部署秒完成、启动必失败）。
    # 用普通赋值展开而非 ${DISTRIB:+bootstrap/${DISTRIB}}：嵌套展开在
    # 不同 shell 实现间行为有差异（设备端 mksh 实测未展开，bootstrap
    # 组件再次被静默跳过），赋值语句的变量展开则任何 POSIX shell 一致。
    distro_component=""
    [ -n "${DISTRIB}" ] && distro_component="bootstrap/${DISTRIB}"
    # 组件执行计划写入日志：组件被静默跳过时（conf 缺失、TARGET 不兼容、
    # 依赖解析异常），日志里至少能看出实际执行了哪些组件，避免再次出现
    # "只有 core 在跑、rootfs 从未安装"却无从定位的情况。
    # 这里展示的是“实际执行顺序”：引导组件在前，core/extra/init 在 rootfs 就绪后执行
    msg "组件执行计划（实际执行顺序）: $(
        _plan=$(IGNORE_DEPENDS=' ' component_depends bootstrap ${distro_component} ${INCLUDE:-core})
        _pre=""
        _post=""
        for _c in ${_plan}
        do
            case "${_c}" in
            bootstrap|bootstrap/*) _pre="${_pre} ${_c}" ;;
            *) _post="${_post} ${_c}" ;;
            esac
        done
        echo "${_pre# }${_post}"
    )"
    # 环境诊断：设备上曾反复出现"bootstrap/ubuntu 没进计划"，需要一眼区分
    # 是跑到了旧脚本、还是组件文件本身缺失/不可读。
    msg "CLI 版本: ${VERSION} | 脚本: ${ENV_DIR}/cli.sh | 组件目录: ${INCLUDE_DIR}"
    msg "发行版引导组件: ${distro_component}/deploy.conf $(
        if [ -e "${INCLUDE_DIR}/${distro_component}/deploy.conf" ]; then
            echo "存在"
        else
            echo "缺失"
        fi)"
    # 部署前硬校验：没有发行版引导组件就不可能安装 rootfs。若它没进执行计划
    # （组件文件缺失、TARGET 不兼容、依赖解析异常），直接中止并说明原因，
    # 避免 core 先跑一遍、最后只留下"容器系统文件不完整"这种间接报错。
    deploy_plan=$(IGNORE_DEPENDS=' ' component_depends bootstrap ${distro_component} ${INCLUDE:-core})
    case "
${deploy_plan}
" in
    *"
${distro_component}
"*) ;;
    *)
        msg "[错误] 部署中止：${distro_component} 未进入执行计划，系统无法安装。"
        if [ ! -e "${INCLUDE_DIR}/${distro_component}/deploy.conf" ]; then
            msg "        原因：组件文件缺失（${INCLUDE_DIR}/${distro_component}/deploy.conf 不存在）。"
            msg "        请在应用「设置 → 重装运行环境」后重试；仍缺失说明安装包内没有该组件。"
        else
            msg "        原因：组件存在但被依赖解析跳过（见上方“组件...已跳过”提示）。"
            msg "        请把这份日志完整反馈给开发者。"
        fi
        exit 1
    ;;
esac
    # 部署执行顺序拆成两段：先装 rootfs（bootstrap 系列），再配置容器内系统。
    # 原因：组件拓扑排序是“先依赖、后自身”，core 依赖 bootstrap 只保证 core
    # 整组排在 core 之前被输出，但 core/* 子组件仍会先于 bootstrap/${DISTRIB}
    # 展开执行。而 core/hostname（装包）、core/profile（写 /etc/shadow）、
    # core/aid、core/timezone 等都必须在 rootfs 就绪后才能跑，否则 apt/chroot
    # 无可用系统会直接卡死（表现为"正在安装 core/hostname ..."后无响应）。
    # 这里显式把 core 依赖拆成两批执行，顺序稳定且不改动各组件自身声明。
    deploy_plan=$(IGNORE_DEPENDS=' ' component_depends bootstrap ${distro_component} ${INCLUDE:-core})
    pre_components=""
    post_components=""
    for _c in ${deploy_plan}
    do
        case "${_c}" in
        bootstrap|bootstrap/*)
            # 引导组件：生成 rootfs，必须最先执行
            pre_components="${pre_components} ${_c}"
        ;;
        *)
            # 其余组件（含依赖 rootfs 的 core/*）：rootfs 就绪后再执行
            post_components="${post_components} ${_c}"
        ;;
        esac
    done
    # 引导组件无论依赖如何都排在最前（避免 core 先于 rootfs 安装）。
    # WITHOUT_DEPENDS=true：按上面排好的顺序直接执行，不再二次解析依赖，
    # 否则 component_exec 会重新拓扑排序，打乱 pre/post 的分段顺序。
    WITHOUT_DEPENDS=true component_exec ${pre_components# }
    deploy_rc=$?
    if [ "${deploy_rc}" -eq 0 ] && [ -n "${post_components# }" ]; then
        # 引导完成后执行剩余组件（core 配置、extra/ssh、init 等）；
        # 这些组件已按依赖排好序，直接执行即可，无需再次解析依赖
        WITHOUT_DEPENDS=true component_exec ${post_components# }
        deploy_rc=$?
    fi
    # 部署后完整性校验：debootstrap 内部失败一般会让 component_exec 非 0
    # 退出，但个别异常（解压不完整却成功返回）只能靠文件级校验兜底，
    # 避免"部署完成"掩盖 rootfs 缺失、拖到启动时才以一句"失败"暴露。
    if [ "${deploy_rc}" -eq 0 ] && [ "${dry_run}" != "true" ]; then
        deploy_miss=""
        # 动态链接器（glibc: ld-linux-*；musl: ld-musl-*），二选一必须存在
        if ! find "${CHROOT_DIR}/lib" "${CHROOT_DIR}/usr/lib" -maxdepth 2 \( -name "ld-linux-*.so*" -o -name "ld-musl-*.so*" \) 2>/dev/null | grep -q .; then
            deploy_miss=" 动态链接器(ld-linux/ld-musl)"
        fi
        [ -e "${CHROOT_DIR}/bin/sh" ] || deploy_miss="${deploy_miss} /bin/sh"
        if [ -n "${deploy_miss}" ]; then
            msg "[错误] 容器系统文件不完整（缺少:${deploy_miss}），部署未真正完成。"
            # 目录里连 debootstrap 工作目录都没有：一阶段没走完（下载/解包前就退了），
            # 和"解包到一半"区分开，便于判断是安装源问题还是解包/磁盘问题。
            if [ "${TARGET_TYPE:-directory}" = "directory" ] && [ ! -d "${CHROOT_DIR}/debootstrap" ] \
                && [ -z "$(ls -A "${CHROOT_DIR}" 2>/dev/null)" ]; then
                msg "        目录里没有任何系统文件，说明 debootstrap 一阶段在下载/解包前就退出了。"
                msg "        请确认手机能访问安装源：${SOURCE_PATH:-默认源}（可先用浏览器/其他下载工具测试该地址）"
            fi
            msg "        常见原因：安装源不可用、网络中断或组件被跳过（见上方日志）。"
            msg "        排查网络/安装源后重新部署；若重复出现，请把完整部署日志反馈给开发者。"
            # 校验失败按部署失败处理：退出码置 1，前端不再误报"部署完成"
            deploy_rc=1
        else
            msg "[通过] 容器系统文件校验通过"
        fi
    fi
    exit ${deploy_rc}
;;

start)
    require_config
    # 启动容器
    log_open "${CURRENT_CONF:-start}"
    mount_flag="false"
    start_args=""
    for arg in "$@"
    do
        case "${arg}" in
        --mount|-m) mount_flag="true" ;;
        *) start_args="${start_args}${arg}
" ;;
        esac
    done
    if [ "${mount_flag}" = "true" ]; then
        container_mount || exit 1
    fi
    oldifs="${IFS}"
    set -f
    IFS='
'
    set -- ${start_args}
    IFS="${oldifs}"
    set +f
    container_start "$@"
    exit $?
;;

stop)
    require_config
    # 停止容器
    log_open "${CURRENT_CONF:-stop}"
    umount_flag="false"
    stop_args=""
    for arg in "$@"
    do
        case "${arg}" in
        --umount|-u) umount_flag="true" ;;
        *) stop_args="${stop_args}${arg}
" ;;
        esac
    done
    oldifs="${IFS}"
    set -f
    IFS='
'
    set -- ${stop_args}
    IFS="${oldifs}"
    set +f
    container_stop "$@"
    stop_rc=$?
    if [ "${umount_flag}" = "true" ]; then
        container_umount
    fi
    if [ ${stop_rc} -ne 0 ]; then
        # 容器已在宿主侧完成停止（进程已结束、挂载已卸）：组件报错只提示，不判失败
        msg "[提示] 容器已停止；部分组件停止时报错（见上方日志），重新启动时会重新拉起"
    fi
    exit 0
;;

restart)
    require_config
    # 重启容器（伪重启：结束进程后重新拉起，不卸载挂载）
    log_open "${CURRENT_CONF:-restart}"
    container_restart "$@"
    exit $?
;;

resize)
    require_config
    # 调整镜像大小（仅支持 TARGET_TYPE=file 的镜像安装）
    log_open "${CURRENT_CONF:-resize}"
    image_resize "$1"
    exit $?
;;

status)
    require_config
    # 容器状态
    if [ $# -gt 0 ]; then
        DO_ACTION='do_status'
        component_exec "$@"
    else
        container_status
    fi
    exit $?
;;

shell)
    require_config
    # 进入容器
    container_shell "$@"
    exit $?
;;

check)
    # 自检（--json 模式输出结构化检查结果，供前端展示）
    if [ "${JSON_MODE}" = "true" ]; then
        raw=$(do_check 2>&1)
        rc=$?
        fail=0
        warn=0
        first="true"
        # do_check 输出经临时文件回读：POSIX sh 兼容（<<< 是 bash 扩展，
        # dash/部分 sh 下直接解析失败、静默退出 2）
        tmpfile="${TEMP_DIR}/check_json_$$.tmp"
        # 先设兜底 trap 再写文件：中途异常退出（如 set -e 中断）也能清理
        trap 'rm -f "${tmpfile}"' EXIT
        printf '%s\n' "${raw}" > "${tmpfile}"
        printf '{\n'
        printf '  "ok": %s,\n' "$([ ${rc} -eq 0 ] && echo true || echo false)"
        printf '  "items": [\n'
        while IFS= read -r item
        do
            case "${item}" in
            "["*)
                level=$(echo "${item}" | sed -n 's/^\[\([^]]*\)\].*/\1/p')
                text=$(echo "${item}" | sed -n 's/^\[[^]]*\]//p')
                case "${level}" in
                通过) ok_text="true" ;;
                警告) ok_text="true"; warn=$((warn+1)) ;;
                失败) ok_text="false"; fail=$((fail+1)) ;;
                *) ok_text="null" ;;
                esac
                if [ "${first}" = "true" ]; then first="false"; else printf ',\n'; fi
                printf '    {"ok": %s, "level": "%s", "detail": "%s"}' \
                    "${ok_text}" "$(json_escape "${level}")" "$(json_escape "${text}")"
            ;;
            esac
        done < "${tmpfile}"
        rm -f "${tmpfile}"  # 正常路径立即清理；兜底 trap 已在创建时设置
        printf '\n  ],\n'
        printf '  "fail": %d,\n  "warn": %d\n' "${fail}" "${warn}"
        printf '}\n'
        exit ${rc}
    fi
    log_open "${CURRENT_CONF:-check}"
    do_check
    exit $?
;;

import)
    require_config
    # 导入 rootfs
    log_open "${CURRENT_CONF:-import}"
    rootfs_import "$@"
    exit $?
;;

export)
    require_config
    # 导出 rootfs
    log_open "${CURRENT_CONF:-export}"
    rootfs_export "$@"
    exit $?
;;

rootfs)
    # rootfs 子命令分组（与顶层 import/export/mount/umount 等价，对齐 usage 文档）
    sub="$1"; shift
    case "${sub}" in
    import)
        log_open "${CURRENT_CONF:-import}"
        rootfs_import "$@"
        exit $?
    ;;
    export)
        log_open "${CURRENT_CONF:-export}"
        rootfs_export "$@"
        exit $?
    ;;
    mount)
        log_open "${CURRENT_CONF:-mount}"
        container_mount
        exit $?
    ;;
    umount)
        log_open "${CURRENT_CONF:-umount}"
        container_umount
        exit $?
    ;;
    *)
        helper
        exit 1
    ;;
    esac
;;

mount)
    require_config
    log_open "${CURRENT_CONF:-mount}"
    container_mount
    exit $?
;;

umount)
    require_config
    log_open "${CURRENT_CONF:-umount}"
    # 统一命名空间操作：锚点有效（容器运行中）一律切入容器命名空间执行卸载
    if [ "${LD_NSENTER}" != "1" ] && container_nsenter_run umount; then
        exit 0
    fi
    container_umount
    exit $?
;;

ip)
    # 宿主局域网 IPv4（列表页展示容器访问地址；-c 可选，不触碰配置锁）
    if [ "${JSON_MODE}" = "true" ]; then
        printf '{\n'
        printf '  "ipv4": "%s"\n' "$(json_escape "$(host_ipv4)")"
        printf '}\n'
    else
        msg "局域网 IPv4: $(host_ipv4)"
    fi
    exit 0
;;

help|-h|--help|"")
    helper
    exit 0
;;

*)
    helper
    exit 1
;;

esac
