package io.github.ganyu256.linuxdeploypro.data

import android.content.Context

/**
 * 容器路径实时校验：用户填写路径时即时判定"能不能用、为什么、怎么改"。
 *
 * 把底层约束翻译成大白话，避免小白用户踩坑：
 * - 手机共享存储（/storage/emulated/0、/sdcard 这类放相册和下载的地方）由
 *   FUSE/sdcardfs 挂载，系统固定禁止"把里面的文件当程序运行"
 *   （noexec/nosuid/nodev，且被内核锁定无法修改）。
 *   "目录"方式把 Linux 放进这里必然无法启动——目录方式必须拦截；
 * - "镜像"方式（ext4 镜像文件）通过 loop 挂载成真实 ext4 后再挂进容器，
 *   镜像文件本身放共享存储不受上述限制；
 * - 推荐路径：系统目录 /data/local/tmp/<名>，与应用专属目录 /data/data/<包名>/files/<名>。
 */
object StorageValidator {

    /** 校验结论（message 均为可直接展示的大白话文案） */
    data class Result(
        /** 是否允许保存（false 时保存按钮禁用） */
        val ok: Boolean,
        /** 路径是否位于共享存储（用于决定是否展示一键修正入口） */
        val sharedStorage: Boolean,
        /** 大白话说明；null 表示无需提示 */
        val message: String?,
    )

    /**
     * 常见共享存储路径前缀（FUSE/sdcardfs 视图）。
     * 注意 /data/media 是 ext4 上的真实目录，bind 挂载可用，不算共享存储。
     */
    private val SHARED_PREFIXES = listOf(
        "/storage/emulated",
        "/storage/sdcard",
        "/storage/self",
        "/storage/scratch",
        "/sdcard",
        "/mnt/sdcard",
        "/mnt/runtime",
        "/mnt/media_rw",
        "/mnt/user",
        "/mnt/installer",
        "/mnt/androidwritable",
    )

    /** 判定路径是否位于共享存储（相册/下载所在的存储区域） */
    fun isSharedStorage(path: String): Boolean {
        val p = path.trim()
        if (!p.startsWith("/")) return false
        // /storage/<UUID>（如 /storage/0000-0000，外置卡/OTG）同样属于共享存储
        if (p.startsWith("/storage/")) {
            val seg = p.removePrefix("/storage/").substringBefore('/')
            if (seg.isNotEmpty() && seg.matches(Regex("[0-9A-Fa-f]{4}(-[0-9A-Fa-f]{4})?"))) return true
        }
        return SHARED_PREFIXES.any { p == it || p.startsWith("$it/") }
    }

    /** 实时校验（输入即查，不用等保存） */
    fun validate(path: String, installType: String): Result {
        val p = path.trim()
        val shared = isSharedStorage(p)
        if (p.isEmpty()) {
            // 空路径：必填（部署需要明确的容器位置）
            return Result(
                ok = false,
                sharedStorage = false,
                message = "还没填容器路径，填一个或点下方推荐路径一键填入",
            )
        }
        if (!p.startsWith("/")) {
            return Result(
                ok = false,
                sharedStorage = shared,
                message = "路径要以 / 开头（例如 /data/local/tmp/mylinux）",
            )
        }
        if (p.contains(' ') || p.contains('\t')) {
            return Result(
                ok = false,
                sharedStorage = shared,
                message = "路径里不能有空格，请去掉空格",
            )
        }
        if (shared) {
            if (installType == "image") {
                // 镜像方式经 loop 挂载成真实 ext4，不受共享存储限制
                return Result(
                    ok = true,
                    sharedStorage = true,
                    message = "镜像方式放在共享存储没问题，可以正常使用",
                )
            }
            return Result(
                ok = false,
                sharedStorage = true,
                message = "这是共享存储（放相册、下载的地方），系统不允许在这里运行程序，" +
                    "Linux 装进来会无法启动。点下方按钮一键修正",
            )
        }
        return Result(ok = true, sharedStorage = false, message = "路径可用")
    }

    /**
     * 配置名 → 安全文件夹名：仅保留字母/数字/下划线/连字符（与配置文件名规则
     * 一致，与 ConfigStore.validConfigName 对齐）。中文、空格等特殊符号压缩为
     * 下划线并去掉首尾；净化后为空（如名称全是中文）时用默认名 "linux"。
     */
    fun safeFolderName(configName: String): String {
        val cleaned = configName.trim()
            .replace(Regex("[^A-Za-z0-9_-]+"), "_")
            .trim('_')
            .take(64)
            .trim('_')
        return cleaned.ifBlank { "linux" }
    }

    /**
     * 合规路径推荐（一键填入）。文件夹名取配置名净化后的安全形式，
     * 目录本身无需提前创建：部署时由 CLI（root）自动创建。
     * @return 列表 of (说明文字, 路径)
     */
    fun recommendations(context: Context, configName: String): List<Pair<String, String>> {
        val name = safeFolderName(configName)
        val list = mutableListOf<Pair<String, String>>()
        // 系统目录：所有 root 环境通用，重启不清空
        list.add("系统目录（推荐）" to "/data/local/tmp/$name")
        // 应用专属目录：随应用卸载一起清理；统一展示为 /data/data 形式
        val appDir = java.io.File(context.filesDir, name).absolutePath
            .replaceFirst("/data/user/0/", "/data/data/")
        list.add("应用专属目录" to appDir)
        return list
    }

    /** 共享存储的通俗叫法（提示文案统一用词） */
    const val SHARED_STORAGE_HINT: String =
        "共享存储（放相册、下载的地方，如 /storage/emulated/0、/sdcard）"
}
