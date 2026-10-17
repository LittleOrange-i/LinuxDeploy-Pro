#!/bin/sh
# Linux Deploy Component

# 运行状态标记：容器启动时拉起进程 ldstatus（exec -a 改名），pid 写入
# /run/ldstatus/pid（容器磁盘，跨挂载命名空间可见），宿主机 status 据此
# 判断容器运行状态，不依赖挂载命名空间可见性。

do_install()
{
    msg ":: 正在安装 ${COMPONENT} ... "
    mkdir -p "${CHROOT_DIR}/run/ldstatus" "${CHROOT_DIR}/usr/local/sbin"
    # 容器内可能没有 bash（Alpine 只有 ash，部分 Arch 精简版也只有 sh）：
    # 安装时探测一次并把解释器写死进脚本，避免启动阶段因缺 bash 而静默失败。
    local sh_bin="/bin/sh"
    if [ -x "${CHROOT_DIR}/bin/bash" ] || [ -x "${CHROOT_DIR}/usr/bin/bash" ]; then
        if [ -x "${CHROOT_DIR}/bin/bash" ]; then
            sh_bin="/bin/bash"
        else
            sh_bin="/usr/bin/bash"
        fi
    fi
    # exec -a 改进程名是 bash/部分 mksh 的特性；ash 不支持时退回普通后台进程，
    # 宿主的 ldstatus_running 校验只看 cmdline 是否含 ldstatus，这里显式拼接名字。
    cat > "${CHROOT_DIR}/usr/local/sbin/ldstatus" <<EOF
#!${sh_bin}
/bin/mkdir -p /run/ldstatus
# 新会话完全脱离宿主（setsid），后台写 pid 后 exec 成 ldstatus 常驻
/bin/setsid ${sh_bin} -c 'echo \$\$ > /run/ldstatus/pid; exec -a ldstatus /bin/sleep infinity' </dev/null >/dev/null 2>&1 &
exit 0
EOF
    chmod 755 "${CHROOT_DIR}/usr/local/sbin/ldstatus"
    return 0
}

do_start()
{
    if ldstatus_running; then
        msg ":: 启动 ${COMPONENT} ... 已在运行"
        return 0
    fi
    msg -n ":: 启动 ${COMPONENT} ... "
    # 预检容器内执行环境：缺文件时给出大白话原因。最常见根因是 rootfs
    # 解压不完整（部署日志中"未检测到 glibc"即同类信号），缺 setsid/sleep
    # 会让本组件静默失败，提前拦截避免用户只看到一句"失败"无从下手。
    local missing=""
    local f
    # shell：bash 优先，缺失时用 sh（Alpine/精简 Arch 没有 bash）
    local have_shell=""
    for f in /bin/bash /usr/bin/bash /bin/sh /usr/bin/sh /bin/ash /usr/bin/ash; do
        [ -e "${CHROOT_DIR}${f}" ] && have_shell="yes" && break
    done
    [ -n "${have_shell}" ] || missing="${missing} /bin/sh"
    # setsid/sleep：busybox 环境可能只有 applet 没有独立文件，此时按 busybox 兜底
    for f in /usr/local/sbin/ldstatus /bin/setsid /bin/sleep; do
        if [ ! -e "${CHROOT_DIR}${f}" ]; then
            # busybox 的 applet 链接在 /usr/bin 或 /bin 下，两种都认
            local base="${f##*/}"
            if [ -e "${CHROOT_DIR}/bin/busybox" ] && [ "${base}" != "ldstatus" ]; then
                continue
            fi
            missing="${missing} ${f}"
        fi
    done
    if [ -n "${missing}" ]; then
        msg "失败"
        msg "[提示] 容器内缺少运行所需的系统文件:${missing}"
        msg "        通常说明容器系统文件不完整（上次部署没有真正完成）。"
        msg "        解决：在配置页重新部署一次；若部署过程报错，请先解决部署错误再启动。"
        return 1
    fi
    chroot_exec /usr/local/sbin/ldstatus
    local ld_rc=$?
    # 等待容器内 pid 文件出现（≤3s），随后覆盖写入配置侧锚点
    # <配置名>.ldstatus（任何命名空间可读，供 stop/umount/status 统一使用）
    local i=0 anchor
    while [ ${i} -lt 15 ] && [ ! -s "${CHROOT_DIR}/run/ldstatus/pid" ]; do
        sleep 0.2
        i=$((i+1))
    done
    if [ -s "${CHROOT_DIR}/run/ldstatus/pid" ] && [ -n "${CURRENT_CONF}" ]; then
        anchor="${CONFIG_DIR}/${CURRENT_CONF}.ldstatus"
        cp -f "${CHROOT_DIR}/run/ldstatus/pid" "${anchor}" 2>/dev/null
        chmod 644 "${anchor}" 2>/dev/null
    fi
    # 恢复 chroot_exec 退出码供 is_ok 判定
    [ ${ld_rc} -eq 0 ]
    is_ok "失败" "完成"
    return 0
}

do_stop()
{
    msg -n ":: 停止 ${COMPONENT} ... "
    # 已停止（锚点不存在或进程已退出）时视为成功：重复点击停止不应报失败
    if ! ldstatus_running; then
        rm -f "${CHROOT_DIR}/run/ldstatus/pid" 2>/dev/null
        remove_ldstatus_anchor
        msg "已停止"
        return 0
    fi
    local ld_pid
    ld_pid=$(ldstatus_pid)
    kill -9 "${ld_pid}" 2>/dev/null
    rm -f "${CHROOT_DIR}/run/ldstatus/pid"
    # 配置侧锚点同步删除，否则 status 会一直读到旧 pid 指向的复用进程
    remove_ldstatus_anchor
    msg "完成"
    return 0
}

do_status()
{
    msg -n ":: ${COMPONENT} ... "
    if ldstatus_running; then
        msg "运行中"
        return 0
    fi
    msg "已停止"
    return 1
}
