#!/bin/sh
# Linux Deploy Component
# (c) Anton Skshidlevsky <meefik@gmail.com>, GPLv3

[ -n "${DNS}" ] || DNS="auto"

# 读取宿主 DNS。
# Android 8 起 net.dns1/net.dns2 已被移除（getprop 返回空），旧实现只查这两个
# 属性，结果落到 8.8.8.8 兜底；国内网络下 8.8.8.8 常被阻断，于是 Alpine/Arch/
# Slackware 等“部署时要点名包”的发行版在 apk/pacman 阶段就下载失败
# （Debian 系因 debootstrap 自带 DNS 不易暴露）。这里按新版属性与系统文件逐级回退。
net_host_dns()
{
    local d out=""
    if [ -n "$(which getprop)" ]; then
        d=$(getprop net.dns1)
        [ -n "${d}" ] && out="${out} ${d}"
        d=$(getprop net.dns2)
        [ -n "${d}" ] && out="${out} ${d}"
        # Android 8+：net.dns1/net.dns2 已废弃，改查当前网络的 dns 列表与各接口私有属性
        d=$(getprop | sed -n 's/^\[net\.[a-zA-Z0-9_]*\.dns[0-9]*\]: \[\(.*\)\]$/\1/p' | grep -v -e '^$' -e '^0\.0\.0\.0$' | tr '\n' ' ')
        [ -n "${d}" ] && out="${out} ${d}"
        d=$(getprop | sed -n 's/^\[dhcp\.[a-zA-Z0-9_.]*\.dns[0-9]*\]: \[\(.*\)\]$/\1/p' | tr '\n' ' ')
        [ -n "${d}" ] && out="${out} ${d}"
    fi
    # 系统解析配置（部分 ROM 由 netd/resolv 写入，root 可读）
    for f in /system/etc/resolv.conf /etc/resolv.conf /vendor/etc/resolv.conf
    do
        [ -s "${f}" ] || continue
        d=$(awk '/^nameserver/{print $2}' "${f}" 2>/dev/null | tr '\n' ' ')
        [ -n "${d}" ] && out="${out} ${d}"
    done
    # 去重并剔除回环/无效地址（容器内 127.0.0.1 不通）
    printf '%s\n' ${out} | awk '!seen[$0]++' \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
        | grep -v -e '^127\.' -e '^0\.0\.0\.0$' | tr '\n' ' '
}

# 判断容器是否使用 systemd-resolved 管理 /etc/resolv.conf：
# 该场景下 resolv.conf 是软链，容器启动后 stub 监听 127.0.0.53；
# 部署期系统的 resolved 并未运行，必须换成宿主 DNS，否则容器内域名解析全部失败。
net_resolved_stub()
{
    [ -L "${CHROOT_DIR}/etc/resolv.conf" ] && return 0
    grep -q '^nameserver 127\.0\.0\.53' "${CHROOT_DIR}/etc/resolv.conf" 2>/dev/null
}

do_configure()
{
    msg ":: 正在配置 ${COMPONENT} ... "
    local dns dns_list=""
    if [ -z "${DNS}" -o "${DNS}" = "auto" ]; then
        dns_list=$(net_host_dns)
        [ -z "${dns_list}" ] && dns_list="8.8.8.8 1.1.1.1"
    else
        dns_list="${DNS}"
    fi
    # systemd-resolved 软链场景：先断开软链再写实体文件，否则写入的是 stub 目录，
    # 容器内实际仍走 127.0.0.53（旧实现会因此出现“容器能启动但装不了包/SSH 解析失败”）
    if net_resolved_stub; then
        rm -f "${CHROOT_DIR}/etc/resolv.conf"
        msg "   [提示] 检测到 systemd-resolved 软链，已改为静态 resolv.conf"
    fi
    mkdir -p "${CHROOT_DIR}/etc" 2>/dev/null || true
    printf '' > "${CHROOT_DIR}/etc/resolv.conf"
    for dns in ${dns_list}
    do
        echo "nameserver ${dns}" >> "${CHROOT_DIR}/etc/resolv.conf"
    done
    if [ -e "${CHROOT_DIR}/etc/nsswitch.conf" ]; then
        sed -i 's/systemd//g' "${CHROOT_DIR}/etc/nsswitch.conf"
    fi
    return 0
}

do_start()
{
    do_configure
    if [ -n "${NET_TRIGGER}" ]; then
        msg ":: 正在启动 ${COMPONENT} ... "
        chroot_exec -u root "${NET_TRIGGER} start"
    fi
    return 0
}

do_stop()
{
    if [ -n "${NET_TRIGGER}" ]; then
        msg ":: 正在停止 ${COMPONENT} ... "
        chroot_exec -u root "${NET_TRIGGER} stop"
    fi
    return 0
}

do_help()
{
cat <<EOF
   --dns="${DNS}"
     IP-address of DNS server, can specify multiple addresses separated by a space.

   --net-trigger="${NET_TRIGGER}"
     Path to a script inside the container to process changes the network.

EOF
}
