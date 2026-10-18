#!/bin/sh
# Linux Deploy Component
# (c) Anton Skshidlevsky <meefik@gmail.com>, GPLv3

[ -n "${LOCALE}" ] || LOCALE="${LANG}"
[ -n "${LOCALE}" ] || LOCALE="C"

do_configure()
{
    msg ":: 正在配置 ${COMPONENT} ... "
    if $(echo ${LOCALE} | grep -q '\.'); then
        local inputfile=$(echo ${LOCALE} | awk -F. '{print $1}')
        local charmapfile=$(echo ${LOCALE} | awk -F. '{print $2}')
        # localedef 失败不应让整个部署中止：
        # 容器内缺少 /usr/share/i18n 数据（精简发行版，如 Slackware 的 glibc 不含
        # locale 源文件）时会直接返回非 0，而组件在 set -e 下会中断部署。
        # 语言环境属增强功能，这里降级为告警。
        if ! chroot_exec -u root localedef -i ${inputfile} -c -f ${charmapfile} ${LOCALE} >/dev/null 2>&1; then
            msg "[警告] 语言环境 ${LOCALE} 生成失败（容器内缺少 locale 数据），已跳过"
        fi
    fi
    case "${DISTRIB}" in
    debian|ubuntu|kali)
        echo "LANG=${LOCALE}" > "${CHROOT_DIR}/etc/default/locale"
    ;;
    archlinux|centos)
        echo "LANG=${LOCALE}" > "${CHROOT_DIR}/etc/locale.conf"
    ;;
    fedora)
        echo "LANG=${LOCALE}" > "${CHROOT_DIR}/etc/sysconfig/i18n"
    ;;
    slackware)
        sed -i "s|^export LANG=.*|export LANG=${LOCALE}|g" "${CHROOT_DIR}/etc/profile.d/lang.sh"
    ;;
    alpine)
      echo "LANG=${LOCALE}" > "${CHROOT_DIR}/etc/profile.d/lang.sh"
    ;;
    esac
    return 0
}

do_help()
{
cat <<EOF
   --locale="${LOCALE}"
     Localization, e.g. "en_US.UTF-8".

EOF
}
