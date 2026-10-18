#!/bin/sh
# Linux Deploy Component
# (c) Anton Skshidlevsky <meefik@gmail.com>, GPLv3
# 重构版维护：全中文日志 + 路径存在性守卫（文件/目录缺失时静默跳过，避免 ls 报错）

[ -n "${INIT_USER}" ] || INIT_USER="root"

run_part()
{
    local path="$1"
    local action="$2"
    msg -n "${path##*/} ... "
    # 注意：chroot_exec 用 "$@" 保持参数边界，不能写成 "${path} ${action}"，
    # 否则容器内会把 “/etc/rc.d/sshd start” 当成单个文件名去执行，直接报
    # “No such file or directory”，导致非 Debian 系的 SSH 服务永远拉不起来。
    if [ "${INIT_ASYNC}" = "true" ]; then
        # 3>&-：关闭继承的 fd3（CLI exec 3>&1 保存的原始 stdout），
        # 防止脚本内后台化且不主动关 fd 的守护进程攥住调用方管道导致永不 EOF
        chroot_exec -u ${INIT_USER} "${path}" "${action}" 1>&2 3>&- &
    else
        chroot_exec -u ${INIT_USER} "${path}" "${action}" 1>&2 3>&-
    fi
    is_ok "失败" "完成"
}

# 列出目录下可执行的服务脚本（按文件名顺序，与 run-parts 一致）。
# 过滤备份/配置类文件（Arch 的 rc.conf、Slackware 的 rc.local.new 等），
# 否则会把非服务脚本当服务执行，报一堆无关错误。
run_parts_services()
{
    local dir="$1" f
    for f in "${dir}"/*; do
        [ -f "${f}" ] || continue
        [ -x "${f}" ] || continue
        case "${f##*/}" in
        rc.conf|*.new|*.orig|*.bak|*.dpkg-*|*.rpmnew|*.rpmsave|K*|S[0-9]*|README*|*.sample) continue ;;
        esac
        echo "${f##*/}"
    done
}

do_start()
{
    [ -n "${INIT_PATH}" ] || return 0

    local full="${CHROOT_DIR}${INIT_PATH}"
    [ -e "${full}" ] || { msg "[跳过] 容器内不存在 ${INIT_PATH}"; return 0; }

    if [ -f "${full}" ]; then
        msg ":: 启动 run-parts 脚本: "
        run_part "${INIT_PATH}" start
    else
        local services
        services=$(run_parts_services "${full}")
        if [ -n "${services}" ]; then
            msg ":: 启动 run-parts 服务: "
            local part
            for part in ${services}
            do
                run_part "${INIT_PATH%/}/${part}" start
            done
        else
            msg "[跳过] ${INIT_PATH} 下没有可执行的服务脚本"
        fi
    fi

    return 0
}

do_stop()
{
    [ -n "${INIT_PATH}" ] || return 0

    local full="${CHROOT_DIR}${INIT_PATH}"
    [ -e "${full}" ] || { msg "[跳过] 容器内不存在 ${INIT_PATH}"; return 0; }

    if [ -f "${full}" ]; then
        msg ":: 停止 run-parts 脚本: "
        run_part "${INIT_PATH}" stop
    else
        local services
        # 逆序停止不依赖 tac（Android/toybox 与部分精简容器没有该命令），
        # 改用 awk 缓存后倒序输出
        services=$(run_parts_services "${full}" | awk '{a[NR]=$0} END{for(i=NR;i>0;i--) print a[i]}')
        if [ -n "${services}" ]; then
            msg ":: 停止 run-parts 服务: "
            local part
            for part in ${services}
            do
                run_part "${INIT_PATH%/}/${part}" stop
            done
        fi
    fi

    return 0
}

do_help()
{
cat <<EOF
   --init-path="${INIT_PATH}"
     容器内要执行的脚本文件或脚本目录。

   --init-user="${INIT_USER}"
     以指定用户执行，默认 "root"。

   --init-async
     异步启动进程。

EOF
}
