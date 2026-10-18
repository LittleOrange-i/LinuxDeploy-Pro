#!/bin/sh
# Linux Deploy Component
# OpenRC 初始化（Alpine Linux 默认）：
# 启动时按 runlevel 顺序拉起 /etc/init.d 下已 enable 的服务，
# 停止时逆序停止；不依赖 systemd / sysv 目录结构。
#
# 说明：Alpine rootfs 内 /sbin/openrc 需要以 PID 1 或独立会话运行，
# 容器内没有真实 init，因此这里直接调用 rc-service 逐个服务启停，
# 效果等价于 `openrc default`，但能给出逐服务日志并避免长期占用管道。

openrc_rc_service()
{
    local name="$1" action="$2"
    # 已 enable 的服务以软链形式出现在 /etc/runlevels/* 下
    if [ ! -x "${CHROOT_DIR}/etc/init.d/${name}" ]; then
        return 1
    fi
    # 3>&-：关闭继承的 fd3，防止后台服务攥住 CLI 管道
    chroot_exec -u root rc-service "${name}" "${action}" 1>&2 3>&-
}

openrc_services()
{
    local dir runlevel
    # 按 runlevel 顺序收集，去重
    for runlevel in boot sysinit default shutdown; do
        dir="${CHROOT_DIR}/etc/runlevels/${runlevel}"
        [ -d "${dir}" ] || continue
        ls "${dir}" 2>/dev/null
    done | awk '!seen[$0]++'
}

do_start()
{
    [ -x "${CHROOT_DIR}/sbin/openrc" ] || [ -x "${CHROOT_DIR}/usr/sbin/rc-service" ] || {
        msg "[跳过] 容器内未安装 OpenRC（缺少 rc-service）"
        return 0
    }
    local services
    services=$(openrc_services)
    [ -n "${services}" ] || { msg "[跳过] /etc/runlevels 下没有已启用的服务"; return 0; }
    msg ":: 启动 OpenRC 服务（default）："
    local item
    for item in ${services}
    do
        msg -n "${item} ... "
        openrc_rc_service "${item}" start
        is_ok "跳过" "完成"
    done
    return 0
}

do_stop()
{
    local services
    # 逆序停止不依赖 tac（Alpine 默认 busybox 无该 applet），改用 awk 倒序输出
    services=$(openrc_services | awk '{a[NR]=$0} END{for(i=NR;i>0;i--) print a[i]}')
    [ -n "${services}" ] || return 0
    msg ":: 停止 OpenRC 服务："
    local item
    for item in ${services}
    do
        msg -n "${item} ... "
        openrc_rc_service "${item}" stop
        is_ok "跳过" "完成"
    done
    return 0
}

do_status()
{
    msg -n ":: ${COMPONENT} ... "
    # 有容器进程即视为运行中（OpenRC 无常驻 init 进程）
    local pids
    pids=$(get_pids)
    [ -n "${pids}" ] && { msg "运行中"; return 0; }
    msg "已停止"
    return 1
}

do_help()
{
cat <<EOF
   无参数：容器启动时按 /etc/runlevels 顺序启动已启用的 OpenRC 服务，
   停止时逆序停止（适用于 Alpine）。
EOF
}
