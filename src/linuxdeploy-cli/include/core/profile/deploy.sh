#!/bin/sh
# Linux Deploy Component
# (c) Anton Skshidlevsky <meefik@gmail.com>, GPLv3

[ -n "${USER_NAME}" ] || USER_NAME="root"
[ -n "${USER_PASSWORD}" ] || USER_PASSWORD="changeme"

# 设置账号密码。
# 注意：chpasswd 失败时若只打印日志，账号会停留在 /etc/shadow 的 "*"（锁定态），
# 表现为 SSH 输入正确密码仍 Permission denied。这里必须把失败向上抛出，
# 并在退出码为 0 但 shadow 仍是锁定态时再报错，避免"静默未生效"。
profile_set_password()
{
    local user="${USER_NAME}" pass="${USER_PASSWORD}" shadow
    shadow="${CHROOT_DIR}/etc/shadow"
    if [ "${user}" = "root" ] && [ ! -e "${shadow}" ]; then
        msg "[错误] 容器内缺少 /etc/shadow，无法设置密码"
        return 1
    fi
    # chpasswd 读取 "用户:密码"（stdin 经 chroot_exec 透传）
    if ! printf '%s:%s\n' "${user}" "${pass}" | chroot_exec -u root chpasswd; then
        msg "[错误] chpasswd 执行失败，无法为 ${user} 设置密码"
        return 1
    fi
    # 校验：shadow 第二字段为 "*" / "!" / "!!" 表示锁定，视为设置失败
    if [ -r "${shadow}" ]; then
        local field
        field=$(awk -F: -v u="${user}" '$1==u {print $2; exit}' "${shadow}")
        case "${field}" in
        ''|'*'|'!'|'!!'|'!'*)
            msg "[错误] ${user} 的密码未生效（/etc/shadow 仍为锁定状态）"
            return 1
        ;;
        esac
    fi
    return 0
}

do_install()
{
    # 部署时也设置一次密码，避免 profile 组件因组件顺序/失败被跳过时账号无密码
    profile_set_password
    return 0
}

do_configure()
{
    msg ":: 正在配置 ${COMPONENT} ... "
    if [ -z "${USER_NAME%aid_*}" ]; then
        echo "Username \"${USER_NAME}\" is reserved."; return 1
    fi
    # user profile
    if [ "${USER_NAME}" != "root" ]; then
        chroot_exec -u root groupadd ${USER_NAME} 2>/dev/null || true
        chroot_exec -u root useradd -m -g ${USER_NAME} -s /bin/sh ${USER_NAME} 2>/dev/null || true
        chroot_exec -u root usermod -g ${USER_NAME} ${USER_NAME} 2>/dev/null || true
    fi
    # set password for user（失败必须报错，不能静默留下锁定账号）
    msg -n ":: 设置 ${USER_NAME} 密码 ... "
    if profile_set_password; then
        msg "完成"
    else
        msg "失败（SSH 将无法用密码登录）"
        return 1
    fi
    # set permissions（home 目录可能不存在，失败不阻断）
    chroot_exec -u root chown -R ${USER_NAME}:${USER_NAME} "$(user_home ${USER_NAME})" 2>/dev/null || true
    return 0
}

do_start()
{
    # 每次启动都对账一次密码：配置文件改过密码后重启容器即可生效，
    # 也修复历史容器里 root 仍为锁定态（shadow 为 "*"）的情况。
    msg -n ":: 校验 ${USER_NAME} 密码 ... "
    if profile_set_password; then
        msg "完成"
    else
        msg "失败（可在配置页检查密码后重新部署）"
        return 1
    fi
    return 0
}

do_help()
{
cat <<EOF
   --user-name="${USER_NAME}"
     Username that will be created in the container.

   --user-password="${USER_PASSWORD}"
     Password will be assigned to the specified user.

EOF
}
