#!/bin/sh
# Linux Deploy Component
# (c) Anton Skshidlevsky <meefik@gmail.com>, GPLv3
# 维护：GanYu256（各发行版兼容修复）

[ -n "${SUITE}" ] || SUITE="latest-stable"

if [ -z "${ARCH}" ]
then
    case "$(get_platform)" in
    x86) ARCH="x86" ;;
    x86_64) ARCH="x86_64" ;;
    arm) ARCH="armhf" ;;
    arm_64) ARCH="aarch64" ;;
    esac
fi
# Alpine 官方发布目录使用 aarch64 代号；即使配置中显式指定 arm64 也统一映射
case "${ARCH}" in
arm64) ARCH="aarch64" ;;
esac

[ -n "${SOURCE_PATH}" ] || SOURCE_PATH="http://dl-cdn.alpinelinux.org/alpine/"

# 归一化软件源目录：Alpine 仓库根是 “<源>/<版本分支>/”，即 …/alpine/v3.22。
# 前端默认镜像（镜像站根 /alpine/）与用户手填的 …/alpine/v3.22 都可能出现，
# 早期实现会把版本号再拼一次，得到 …/alpine/v3.22/v3.22/main 导致 404，
# 表现为部署在“正在获取 rootfs 归档”阶段失败。
apk_branch()
{
    local src="${SOURCE_PATH%/}" suite="${SUITE}"
    # 源里已带版本目录（v3.x / edge）时以源为准，不再重复拼接
    case "${src}" in
    */v[0-9]*.*|*/edge) echo "${src}"; return 0 ;;
    esac
    case "${suite}" in
    ""|latest-stable|stable|latest) echo "${src}/latest-stable" ;;
    v[0-9]*|edge) echo "${src}/${suite}" ;;
    *) echo "${src}/v${suite}" ;;
    esac
}

# wget 附加参数（供获取 rootfs 归档的几处 wget 复用）。两个平台性原因：
# 1) 宿主内置 wget 是 GNU Wget2，不读安卓系统证书库
#    /system/etc/security/cacerts，直接访问 https 源会报 “Certificate error”
#    （wget 退出码 5），表现为“正在获取 rootfs 归档 ... 失败”；
#    这里复用 cli.sh 的 env_ca_bundle 生成 PEM 证书包，用 --ca-certificate 传入，
#    保持证书校验而不是关闭校验（与 archlinux/debian 组件同一做法）；
# 2) 部分镜像站（如清华 TUNA）的 nginx 防护会拦截 Wget2 默认 UA 返回 403，
#    统一改用通用 wget UA（实测换 UA 即 200）。
apk_wget_opts()
{
    local opts="-U Wget/1.21.3"
    case "${SOURCE_PATH}" in
    https://*)
        local ca_bundle
        ca_bundle=$(env_ca_bundle)
        [ -n "${ca_bundle}" ] && opts="${opts} --ca-certificate=${ca_bundle}"
        ;;
    esac
    echo "${opts}"
}

# rootfs 归档名：优先读 latest-releases.yaml；
# 镜像站未同步该文件或格式变化时，回退为目录列表匹配（不依赖文件内的字段顺序）。
apk_rootfs_name()
{
    local branch="$1" name=""
    name=$(wget $(apk_wget_opts) -q -O - "${branch}/releases/${ARCH}/latest-releases.yaml" 2>/dev/null \
        | grep -m1 "file: alpine-minirootfs" | awk '{print $2}' | tr -d '"' | tr -d "'")
    if [ -z "${name}" ]; then
        # 回退：抓目录索引，取最新的 alpine-minirootfs-<版本>-<arch>.tar.gz。
        # 注意：Android toybox 的 sort 不支持 -V（会报 invalid option），
        # 这里按“主/次/修订版本号数值”比较，保证设备上同样可用。
        local ver f a b
        for f in $(wget $(apk_wget_opts) -q -O - "${branch}/releases/${ARCH}/" 2>/dev/null \
            | grep -o "alpine-minirootfs-[0-9][0-9.]*-${ARCH}\.tar\.gz" | sort -u)
        do
            # 从文件名截出版本号：alpine-minirootfs-3.22.6-aarch64.tar.gz → 3.22.6
            ver="${f#alpine-minirootfs-}"
            ver="${ver%-${ARCH}.tar.gz}"
            case "${ver}" in
            ''|*[!0-9.]*) continue ;;
            esac
            [ -n "${name}" ] || { name="${ver}"; continue; }
            a=$(printf '%s\n' "${ver}" | awk -F. '{printf "%03d%03d%03d", $1+0, $2+0, $3+0}')
            b=$(printf '%s\n' "${name}" | awk -F. '{printf "%03d%03d%03d", $1+0, $2+0, $3+0}')
            if [ "${a}" -gt "${b}" ] 2>/dev/null; then
                name="${ver}"
            fi
        done
        [ -n "${name}" ] && name="alpine-minirootfs-${name}-${ARCH}.tar.gz"
    fi
    [ -n "${name}" ] || return 1
    echo "${name}"
}

apk_repository()
{
  local branch
  branch=$(apk_branch)
  # Backup repositories
  if [ -e "${CHROOT_DIR}/etc/apk/repositories" ]; then
      cp "${CHROOT_DIR}/etc/apk/repositories" "${CHROOT_DIR}/etc/apk/repositories.bak"
  fi
  # Update repositories（branch 已含版本目录，避免重复拼接）
  mkdir -p "${CHROOT_DIR}/etc/apk"
  echo "${branch}/main" > "${CHROOT_DIR}/etc/apk/repositories"
  echo "${branch}/community" >> "${CHROOT_DIR}/etc/apk/repositories"
  # Alpine 默认不信任 https 源，若用户配置了 https 镜像需装证书后才会生效；
  # 部署阶段先用 http 完成基础安装，软件源原样写入（由 ca-certificates 保障）。
  if [ ! -s "${CHROOT_DIR}/etc/resolv.conf" ] && [ -s /etc/resolv.conf ]; then
      cp /etc/resolv.conf "${CHROOT_DIR}/etc/resolv.conf" 2>/dev/null || true
  fi
}

# apk 安装函数已下沉到 cli.sh 公共层（bootstrap 与后续组件共用），此处不再重复定义。

do_install()
{
    is_archive "${SOURCE_PATH}" && return 0

    msg ":: 正在安装 ${COMPONENT} ... "

    local branch rootfs_name
    branch=$(apk_branch)
    msg -n "正在获取 rootfs 归档 ... "
    rootfs_name=$(apk_rootfs_name "${branch}")
    if [ -z "${rootfs_name}" ]; then
        msg "失败"
        msg "[提示] 无法从 ${branch}/releases/${ARCH}/ 获取 Alpine rootfs 文件名。"
        msg "        请检查软件源地址（应指向 Alpine 仓库根，如 http://mirrors.tuna.tsinghua.edu.cn/alpine/）与网络。"
        return 1
    fi
    msg "完成（${rootfs_name}）"
    mkdir -p "${CHROOT_DIR}"
    if ! wget $(apk_wget_opts) -q -O - "${branch}/releases/${ARCH}/${rootfs_name}" | tar xz -C "${CHROOT_DIR}" 2>/dev/null; then
        msg "[错误] Alpine rootfs 下载或解包失败（${branch}/releases/${ARCH}/${rootfs_name}）"
        return 1
    fi
    if [ ! -e "${CHROOT_DIR}/etc/alpine-release" ] && [ ! -x "${CHROOT_DIR}/bin/busybox" ]; then
        msg "[错误] 解包后未检测到 Alpine 基础系统文件，rootfs 可能不完整"
        return 1
    fi

    component_exec core/emulator core/mnt core/net

    msg -n "正在更新软件源 ... "
    apk_repository
    is_ok "失败" "完成"

    msg "正在安装软件包: "
    # 通用性：与 Debian 系对齐，补齐各组件会用到的常见工具。
    # - shadow：提供 useradd/chpasswd（core/profile、core/aid 依赖）
    # - sudo / tzdata：权限与时区（core/sudo、core/timezone）
    # - bash：脚本与交互默认 shell（ldstatus、终端优先使用）
    # - curl、wget、ca-certificates：包下载与 https 校验（各组件/用户常用）
    # - openssh-client：容器内可主动 ssh 出去（部分组件与用户习惯依赖）
    # - openrc：服务管理（init/openrc 组件依赖 rc-service/rc-update）
    # - util-linux：setsid 等基础工具（ldstatus 依赖 busybox 时也能兜底）
    local extra_pkgs
    extra_pkgs=$(normalize_packages "${EXTRA_PACKAGES}")
    apk_install shadow sudo tzdata bash curl wget ca-certificates openssh-client openrc util-linux ${extra_pkgs}
    is_ok || return 1

    return 0
}

do_help()
{
cat <<EOF
   --arch="${ARCH}"
     Architecture of Linux distribution, supported "aarch64", "armhf", "x86" and "x86_64".

   --suite="${SUITE}"
     Version of Linux distribution, supported version "latest-stable", "3.22", "edge".

   --source-path="${SOURCE_PATH}"
     Installation source, can specify address of the repository or path to the rootfs archive.

   --extra-packages="${EXTRA_PACKAGES}"
     List of optional installation packages, separated by spaces.

EOF
}
