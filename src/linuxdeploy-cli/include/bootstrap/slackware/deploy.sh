#!/bin/sh
# Linux Deploy Component
# (c) Anton Skshidlevsky <meefik@gmail.com>, GPLv3
# 维护：GanYu256（各发行版兼容修复）
#
# 本项目只维护 arm64（aarch64），Slackware 的 ARM 分支结构与 x86 完全不同：
# 1) 目录：ARM 只有 <源>/slackwarearm/slackwareaarch64-current/（16.0 尚未正式发布，
#    ARM 侧仅提供 current 开发分支）；x86 为 <源>/slackware64-15.0/；
# 2) 包清单：FTP 根目录只有 CHECKSUMS.md5，FILE_LIST 位于仓库子目录 slackware/ 下；
# 3) 包索引：ARM 的包在 slackware/a、slackware/ap…，x86_64 在 slackware64/a…；
# 4) 发行代号：Slackware ARM 没有 15.0/14.2 的 aarch64 版本，SUITE 必须映射为 current。
# 早期实现把 SUITE 直接拼进路径（slackwareaarch64-15.0、x86 源下取 aarch64），
# 且 FILE_LIST 取错位置，表现为“正在获取软件包列表”阶段直接失败。

[ -n "${SUITE}" ] || SUITE="current"

if [ -z "${ARCH}" ]
then
    case "$(get_platform)" in
    x86) ARCH="x86" ;;
    x86_64) ARCH="x86_64" ;;
    arm*) ARCH="arm" ;;
    esac
fi

# 判断是否为 Slackware ARM / AArch64 分支（架构为 arm* 或软件源指向 slackwarearm）
slack_is_arm()
{
    case "$(get_platform ${ARCH})" in
    arm*) return 0 ;;
    esac
    case "${SOURCE_PATH%/}" in
    *slackwarearm*|*arm.slackware*) return 0 ;;
    esac
    return 1
}

# 归一化发行代号：
# - ARM 分支：只存在 slackwarearm-<ver>（32 位）与 slackwareaarch64-current（64 位）；
#   aarch64 只有 current，传任何版本号都映射为 current（避免 404）；
# - x86_64：slackware64-<ver>，版本号原样使用。
slack_suite()
{
    if slack_is_arm; then
        case "$(get_platform ${ARCH})" in
        arm_64) echo "current" ;;
        *)
            # 32 位 ARM 分支带版本目录（如 slackwarearm-15.0）
            case "${SUITE}" in
            current|"") echo "14.2" ;;
            *) echo "${SUITE}" ;;
            esac
        ;;
        esac
        return 0
    fi
    echo "${SUITE}"
}

# 计算仓库根地址（到发行分支目录），输出到 stdout
slack_repo_root()
{
    local suite
    suite=$(slack_suite)
    if slack_is_arm; then
        case "$(get_platform ${ARCH})" in
        arm_64) echo "${SOURCE_PATH%/}/slackwareaarch64-${suite}" ;;
        *) echo "${SOURCE_PATH%/}/slackwarearm-${suite}" ;;
        esac
        return 0
    fi
    case "$(get_platform ${ARCH})" in
    x86_64) echo "${SOURCE_PATH%/}/slackware64-${suite}" ;;
    *) echo "${SOURCE_PATH%/}/slackware-${suite}" ;;
    esac
}

# 包集合目录前缀：ARM 与 x86 都是 slackware/，x86_64 为 slackware64/
slack_pkg_prefix()
{
    if slack_is_arm; then
        echo "slackware"
    else
        case "$(get_platform ${ARCH})" in
        x86_64) echo "slackware64" ;;
        *) echo "slackware" ;;
        esac
    fi
}

slackpkg_repository()
{
    if [ -e "${CHROOT_DIR}/etc/slackpkg/mirrors" ]; then
        cp "${CHROOT_DIR}/etc/slackpkg/mirrors" "${CHROOT_DIR}/etc/slackpkg/mirrors.bak"
    fi
    local repo_url
    repo_url="$(slack_repo_root)/"
    mkdir -p "${CHROOT_DIR}/etc/slackpkg"
    echo "${repo_url}" > "${CHROOT_DIR}/etc/slackpkg/mirrors"
    chmod 644 "${CHROOT_DIR}/etc/slackpkg/mirrors"
    sed -i 's|^WGETFLAGS=.*|WGETFLAGS="--passive-ftp -q"|g' "${CHROOT_DIR}/etc/slackpkg/slackpkg.conf"
}

do_install()
{
    is_archive "${SOURCE_PATH}" && return 0

    msg ":: 正在安装 ${COMPONENT} ... "

    local root prefix repo_url pkg_list pkg_list_raw
    root=$(slack_repo_root)
    prefix=$(slack_pkg_prefix)
    repo_url="${root}/${prefix}"

    local cache_dir="${CHROOT_DIR}/tmp"
    # 基础包：按 aarch64 实际包名（glibc-solibs 由 aaa_glibc-solibs 提供；
    # slackpkg/sudo/gnupg/wget/ca-certificates/openssl/perl 均在 ap/n/d 目录）
    local base_packages="l/glibc l/ncurses ap/diffutils ap/groff ap/man ap/slackpkg ap/sudo n/gnupg n/wget l/libunistring n/ca-certificates n/openssl d/perl"

    msg -n "正在准备部署 ... "
    (set -e
        mkdir -p "${CHROOT_DIR}"
        cd "${CHROOT_DIR}"
        [ -d etc ] || mkdir etc
        [ -e etc/fstab ] || touch etc/fstab
        mkdir -p tmp; chmod 1777 tmp
    exit 0)
    is_ok "失败" "完成" || return 1

    msg -n "正在获取软件包列表 ... "
    # FILE_LIST 在仓库子目录（slackware/ 或 slackware64/）下，不在 FTP 根目录。
    # 注意：该文件是 `ls -lR` 风格的目录清单，包路径位于行尾而不是行首，形如
    #   -rw-r--r--  1 root root 54364 2026-09-06 20:44 ./a/aaa_terminfo-6.6-aarch64-2.txz
    # 旧实现按“行首就是相对路径”解析，永远匹配不到任何包，表现为
    # “正在解析基础软件包”直接失败（提示镜像不完整）。
    # 这里先规范化清单：只取 .txz 行的路径字段（保留 ./ 前缀），
    # 后续 grep/sed 仍按原格式（^\./a/<包名>-）工作，无需改动其他逻辑。
    pkg_list_raw="${cache_dir}/FILE_LIST"
    pkg_list="${cache_dir}/packages.list"
    if ! wget -q -T 60 -O "${pkg_list_raw}" "${repo_url}/FILE_LIST"; then
        msg "失败"
        msg "[提示] 无法下载软件包清单：${repo_url}/FILE_LIST"
        msg "        请确认软件源指向 Slackware 镜像根（aarch64 仅提供 slackwareaarch64-current）。"
        return 1
    fi
    sed -n 's|^.*[[:space:]]\(\./[^[:space:]]*\.txz\)$|\1|p' "${pkg_list_raw}" > "${pkg_list}"
    if ! grep -q '\.txz$' "${pkg_list}" 2>/dev/null; then
        msg "失败"
        msg "[提示] 软件包清单无效（${repo_url}/FILE_LIST 中未解析到 .txz 包）"
        return 1
    fi
    is_ok "失败" "完成" || return 1

    # a 系列全部基础包（排除内核/引导/调试），按 tagfile 取包名再回填文件名
    msg -n "正在解析基础软件包 ... "
    local core_packages=""
    local tag name
    for tag in $(wget -q -T 60 -O - "${repo_url}/a/tagfile" 2>/dev/null | awk -F: '$1!="" {print $1}')
    do
        case "${tag}" in
        kernel*|grub*|lilo*|efibootmgr*|devs|elilo*|*.orig) continue ;;
        esac
        name=$(grep -m1 "^\./a/${tag}-" "${pkg_list}" | sed 's|^\./||')
        [ -n "${name}" ] && core_packages="${core_packages} ${name}"
    done
    if [ -z "${core_packages}" ]; then
        msg "失败"
        msg "[提示] 未能从 ${repo_url}/a/tagfile 解析到基础软件包（镜像可能不完整）"
        return 1
    fi
    is_ok "失败" "完成" || return 1

    msg "正在获取并安装软件包: "
    local package i pkg_url pkg_file
    for package in ${core_packages} ${base_packages}
    do
        # 基础包已带完整相对路径（a/xxx-ver-arch-build.txz）；
        # base_packages 只写集合/包名，需从清单里补全版本与架构
        case "${package}" in
        */*.txz) pkg_url="${package}" ;;
        *)
            pkg_url=$(grep -m1 "^\./${package}-[0-9]" "${pkg_list}" | sed 's|^\./||')
            ;;
        esac
        if [ -z "${pkg_url}" ]; then
            msg "${package} ... 跳过（清单中不存在）"
            continue
        fi
        msg -n "${pkg_url##*/} ... "
        pkg_file="${pkg_url##*/}"
        # download
        local ok="false"
        for i in 1 2 3
        do
            if wget -q -c -T 60 -O "${cache_dir}/${pkg_file}" "${repo_url}/${pkg_url}"; then
                ok="true"
                break
            fi
            sleep 5s
        done
        if [ "${ok}" != "true" ]; then
            msg "失败"
            msg "[错误] 软件包下载失败：${repo_url}/${pkg_url}"
            return 1
        fi
        # unpack
        case "${pkg_file}" in
        *gz) tar xzf "${cache_dir}/${pkg_file}" -C "${CHROOT_DIR}" --exclude='./dev' --exclude='./sys' --exclude='./proc';;
        *bz2) tar xjf "${cache_dir}/${pkg_file}" -C "${CHROOT_DIR}" --exclude='./dev' --exclude='./sys' --exclude='./proc';;
        *xz) tar xJf "${cache_dir}/${pkg_file}" -C "${CHROOT_DIR}" --exclude='./dev' --exclude='./sys' --exclude='./proc';;
        *) msg "失败"; return 1;;
        esac
        is_ok "失败" "完成" || return 1
        # install（doinst.sh 必须在容器内执行）
        # 关键：早期写法在“宿主”shell 中 source doinst.sh，里面的 pwconv/grpconv/
        # ldconfig 在 Android 宿主上不存在（或被 || true 吞掉），导致：
        #   - /etc/shadow 未生成 → core/profile 报“容器内缺少 /etc/shadow”并中止部署；
        #   - ldconfig 未执行 → 容器内动态链接缓存缺失。
        # 这里改为把脚本拷进容器后用 chroot_exec 执行，效果与 Slackware 安装器一致。
        # 解释器统一使用内置的静态 busybox（Slackware 安装器本身也是 busybox 环境），
        # 原因有三：
        #   1) aaa_base 是第一个解包的包，而 Slackware 的 /bin/sh -> bash 恰恰由它的
        #      doinst.sh 创建，bash 自己也要靠 bash 包的 doinst.sh 把 bin/bash5.new
        #      改名而来 —— 最早几个包执行时容器内没有任何 shell，旧写法直接调用
        #      /bin/sh 必然失败且被 || true 吞掉，形成死锁（/bin/sh、/etc/shadow、
        #      /etc/slackpkg/slackpkg.conf 全都生成不了，后者导致软件源更新失败）。
        #   2) 本设备实测：容器内 glibc/bash 的 test -r 恒为假（同一文件 -e/-f/cat
        #      均正常），而 busybox 的 test -r 正常；doinst.sh 里大量使用
        #      `[ -r ... ]` 判断配置是否已存在，用 bash 会让 /etc/pam.d/*.new 这类
        #      配置永不落地，进而 chpasswd/su 报 pam_start failure、无法设置密码。
        #   3) busybox 的 sh 自带 applet 兜底，coreutils 尚未解包时也能提供 ln/grep 等。
        if [ -e "${CHROOT_DIR}/install/doinst.sh" ]; then
            cp -f "${CHROOT_DIR}/install/doinst.sh" "${CHROOT_DIR}/tmp/doinst.sh" 2>/dev/null || true
            if [ -f "${CHROOT_DIR}/tmp/doinst.sh" ]; then
                cp -f "${TOOLS_DIR:-${ENV_DIR}/tools}/busybox" "${CHROOT_DIR}/tmp/busybox" 2>/dev/null || true
                chmod 755 "${CHROOT_DIR}/tmp/busybox" 2>/dev/null || true
                # aaa_glibc-solibs 的 doinst.sh 第一步是 `flock 9 || exit 11`
                # （并发保护），而内置 busybox 未编译 flock applet：缺 flock 会让该
                # 脚本直接跳过 /lib64/incoming → /lib64 的搬运，容器内就没有动态加载器
                # ld-linux-aarch64.so.1，所有动态链接程序都会 exec 失败
                # （报 “No such file or directory”）。容器内不存在并发安装场景，
                # 这里放一个空实现的 flock 兜底。
                printf '#!/tmp/busybox sh\nexit 0\n' > "${CHROOT_DIR}/tmp/flock" 2>/dev/null || true
                chmod 755 "${CHROOT_DIR}/tmp/flock" 2>/dev/null || true
                # doinst.sh 内部使用相对路径（etc/...、usr/...），必须在 / 下执行
                chroot_exec /tmp/busybox sh -c "cd /; PATH=/tmp:\${PATH} /tmp/busybox sh /tmp/doinst.sh" >/dev/null 2>&1 || true
                rm -f "${CHROOT_DIR}/tmp/doinst.sh"
            fi
        fi
        rm -rf "${CHROOT_DIR}/install"
    done

    # shadow 缺失时用容器内 pwconv 从 /etc/passwd 生成（doinst.sh 未生效时的兜底）
    if [ -e "${CHROOT_DIR}/etc/passwd" ] && [ ! -e "${CHROOT_DIR}/etc/shadow" ]; then
        msg -n "正在初始化 /etc/shadow ... "
        chroot_exec /usr/sbin/pwconv >/dev/null 2>&1 || chroot_exec /sbin/pwconv >/dev/null 2>&1 || true
        if [ -e "${CHROOT_DIR}/etc/shadow" ]; then
            msg "完成"
        else
            msg "跳过（容器内无 pwconv）"
        fi
    fi
    # 生成动态链接缓存（宿主没有 ldconfig，必须在容器内执行）
    if [ -x "${CHROOT_DIR}/sbin/ldconfig" ] || [ -x "${CHROOT_DIR}/usr/sbin/ldconfig" ]; then
        chroot_exec /sbin/ldconfig >/dev/null 2>&1 || chroot_exec /usr/sbin/ldconfig >/dev/null 2>&1 || true
    fi

    # 包解包完成：容器内已具备 glibc，启用构建期 statx 兼容层
    statx_shim_install || true

    # 挂载虚拟文件系统并配置网络，供后续组件与软件源更新使用
    component_exec core/emulator core/mnt core/net

    msg -n "正在更新软件源 ... "
    slackpkg_repository
    is_ok "失败" "完成"

    msg -n "正在清理缓存 ... "
    rm -f "${cache_dir}"/*
    is_ok "跳过" "完成"

    # 额外软件包（可选）：用 slackpkg 安装，失败不阻断基础系统
    if [ -n "${EXTRA_PACKAGES}" ]; then
        msg "正在安装额外软件包: ${EXTRA_PACKAGES}"
        slackpkg_install $(normalize_packages "${EXTRA_PACKAGES}")
        is_ok "失败" "完成"
    fi

    return 0
}

do_help()
{
cat <<EOF
   --arch="${ARCH}"
     Architecture of Linux distribution, supported "arm", "x86", "x86_64"（本项目只维护 arm64）。

   --suite="${SUITE}"
     Slackware aarch64 仅提供 "current"；32 位 ARM 可用 "14.2"，x86_64 可用 "15.0"/"current"。

   --source-path="${SOURCE_PATH}"
     Installation source, can specify address of the repository or path to the rootfs archive.

   --extra-packages="${EXTRA_PACKAGES}"
     List of optional installation packages, separated by spaces.

EOF
}
