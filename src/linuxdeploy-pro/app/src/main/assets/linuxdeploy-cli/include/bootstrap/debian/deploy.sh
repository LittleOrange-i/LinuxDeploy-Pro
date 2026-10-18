#!/bin/sh
# Linux Deploy 组件：Debian GNU/Linux 引导
# (c) Anton Skshidlevsky <meefik@gmail.com>, GPLv3
# 维护：GanYu256（CLI 4.0 重构，中文注释与日志）

# 发行版代号，默认 trixie（Debian 13）
# 可用值：trixie(13) bookworm(12) bullseye(11) stable testing unstable
[ -n "${SUITE}" ] || SUITE="trixie"

# 架构自动推断；本项目只维护 arm64，其余分支保留兼容
if [ -z "${ARCH}" ]
then
    case "$(get_platform)" in
    x86) ARCH="i386" ;;
    x86_64) ARCH="amd64" ;;
    arm) ARCH="armhf" ;;
    arm_64) ARCH="arm64" ;;
    esac
fi

# 软件源，默认中科大 HTTP 镜像源
# 说明：https 源同样受支持（cli.sh 合并系统 CA 后传给 debootstrap
# --ca-certificate，保持证书校验）；若网络对镜像存在劫持，可在配置中
# 指定 --source-path 覆盖为其他源
[ -n "${SOURCE_PATH}" ] || SOURCE_PATH="http://mirrors.ustc.edu.cn/debian/"

# 基础安装包清单（trixie 实测通过）
# - locales：本地化支持
# - sudo：权限管理
# - man-db：手册数据库
# - python3：systemctl（python 实现）运行依赖
# - hostname：core/hostname 组件需要 hostname 命令（debootstrap 基础包不含）
# - tzdata：时区数据库，core/timezone 需要 /usr/share/zoneinfo/<时区>
# 注意：debootstrap 一阶段只索引 main 分区，非 main 的包（如 fish）会报
# "E: Couldn't find these debs" 直接中断部署；这类包放到二阶段配好完整源
# 后用 apt 安装（见 do_install）。
BASE_INCLUDE_PACKAGES="locales,sudo,man-db,python3,hostname,tzdata"
# 排除包清单（容器内不需要 init 与 systemd 引导）
BASE_EXCLUDE_PACKAGES="init,systemd-sysv"
# 一阶段完成后额外安装的包（依赖非 main 分区，需先配好完整 apt 源）
BASE_UNIVERSE_PACKAGES="fish"

# apt 安装函数 apt_install 已下沉到 cli.sh 公共层（bootstrap 与后续组件共用），
# 此处不再重复定义，避免两处实现不一致。

# 确保容器内核心虚拟文件系统可用
# debootstrap 二阶段结束退出时，会自动卸载 /proc、/sys、/dev、/dev/shm、/dev/pts，
# 导致后续 apt 安装额外软件包时 /dev/pts 不可用（posix_openpt 报错）、
# systemd-tmpfiles 报 /proc 未挂载。这里检测缺失项并补挂，保证后续组件在完整环境中执行。
ensure_container_fs()
{
    local missing=""
    for m in proc sys dev dev/shm dev/pts
    do
        is_mounted "${CHROOT_DIR}/${m}" || missing="${missing} ${m}"
    done
    [ -n "${missing}" ] || return 0
    msg "debootstrap 二阶段已卸载虚拟文件系统，正在补挂: ${missing}"
    container_mount ${missing} || return 1
    return 0
}

# 配置 apt 软件源
# 说明：本函数被 bootstrap/kali（EXTENDS=bootstrap/debian）复用。
# 早期实现把主机与分区写死为 Debian 的 ${SOURCE_PATH}（默认中科大 /debian/），
# Kali 部署后 sources.list 指向 Debian 仓库：apt update 报 Release 不匹配/
# 签名错误，后续装包（openssh-server 等）全部失败，表现为“能启动但 SSH 连不上”。
# 这里按发行版分别生成：
# - Debian：主源 + contrib/non-free/non-free-firmware；
# - Kali：kali-rolling 的 main/contrib/non-free/non-free-firmware；
# - Ubuntu：main/universe/multiverse/restricted（由 bootstrap/ubuntu 覆盖，这里兜底）。
apt_repository()
{
    # 备份原始 sources.list（若存在）
    if [ -e "${CHROOT_DIR}/etc/apt/sources.list" ]; then
        cp "${CHROOT_DIR}/etc/apt/sources.list" "${CHROOT_DIR}/etc/apt/sources.list.bak"
    fi
    # 规避容器内 apt 因权限下降导致的 resolv 问题（老问题修复）
    echo 'Debug::NoDropPrivs "true";' > "${CHROOT_DIR}/etc/apt/apt.conf.d/00no-drop-privs"
    # 关闭 apt 沙箱 seccomp，安卓内核不完整时避免 apt 崩溃
    echo 'apt::sandbox::seccomp "false";' > "${CHROOT_DIR}/etc/apt/apt.conf.d/999seccomp-off"
    # 确保容器内 DNS 配置可用：若缺失或为空，复用宿主 resolv.conf
    if [ ! -s "${CHROOT_DIR}/etc/resolv.conf" ]; then
        cp /etc/resolv.conf "${CHROOT_DIR}/etc/resolv.conf" 2>/dev/null || true
    fi
    # Kali 的签名由 kali-archive-keyring 提供：官方/镜像源均为 http 时无需额外配置，
    # 但 debootstrap 内置的 kali 脚本会指向 http.kali.org，这里按用户配置的源写入。
    local src="${SOURCE_PATH%/}"
    case "${DISTRIB}" in
    kali)
        # Kali 滚动源：kali-rolling 只有 main/contrib/non-free/non-free-firmware
        echo "deb ${src}/ kali-rolling main contrib non-free non-free-firmware" > "${CHROOT_DIR}/etc/apt/sources.list"
        echo "deb-src ${src}/ kali-rolling main contrib non-free non-free-firmware" >> "${CHROOT_DIR}/etc/apt/sources.list"
    ;;
    ubuntu)
        echo "deb ${src}/ ${SUITE} main universe multiverse restricted" > "${CHROOT_DIR}/etc/apt/sources.list"
        echo "deb-src ${src}/ ${SUITE} main universe multiverse restricted" >> "${CHROOT_DIR}/etc/apt/sources.list"
    ;;
    *)
        # 写入 trixie 软件源；Debian 12+ 固件组件为 non-free-firmware
        echo "deb ${src}/ ${SUITE} main contrib non-free non-free-firmware" > "${CHROOT_DIR}/etc/apt/sources.list"
        echo "deb-src ${src}/ ${SUITE} main contrib non-free non-free-firmware" >> "${CHROOT_DIR}/etc/apt/sources.list"
    ;;
    esac
}

# 安装主流程：debootstrap 一阶段（解包）+ 二阶段（chroot 内配置）
do_install()
{
    # 支持直接导入 rootfs 归档作为安装源
    is_archive "${SOURCE_PATH}" && return 0

    msg ":: 正在安装 ${COMPONENT} ... "

    # 使用官方 debootstrap（本项目内置 1.0.144）
    local DEBOOTSTRAP_DIR rc_file debootstrap_rc
    DEBOOTSTRAP_DIR="$(component_dir bootstrap/debian)/debootstrap"
    mkdir -p "${TEMP_DIR}" 2>/dev/null || true
    rc_file=$(mktemp "${TEMP_DIR}/ld-debootstrap.XXXXXX") || return 1

    # 一阶段：仅解包基础系统到目标目录
    # --no-check-gpg：跳过 Release 签名校验（离线/镜像场景必需）
    # --foreign：只做第一段（目标架构与主机不一致时的标准做法）
    # --extractor=ar：安卓环境缺少 dpkg-deb 时的降级解包器
    # 注意：必须以“执行”方式调用官方 debootstrap，绝不可 source（source 时 $0 变成外层 shell，save_variables 的 cp "$0" 会拿 shell 名当文件复制）
    # 输出经 log_stream 实时回显并写入日志文件
    log_note ":: debootstrap 一阶段（下载并解包 ${SUITE}/${ARCH}）..."
    # HTTPS 源支持：宿主 wget 不认安卓系统证书库，直接访问 https 会报
    # "Certificate error"。这里把系统 CA 合并成 PEM 交给 debootstrap
    # （--ca-certificate），保持证书校验而不是关闭校验。仅 https 源需要。
    local ca_arg=""
    case "${SOURCE_PATH}" in
    https://*)
        local ca_bundle
        ca_bundle=$(env_ca_bundle)
        if [ -n "${ca_bundle}" ]; then
            ca_arg="--ca-certificate=${ca_bundle}"
            log_note "   安装源为 https，已启用系统 CA 证书校验（${ca_bundle}）"
        else
            log_note "   [警告] 未能生成系统 CA 证书包，https 源可能因证书校验失败"
        fi
    ;;
    esac
    (
        # shellcheck disable=SC2086
        env DEBOOTSTRAP_DIR="${DEBOOTSTRAP_DIR}" $(env_wget_vars) "${DEBOOTSTRAP_DIR}/debootstrap" --no-check-gpg ${ca_arg} --foreign --extractor=ar --arch="${ARCH}" --exclude="${BASE_EXCLUDE_PACKAGES}" --include="${BASE_INCLUDE_PACKAGES}" "${SUITE}" "${CHROOT_DIR}" "${SOURCE_PATH}" 2>&1
        echo $? > "${rc_file}"
    ) | log_stream
    debootstrap_rc=$(cat "${rc_file}")
    rm -f "${rc_file}"
    if [ "${debootstrap_rc}" -ne 0 ]; then
        msg "debootstrap 一阶段失败（退出码 ${debootstrap_rc}），请检查安装源与网络"
        return 1
    fi

    # 一阶段完成：容器内已具备 glibc，此时启用构建期 statx 兼容层
    # （内核 <5.8 时，systemd≥260 的 postinst 需要 STATX_MNT_ID，见 cli.sh）
    statx_shim_install || true

    # 挂载核心虚拟文件系统，准备二阶段
    component_exec core/emulator core/mnt core/net

    # 二阶段前确保 /dev 为宿主 bind：部分设备（如 k pad）一阶段 mknod 的
    # 设备节点带数据目录 SELinux 标签，无法作为设备打开，debootstrap 自身的
    # /dev/null 重定向会 Permission denied（二阶段退出时会卸载，随后补挂）
    if ! is_mounted "${CHROOT_DIR}/dev"; then
        container_mount dev shm pts || true
    fi

    # 二阶段：在 chroot 内完成包配置
    unset DEBOOTSTRAP_DIR
    rc_file=$(mktemp "${TEMP_DIR}/ld-second.XXXXXX") || return 1
    (
        chroot_exec /debootstrap/debootstrap --no-check-gpg --second-stage 2>&1
        echo $? > "${rc_file}"
    ) | log_stream
    debootstrap_rc=$(cat "${rc_file}")
    rm -f "${rc_file}"
    if [ "${debootstrap_rc}" -ne 0 ]; then
        msg "debootstrap 二阶段失败（退出码 ${debootstrap_rc}），请查看上方日志"
        return 1
    fi

    # 二阶段退出时虚拟文件系统被卸载，先补挂再继续 apt，避免 /dev/pts、/proc 缺失
    ensure_container_fs || return 1

    apt_install -f -qq
    is_ok || return 1

    # 写入正式软件源并更新索引
    msg -n "正在更新软件源 ... "
    apt_repository
    is_ok "失败" "完成"

    # 默认安装 command-not-found：输入未知命令时提示正确的包名建议。
    # 依赖 apt 源已配置；失败不阻断部署（属增强功能，容器仍可用）。
    # 说明：前端已移除"额外软件包"输入，容器部署后手动安装即可。
    msg "正在安装 command-not-found ..."
    apt_install command-not-found
    is_ok || msg "[警告] command-not-found 安装失败（不影响容器使用）"

    # 安装非 main 分区的默认包（fish）。此处在完整源配置后执行，
    # 失败不阻断部署：基础系统已可用，shell 缺失只需手动 apt install 补装。
    if [ -n "${BASE_UNIVERSE_PACKAGES}" ]; then
        msg "正在安装 ${BASE_UNIVERSE_PACKAGES} ..."
        apt_install ${BASE_UNIVERSE_PACKAGES}
        is_ok || msg "[警告] ${BASE_UNIVERSE_PACKAGES} 安装失败（可在容器内执行 apt install 补装）"
    fi

    # 安装额外软件包（可选，CLI 命令行参数仍支持）
    if [ -n "${EXTRA_PACKAGES}" ]; then
      local extra_pkgs
      extra_pkgs=$(normalize_packages "${EXTRA_PACKAGES}")
      if [ -n "${extra_pkgs}" ]; then
          msg "正在安装额外软件包: ${extra_pkgs}"
          apt_install ${extra_pkgs}
          is_ok || return 1
      fi
    fi

    return 0
}

# 帮助文本
do_help()
{
cat <<HELP_EOF
   --arch="${ARCH}"
     目标架构，支持 "armel", "armhf", "arm64", "i386" 和 "amd64"（本项目只维护 arm64）。

   --suite="${SUITE}"
     发行版代号，支持 "trixie"(13), "bookworm"(12), "bullseye"(11) 及 stable/testing/unstable。

   --source-path="${SOURCE_PATH}"
     安装源，可指定软件源地址或 rootfs 归档路径。

   --extra-packages="${EXTRA_PACKAGES}"
     额外安装的软件包列表，以空格分隔。

HELP_EOF
}
