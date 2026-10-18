#!/bin/sh
# Linux Deploy 组件：Ubuntu 引导
# (c) Anton Skshidlevsky <meefik@gmail.com>, GPLv3
# 维护：GanYu256（CLI 4.0 重构，中文注释与日志）
#
# 说明：与 bootstrap/debian 共用同一套内置官方 debootstrap（scripts 目录
# 含 jammy/noble/focal 等 Ubuntu 代号脚本），安装流程完全一致；
# 差异仅在 apt 源组件（main universe multiverse）与默认镜像源。
# 注意：本组件此前缺少 do_install，部署时被空默认实现顶替，
# rootfs 从未真正安装（部署秒完成、启动必失败），此文件为修复补全。

# 发行版代号，默认 focal（20.04）
# 可用值：resolute(26.04) noble(24.04) jammy(22.04) focal(20.04)
# 说明：resolute 为 26.04 LTS，ports 源正常同步；已 EOL 的临时版
# （oracular/plucky/questing 等）已从 ports.ubuntu.com 移除，装它们需换
# old-releases 源，故不列入推荐值
[ -n "${SUITE}" ] || SUITE="focal"

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

# 软件源：arm 系架构的官方仓库在 ports（archive.ubuntu.com 不含 arm64）
if [ -z "${SOURCE_PATH}" ]
then
    case "$(get_platform ${ARCH})" in
    x86*) SOURCE_PATH="http://archive.ubuntu.com/ubuntu/" ;;
    arm*) SOURCE_PATH="http://ports.ubuntu.com/" ;;
    esac
fi

# 基础安装包清单（与 bootstrap/debian 保持一致）
# - locales：本地化支持
# - sudo：权限管理
# - man-db：手册数据库
# - python3：systemctl（python 实现）运行依赖
# 注意：
# 1) Ubuntu 官方 rootfs 默认自带 hostname/tzdata，重复列入只会拖慢下载；
# 2) --include 只能取 main 分区（debootstrap 一阶段只索引 main），
#    universe 包（如 fish）会被报 "E: Couldn't find these debs" 直接中断部署，
#    这类包放到二阶段配好 main/universe/multiverse 源后再用 apt 安装（见 do_install）；
# 3) fish 属于可选增强：镜像站 universe 未同步时 apt 安装失败不应让整个部署失败。
BASE_INCLUDE_PACKAGES="locales,sudo,man-db,python3,tzdata"
# 排除包清单（容器内不需要 init 与 systemd 引导）
BASE_EXCLUDE_PACKAGES="init,systemd-sysv"
# 一阶段完成后额外安装的包（依赖 non-main 分区，需先配好完整 apt 源）
BASE_UNIVERSE_PACKAGES="fish"

# apt 安装函数 apt_install 已下沉到 cli.sh 公共层（bootstrap 与后续组件共用），
# 此处不再重复定义，避免两处实现不一致。

# 确保容器内核心虚拟文件系统可用（与 bootstrap/debian 相同）
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

# 配置 apt 软件源（Ubuntu 组件：main universe multiverse）
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
    # 写入正式软件源。
    # Ubuntu 24.04（noble）起 deb822 格式（/etc/apt/sources.list.d/ubuntu.sources）是
    # 官方默认，旧的单行 sources.list 仍被支持；但若两者同时存在，重复的源会在
    # apt update 时产生 "Target Packages is configured multiple times" 告警。
    # 这里统一改用 deb822 覆盖官方源文件，并清空旧 sources.list，避免两份源打架。
    local src="${SOURCE_PATH%/}"
    local suites="${SUITE} ${SUITE}-updates ${SUITE}-security"
    local components="main universe multiverse restricted"
    mkdir -p "${CHROOT_DIR}/etc/apt/sources.list.d"
    {
        echo "Types: deb"
        echo "URIs: ${src}/"
        echo "Suites: ${suites}"
        echo "Components: ${components}"
        echo "Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg"
    } > "${CHROOT_DIR}/etc/apt/sources.list.d/ubuntu.sources"
    # 无签名的第三方/镜像源（archive 未同步 keyring）不做强校验：仅在源为 http 时放宽，
    # 避免部分镜像站 Release 签名缺失导致 apt update 整体失败
    case "${src}" in
    http://*) sed -i '/^Signed-By:/d' "${CHROOT_DIR}/etc/apt/sources.list.d/ubuntu.sources" ;;
    esac
    : > "${CHROOT_DIR}/etc/apt/sources.list"
    # 后端已固化的旧配置：删除重复的官方源文件（保留用户自定义源）
    local f
    for f in "${CHROOT_DIR}"/etc/apt/sources.list.d/*.list "${CHROOT_DIR}"/etc/apt/sources.list.d/*.sources
    do
        [ -f "${f}" ] || continue
        case "${f##*/}" in
        ubuntu.sources) continue ;;
        esac
        # 只清理指向 Ubuntu 官方/典型镜像的源文件，避免误删用户自建源
        if grep -Eq 'ubuntu\.com|ubuntu-ports|aliyun\.com|tuna\.tsinghua|ustc\.edu\.cn|mirrors\.' "${f}" 2>/dev/null; then
            rm -f "${f}"
        fi
    done
}

# 安装主流程：debootstrap 一阶段（解包）+ 二阶段（chroot 内配置）
do_install()
{
    # 支持直接导入 rootfs 归档作为安装源
    is_archive "${SOURCE_PATH}" && return 0

    msg ":: 正在安装 ${COMPONENT} ... "

    # 使用官方 debootstrap（与 bootstrap/debian 共用内置 1.0.144，
    # scripts 目录含 Ubuntu 各代号脚本）
    local DEBOOTSTRAP_DIR rc_file debootstrap_rc
    DEBOOTSTRAP_DIR="$(component_dir bootstrap/debian)/debootstrap"
    mkdir -p "${TEMP_DIR}" 2>/dev/null || true
    rc_file=$(mktemp "${TEMP_DIR}/ld-debootstrap.XXXXXX") || return 1

    # 一阶段：仅解包基础系统到目标目录
    # --no-check-gpg：跳过 Release 签名校验（离线/镜像场景必需）
    # --foreign：只做第一段（目标架构与主机不一致时的标准做法）
    # --extractor=ar：安卓环境缺少 dpkg-deb 时的降级解包器
    # 注意：必须以"执行"方式调用官方 debootstrap，绝不可 source（source 时 $0 变成外层 shell，save_variables 的 cp "$0" 会拿 shell 名当文件复制）
    # 输出经 log_stream 实时回显并写入日志文件
    # debootstrap 失败时只有 info 级输出（W:/E:），安卓上典型表现是
    # 卡在下载 Release/Packages 无声退出；这里前后附上阶段提示与退出码，
    # 方便直接判断是网络/安装源问题还是解包问题。
    log_note ":: debootstrap 一阶段（下载并解包 ${SUITE}/${ARCH}）..."
    if [ "${TARGET_TYPE:-directory}" = "directory" ]; then
        log_note "   安装方式: 目录（${CHROOT_DIR}），源: ${SOURCE_PATH}"
    fi
    # HTTPS 源支持：宿主 wget 不认安卓系统证书库，直接访问 https 会报
    # "Certificate error"。这里把系统 CA 合并成 PEM 交给 debootstrap 的
    # --ca-certificate 参数，保持证书校验而不是关闭校验。仅 https 源需要。
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
        log_note "debootstrap 一阶段失败（退出码 ${debootstrap_rc}）"
        msg "debootstrap 一阶段失败（退出码 ${debootstrap_rc}），请检查安装源与网络"
        return 1
    fi
    log_note "debootstrap 一阶段完成"

    # 一阶段完成：容器内已具备 glibc，此时启用构建期 statx 兼容层
    # （内核 <5.8 时，systemd≥260 的 postinst 需要 STATX_MNT_ID，见 cli.sh）
    statx_shim_install || true

    # 挂载核心虚拟文件系统，准备二阶段
    component_exec core/emulator core/mnt core/net

    # 二阶段前确保 /dev 为宿主 bind：部分设备一阶段 mknod 的设备节点带
    # 数据目录 SELinux 标签，无法作为设备打开，debootstrap 自身的
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
    msg "正在安装 command-not-found ..."
    apt_install command-not-found
    is_ok || msg "[警告] command-not-found 安装失败（不影响容器使用）"

    # 安装非 main 分区的默认包（fish 在 universe）。此处在完整源配置后执行，
    # 失败不阻断部署：fish 属可选增强（部分镜像站未同步 universe），
    # 基础系统与 SSH 已可用，缺 shell 只需手动 apt install 补装即可。
    if [ -n "${BASE_UNIVERSE_PACKAGES}" ]; then
        msg "正在安装 ${BASE_UNIVERSE_PACKAGES}（可选）..."
        apt_install ${BASE_UNIVERSE_PACKAGES}
        is_ok || msg "[提示] ${BASE_UNIVERSE_PACKAGES} 安装失败（可选组件，不影响系统与 SSH 使用）"
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
     发行版代号，支持 "resolute"(26.04), "noble"(24.04), "jammy"(22.04), "focal"(20.04)。

   --source-path="${SOURCE_PATH}"
     安装源，可指定软件源地址或 rootfs 归档路径（arm64 使用 ports.ubuntu.com）。

   --extra-packages="${EXTRA_PACKAGES}"
     额外安装的软件包列表，以空格分隔。

HELP_EOF
}
