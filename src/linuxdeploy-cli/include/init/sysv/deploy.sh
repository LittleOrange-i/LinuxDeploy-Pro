#!/bin/sh
# Linux Deploy Component
# (c) Anton Skshidlevsky <meefik@gmail.com>, GPLv3
# 重构版维护：全中文日志 + 目录存在性守卫（目录缺失时静默跳过，避免 ls 报错）
#
# 发行版差异（修复非 Debian 系统“容器运行但 SSH 连不上”）：
# - Debian/Ubuntu/Kali：/etc/rcN.d/S??xxx（SysV 约定），停止用 /etc/rc6.d/K??xxx；
# - Fedora/CentOS：同名目录，但停止脚本常见于 /etc/rc0.d；
# - Arch/Slackware/Alpine：没有 rcN.d 布局，服务脚本在 /etc/rc.d（由 run-parts 处理）。
# 这里不再硬编码 rc3.d/rc6.d，而是按“当前发行版实际存在的目录”选择，
# 并在缺失时明确提示应改用 run-parts，避免静默跳过。

[ -n "${INIT_USER}" ] || INIT_USER="root"

# 取启动目录：优先 /etc/rc${INIT_LEVEL}.d，其次发行版默认运行级别目录
sysv_start_dir()
{
    local lvl="${INIT_LEVEL:-3}" d
    for d in "${CHROOT_DIR}/etc/rc${lvl}.d" "${CHROOT_DIR}/etc/rc2.d" "${CHROOT_DIR}/etc/rc5.d" "${CHROOT_DIR}/etc/rc.d/rc${lvl}.d"; do
        [ -d "${d}" ] && { echo "${d}"; return 0; }
    done
    return 1
}

# 取停止目录：Debian 系用 rc6.d（关机），Fedora/CentOS 用 rc0.d
sysv_stop_dir()
{
    local d
    for d in "${CHROOT_DIR}/etc/rc6.d" "${CHROOT_DIR}/etc/rc0.d"; do
        [ -d "${d}" ] && { echo "${d}"; return 0; }
    done
    return 1
}

do_start()
{
    [ -n "${INIT_LEVEL}" ] || return 0
    local rcdir
    rcdir=$(sysv_start_dir)
    if [ -z "${rcdir}" ] || [ ! -d "${rcdir}" ]; then
        # 非 Debian 系没有 rcN.d：明确提示，避免用户误以为服务已启动
        msg "[跳过] 容器内不存在 SysV 启动目录（/etc/rc${INIT_LEVEL}.d）"
        msg "        本发行版的服务脚本通常在 /etc/rc.d，请在配置中将「初始化系统」改为 run-parts。"
        return 0
    fi
    local services
    services=$(ls "${rcdir}" 2>/dev/null | grep '^S')
    if [ -n "${services}" ]; then
        msg ":: 启动 SysV 服务（${rcdir##*/}）: "
        local item
        for item in ${services}
        do
            msg -n "${item/S[0-9][0-9]/} ... "
            if [ "${INIT_ASYNC}" = "true" ]; then
                # 3>&-：关闭继承的 fd3（CLI exec 3>&1 保存的原始 stdout），
                # 防止脚本内后台化且不主动关 fd 的守护进程攥住调用方管道导致永不 EOF
                chroot_exec -u ${INIT_USER} "${rcdir}/${item}" start 1>&2 3>&- &
            else
                chroot_exec -u ${INIT_USER} "${rcdir}/${item}" start 1>&2 3>&-
            fi
            is_ok "失败" "完成"
        done
    fi

    return 0
}

do_stop()
{
    [ -n "${INIT_LEVEL}" ] || return 0
    local rcdir
    rcdir=$(sysv_stop_dir)
    if [ -z "${rcdir}" ] || [ ! -d "${rcdir}" ]; then
        msg "[跳过] 容器内不存在 SysV 停止目录（/etc/rc6.d 或 /etc/rc0.d）"
        return 0
    fi
    local services
    services=$(ls "${rcdir}" 2>/dev/null | grep '^K')
    if [ -n "${services}" ]; then
        msg ":: 停止 SysV 服务（${rcdir##*/}）: "
        local item
        for item in ${services}
        do
            msg -n "${item/K[0-9][0-9]/} ... "
            if [ "${INIT_ASYNC}" = "true" ]; then
                chroot_exec -u ${INIT_USER} "${rcdir}/${item}" stop 1>&2 3>&- &
            else
                chroot_exec -u ${INIT_USER} "${rcdir}/${item}" stop 1>&2 3>&-
            fi
            is_ok "失败" "完成"
        done
    fi

    return 0
}

do_help()
{
cat <<EOF
   --init-level="${INIT_LEVEL}"
     SysV 运行级别编号，如 "3"（启动时执行 /etc/rcN.d/ 的 S 脚本）。

   --init-user="${INIT_USER}"
     以指定用户执行，默认 "root"。

   --init-async
     异步启动进程。

EOF
}
