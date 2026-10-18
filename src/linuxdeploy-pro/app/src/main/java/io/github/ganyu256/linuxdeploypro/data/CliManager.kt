package io.github.ganyu256.linuxdeploypro.data

import android.content.Context
import io.github.ganyu256.linuxdeploypro.model.ContainerConfig
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope

/**
 * CLI 4.0 后端桥接层。
 *
 * 设计目标：前端只做可视化操作，真正干活的一律交给 cli.sh。
 * 所有命令都通过 su -c 以 root 身份执行（现代 KSU / Magisk 均可）：
 *  - 首次启动把 assets 里的 linuxdeploy-cli 解压到应用私有目录；
 *  - 执行命令时按 Shell 单引号规则转义每个参数，防止注入；
 *  - --json 模式用于读取配置列表 / 状态等结构化数据；
 *  - 启停 / 部署 / 导出等长任务按行流式回调，供日志页实时显示。
 */
object CliManager {

    /** assets 里的 CLI 目录名 */
    private const val ASSET_ROOT = "linuxdeploy-cli"

    /** 解压标记兜底值（仅在无法计算 assets 校验和时使用）。
     * 早期这里是手工维护的 4.1.19-rN 版本号，必须每次改 assets 手动 bump；
     * 曾因漏 bump 导致设备显示"已是最新"却仍在跑旧脚本（bootstrap 组件被跳过）。
     * 现在改为 [assetDigest]：运行时对 assets 内容算校验和，任何脚本改动都会
     * 自动触发重新解压，无需再手工提升版本。 */
    private const val EXTRACT_MARKER_FALLBACK = "unknown"

    /** CLI 版本（与 cli.sh 内 VERSION 对应，仅用于日志显示） */
    const val CLI_VERSION = "4.1.21"

    /**
     * 进程退出后等待输出读取线程收尾的默认时间（毫秒）。
     * CLI 派生的守护进程可能继承 stdout 管道，读取端等不到 EOF；
     * 主流程以进程退出为准，这里给一个窗口把已缓冲输出取完。
     * 默认 1500ms：500ms 对 debootstrap 等大量输出场景不足以搬完
     * 内核管道缓冲（64KB+），会造成日志截断。
     */
    private const val DRAIN_MS = 1500L

    /** 高输出操作（部署/导入导出）的收尾窗口：debootstrap 输出可达数 MB */
    private const val DRAIN_MS_LONG = 6000L

    /** 本次进程内是否已确认 root 可用（避免每次操作都反复探测） */
    @Volatile
    private var rootReady: Boolean? = null

    /** 当前正在执行的 CLI 进程（超时/卡死时 killCurrentProcess 使用） */
    @Volatile
    private var currentProcess: Process? = null

    /** 已解压的 CLI 目录（进程内缓存） */
    @Volatile
    private var cliDir: File? = null

    /** CLI 配置信息（config list --json 的解析结果） */
    data class CliConfig(
        val name: String,
        val distrib: String,
        val arch: String,
        val suite: String,
        val chrootDir: String,
        val targetType: String,
    )

    /** 单次执行结果：退出码 + 完整输出 */
    data class CliResult(
        val exitCode: Int,
        val output: String,
    )

    /** 容器 shell 会话：持久进程 + 是否走 PTY（容器内有 script 时启用） */
    data class ShellSession(
        val process: Process,
        val ptyMode: Boolean,
    )

    /** CLI 不可用（未解压 / 无 root / 执行失败）时抛出 */
    class CliException(message: String) : Exception(message)

    // ==================== 初始化 ====================

    /**
     * 确保 CLI 已解压到应用私有目录。
     * 目录结构：filesDir/linuxdeploy-cli/（内含 cli.sh、include 等）。
     * 返回 CLI 目录，解压失败返回 null（由调用方记录日志）。
     */
    fun ensureExtracted(context: Context): File? {
        cliDir?.takeIf { it.exists() }?.let { return it }
        val target = File(context.filesDir, ASSET_ROOT)
        return try {
            // 以 assets 内容校验和作为解压标记：安装包里的脚本一变，标记就变，
            // 覆盖安装后会自动重新解压，不依赖人工维护版本号。
            val marker = assetDigest(context) ?: EXTRACT_MARKER_FALLBACK
            if (!target.exists() || markerVersion(target) != marker) {
                // 逐文件合并覆盖，保留 config/、builds/、.current。
                extractAssets(context, target)
                File(target, ".version").writeText(marker)
            }
            cliDir = target
            target
        } catch (e: Exception) {
            cliDir = null
            null
        }
    }

    /**
     * 计算 assets/linuxdeploy-cli 的内容指纹（SHA-256，前 16 位十六进制）。
     *
     * 覆盖所有文件路径与内容，所以任何脚本/配置改动都会得到不同的指纹：
     * 新安装包首次启动即自动重新解压，不需要再手工 bump 版本常量。
     * 结果缓存在内存中，同一次运行只算一次。
     */
    @Volatile
    private var cachedDigest: String? = null

    @Synchronized
    private fun assetDigest(context: Context): String? {
        cachedDigest?.let { return it }
        return try {
            val md = java.security.MessageDigest.getInstance("SHA-256")
            fun feed(path: String) {
                val entries = context.assets.list(path) ?: return
                for (name in entries.sorted()) {
                    val childPath = "$path/$name"
                    if (context.assets.list(childPath)?.isNotEmpty() == true) {
                        feed(childPath)
                    } else {
                        md.update(childPath.toByteArray())
                        md.update(context.assets.open(childPath).use { it.readBytes() })
                    }
                }
            }
            feed(ASSET_ROOT)
            val digest = md.digest().joinToString("") { "%02x".format(it) }.take(16)
            cachedDigest = digest
            digest
        } catch (e: Exception) {
            android.util.Log.w("CliManager", "计算 assets 指纹失败", e)
            null
        }
    }

    /** 读取解压标记版本；目录不存在返回空串 */
    private fun markerVersion(dir: File): String =
        try {
            File(dir, ".version").readText().trim()
        } catch (_: Exception) {
            ""
        }

    /** 递归拷贝 assets/linuxdeploy-cli 到目标目录 */
    private fun extractAssets(context: Context, target: File) {
        target.mkdirs()
        // 以 assets 为准对齐文件集合：assets 里已不存在的脚本要删掉，
        // 否则重命名/移除组件后旧文件会残留在设备上继续被 CLI 引用。
        val stale = mutableListOf<File>()
        // 保留目录：CLI 运行时生成（配置、部署产物、临时文件），不属于 assets
        val keep = setOf("config", "builds", "tmp", ".version", ".current")
        fun copyDir(path: String, dest: File) {
            val entries = context.assets.list(path) ?: return
            dest.mkdirs()
            val names = entries.toSet()
            dest.listFiles()?.forEach { existing ->
                if (existing.name !in names && existing.name !in keep) {
                    stale.add(existing)
                }
            }
            entries.forEach { name ->
                val childPath = if (path.isEmpty()) name else "$path/$name"
                val childDest = File(dest, name)
                if (context.assets.list(childPath)?.isNotEmpty() == true) {
                    copyDir(childPath, childDest)
                } else {
                    context.assets.open(childPath).use { input ->
                        childDest.writeBytes(normalizeForPosix(input.readBytes()))
                    }
                }
            }
        }
        copyDir(ASSET_ROOT, target)
        stale.forEach { if (!it.deleteRecursively()) it.delete() }
        // assets 解压会丢失可执行位，这里统一补回：
        // 脚本、debootstrap、pkgdetails、tools 里的静态二进制都必须可执行，
        // 否则部署时会出现 "Permission denied"（退出码 126）。
        var successCount = 0
        var failCount = 0
        // 必须可执行的关键文件（缺失执行位会直接阻断部署）
        val criticalMissing = StringBuilder()
        target.walkTopDown().forEach { f ->
            if (f.isFile) {
                val critical = f.name.endsWith(".sh") ||
                    f.name == "debootstrap" ||
                    f.name == "pkgdetails" ||
                    f.parentFile?.name == "tools"
                try {
                    f.setExecutable(true, false)
                    f.setReadable(true, false)
                    successCount++
                } catch (e: IOException) {
                    failCount++
                    e.printStackTrace()
                    if (critical) criticalMissing.append(f.absolutePath).append('\n')
                }
            } else if (f.isDirectory) {
                try {
                    f.setExecutable(true, false)
                    successCount++
                } catch (e: IOException) {
                    failCount++
                    e.printStackTrace()
                }
            }
        }
        if (failCount > 0) {
            android.util.Log.w("CliManager", "权限设置完成:${successCount}成功，${failCount}失败")
        }
        // 关键文件权限设置失败时不静默放过：否则要到部署阶段才以
        // "Permission denied"（126）的形式暴露，用户无从排查
        if (criticalMissing.isNotEmpty()) {
            throw IOException("关键文件无法设置可执行权限:\n$criticalMissing")
        }
        // 保证基础目录存在（CLI 自己也会创建，这里兜底）
        File(target, "config").mkdirs()
        File(target, "tmp").mkdirs()
    }

    /**
     * POSIX 文本规范化：剥 UTF-8 BOM，CRLF / 孤立 CR 统一为 LF。
     *
     * 背景：Windows 构建机的 core.autocrlf 或编辑器可能把 CRLF、BOM 带进
     * assets。mksh 会把行尾 \r 当作命令名/词法符号的一部分，表现为
     * "inaccessible or not found"、"syntax error: unexpected 'in'"。
     * 含 NUL 字节的文件视为二进制（debootstrap、pkgdetails、tools 目录内文件），原样保留。
     */
    private fun normalizeForPosix(bytes: ByteArray): ByteArray {
        if (bytes.isEmpty() || bytes.contains(0.toByte())) return bytes
        var i = 0
        if (bytes.size >= 3 &&
            bytes[0] == 0xEF.toByte() && bytes[1] == 0xBB.toByte() && bytes[2] == 0xBF.toByte()
        ) {
            i = 3
        }
        val out = ByteArray(bytes.size - i)
        var j = 0
        while (i < bytes.size) {
            val b = bytes[i]
            if (b == '\r'.code.toByte()) {
                // CRLF 只留 \n；孤立 CR 同样归一为 \n
                if (i + 1 < bytes.size && bytes[i + 1] == '\n'.code.toByte()) i++
                out[j] = '\n'.code.toByte()
            } else {
                out[j] = b
            }
            i++
            j++
        }
        return if (j == out.size) out else out.copyOf(j)
    }

    /** 重新部署运行环境：强制重新解压 CLI（设置页“重装运行环境”用） */
    fun reinstall(context: Context): Boolean {
        cliDir = null
        rootReady = null
        // 清空版本标记后走 ensureExtracted 重新解压，保留 config/、builds/。
        try {
            File(File(context.filesDir, ASSET_ROOT), ".version").writeText("")
        } catch (_: Exception) {
            // 目录不存在时 ensureExtracted 会走首次解压
        }
        return ensureExtracted(context) != null
    }

    // ==================== root 探测 ====================

    /**
     * 检查 root 是否可用（su -c id 输出 uid=0 即视为可用）。
     * 结果在本次进程内缓存；失败不抛异常，返回 false。
     */
    fun isRootAvailable(): Boolean {
        rootReady?.let { return it }
        val ok = try {
            val process = ProcessBuilder("su", "-c", "id").redirectErrorStream(true).start()
            val output = process.inputStream.bufferedReader().use { it.readText() }
            process.waitFor()
            process.exitValue() == 0 && output.contains("uid=0")
        } catch (_: Exception) {
            false
        }
        // 只缓存成功结果；失败不缓存，下次调用重试
        if (ok) rootReady = true
        return ok
    }

    // ==================== 命令执行 ====================

    /** Shell 单引号转义：任何字符串都能安全地放进 sh -c 的参数位 */
    private fun shellQuote(s: String): String =
        "'" + s.replace("'", "'\\''") + "'"

    /**
     * 参数拼接规则：无空白/引号字符时原样输出，含空格等特殊字符才 shellQuote。
     */
    private fun quoteIfNeeded(s: String): String =
        if (s.isNotEmpty() && !s.any { it.isWhitespace() } &&
            !s.contains("'") && !s.contains("\"") && !s.contains("\\")
        ) {
            s
        } else {
            shellQuote(s)
        }

    /**
     * 以 root 身份执行 cli.sh。
     *
     * @param args      CLI 参数列表（如 ["--json", "config", "list"]）
     * @param onLine    输出行回调（默认忽略，用于日志实时回显）
     * @param input     写入进程标准输入的文本（如确认回答 "y\n"），写完后关闭
     * @param drainMs   进程退出后等待读取线程收尾的毫秒数（高输出操作传 [DRAIN_MS_LONG]）
     * @return          退出码 + 完整输出；执行失败抛 [CliException]
     */
    fun runCli(
        context: Context,
        args: List<String>,
        onLine: (String) -> Unit = {},
        input: String? = null,
        drainMs: Long = DRAIN_MS,
    ): CliResult {
        val dir = ensureExtracted(context)
            ?: throw CliException("CLI 未解压成功，请检查应用数据目录")
        val script = File(dir, "cli.sh")
        if (!script.exists()) {
            throw CliException("cli.sh 缺失：${script.absolutePath}")
        }
        if (!isRootAvailable()) {
            throw CliException("未获得 root 权限，请在 KSU / Magisk 中授权本应用")
        }
        val cmdTail = (listOf("sh", script.absolutePath) + args).joinToString(" ") { quoteIfNeeded(it) }
        return try {
            val process = ProcessBuilder("su", "-c", cmdTail).redirectErrorStream(true).start()
            // 记录当前进程，供超时/卡死时外部强制终止
            currentProcess = process
            if (input != null) {
                process.outputStream.write(input.toByteArray(Charsets.UTF_8))
                process.outputStream.flush()
                process.outputStream.close()
            }
            val output = StringBuilder()
            // 读取线程：CLI 派生的守护进程可能继承这条 stdout 管道，使读取端永远等不到 EOF
            // （旧实现在主流程里 useLines 读到 EOF 才返回，于是 start/stop 之类的操作永不结束，
            //  上层 busy 一直不释放，表现为“查询无响应、必须重启应用”）。
            // 现在改为异步读取，主流程以 waitFor() 的进程退出为准，退出后再给一个很短的
            // 收尾窗口把已缓冲输出取完，之后不再等待管道关闭。
            val reader = Thread {
                try {
                    process.inputStream.bufferedReader(Charsets.UTF_8).useLines { lines ->
                        lines.forEach { line ->
                            synchronized(output) { output.append(line).append('\n') }
                            onLine(line)
                        }
                    }
                } catch (_: Exception) {
                    // 进程退出导致管道关闭属正常路径
                }
            }
            reader.isDaemon = true
            reader.start()
            val exit = process.waitFor()
            reader.join(drainMs)
            CliResult(exitCode = exit, output = synchronized(output) { output.toString() })
        } catch (e: IOException) {
            throw CliException("执行 CLI 失败：${e.message}")
        } finally {
            currentProcess = null
        }
    }

    /**
     * 确保 config/ 目录归属 app（chown + chmod），使前端可直写。启动时调用一次。
     */
    fun ensureConfigWritable(context: Context) {
        val dir = ConfigStore.configDir(context)
        if (!dir.exists()) return
        try {
            // 用应用自身的 uid:gid（applicationInfo.uid，即 u0_aXXX），
            // 不依赖任何用户手动指定的用户组；config/ 完全归应用所有。
            val uid = context.applicationInfo.uid
            val cmd = "chown -R ${uid}:${uid} ${shellQuote(dir.absolutePath)} && " +
                "chmod 755 ${shellQuote(dir.absolutePath)} && " +
                "find ${shellQuote(dir.absolutePath)} -type f -exec chmod 644 {} \\;"
            ProcessBuilder("su", "-c", cmd)
                .redirectErrorStream(true)
                .start()
                .waitFor(10, java.util.concurrent.TimeUnit.SECONDS)
        } catch (_: Exception) {
        }
    }

    /**
     * 强制终止当前正在执行的 CLI 进程（超时/卡死保护）。
     * 杀 su 进程 → 连带杀掉 cli.sh 及其子进程。
     */
    fun killCurrentProcess() {
        currentProcess?.let { proc ->
            try {
                proc.destroy()
                // 未退出则强制杀（su→cli.sh 进程组）
                if (!proc.waitFor(3, java.util.concurrent.TimeUnit.SECONDS)) {
                    proc.destroyForcibly()
                }
            } catch (_: Exception) {
            }
        }
        currentProcess = null
    }

    /** 执行 CLI 并解析最后一段 JSON 对象（失败返回 null，不抛异常） */
    fun runCliJson(
        context: Context,
        args: List<String>,
        onLine: (String) -> Unit = {},
    ): JSONObject? {
        return try {
            val result = runCli(context, args, onLine)
            parseJson(result.output)
        } catch (_: Exception) {
            null
        }
    }

    /** 从混合输出中截取第一个 { 到最后一个 } 之间的 JSON 文本 */
    private fun parseJson(output: String): JSONObject? {
        val start = output.indexOf('{')
        val end = output.lastIndexOf('}')
        if (start < 0 || end <= start) {
            // 输出中没有 JSON 对象：记录尾部片段，便于诊断 CLI 输出异常
            android.util.Log.w("CliManager", "CLI 输出中未找到 JSON：${output.trim().takeLast(200)}")
            return null
        }
        return try {
            JSONObject(output.substring(start, end + 1))
        } catch (e: Exception) {
            // 解析失败记录原因与片段（原实现完全静默，CLI 输出异常时无从排查）
            android.util.Log.w("CliManager", "JSON 解析失败：${e.message}", e)
            null
        }
    }

    // ==================== 配置管理（前端直读 config/ 文件） ====================

    /** 读取配置列表（直读 config 目录下 .conf 文件，无需 CLI，毫秒级） */
    fun configListModels(context: Context): List<ContainerConfig> =
        ConfigStore.listConfigs(context)

    /** 读取单个配置完整详情（直读文件） */
    fun configToModel(context: Context, name: String): ContainerConfig? =
        ConfigStore.readConfig(context, name)

    /**
     * 写入配置（直写 config 目录下 .conf 文件，新建/编辑统一）。
     * 返回 CliResult 保持接口兼容（退出码 0 表示成功）。
     */
    fun writeConfig(
        context: Context,
        name: String,
        config: ContainerConfig,
        isNew: Boolean,
    ): CliResult {
        return try {
            if (!isNew && !ConfigStore.exists(context, name)) {
                CliResult(1, "配置不存在：$name")
            } else {
                ConfigStore.writeConfig(context, config.copy(name = name))
                CliResult(0, "已写入 ${name}.conf")
            }
        } catch (e: Exception) {
            CliResult(1, e.message ?: "写入配置失败")
        }
    }

    /** 删除容器目录（su rm -rf，前端确认流程后调用） */
    fun deleteContainerDir(context: Context, chrootDir: String): Boolean {
        if (chrootDir.isBlank()) return false
        return try {
            val proc = ProcessBuilder("su", "-c", "rm -rf ${shellQuote(chrootDir)}")
                .redirectErrorStream(true)
                .start()
            proc.waitFor() == 0
        } catch (_: Exception) {
            false
        }
    }

    /** 删除配置文件（保留容器目录数据） */
    fun deleteConfig(context: Context, name: String): CliResult {
        val ok = ConfigStore.deleteConfig(context, name)
        return if (ok) CliResult(0, "已删除配置：$name") else CliResult(1, "配置不存在：$name")
    }

    // ==================== 容器操作 ====================

    /** 启动容器（-c 显式指定配置，不触碰 .current 锁；start 自动挂载系统文件） */
    fun start(context: Context, name: String, onLine: (String) -> Unit = {}): Boolean =
        runCli(context, listOf("-c", name, "start"), onLine).exitCode == 0

    /** 停止容器（stop 自动卸载全部挂载） */
    fun stop(context: Context, name: String, onLine: (String) -> Unit = {}): Boolean =
        runCli(context, listOf("-c", name, "stop"), onLine).exitCode == 0

    /** 调整镜像大小（仅镜像安装有效） */
    fun resize(context: Context, name: String, size: String, onLine: (String) -> Unit = {}): Boolean =
        runCli(context, listOf("-c", name, "resize", size), onLine, drainMs = DRAIN_MS_LONG).exitCode == 0

    /** 部署容器（--yes 自动跳过确认，配合应用内确认流程） */
    fun deploy(context: Context, name: String, onLine: (String) -> Unit = {}): Boolean =
        runCli(context, listOf("-c", name, "deploy", "--yes"), onLine, drainMs = DRAIN_MS_LONG).exitCode == 0

    /**
     * 检查部署目标目录是否非空（已部署/存在残留数据）。
     * 通过 check --json 的"容器目录非空"警告判断，供前端部署前确认。
     */
    /**
     * 检查部署目标目录是否非空。
     * @return 第一项：true=目录非空；false=目录为空；null=检查失败或配置不存在
     * @return 第二项：失败时的 CLI 原始输出（诊断，供日志展示）
     */
    fun isTargetDirNonEmpty(context: Context, name: String): Pair<Boolean?, String> {
        return try {
            val result = runCli(context, listOf("-c", name, "--json", "check"))
            // 优先解析 JSON（与退出码无关），仅用"容器目录非空"判断是否需强制部署确认；
            // JSON 解析失败才视为配置读取失败。
            val json = parseJson(result.output)
            if (json == null) {
                return Pair(null, "check 输出无法解析（退出码 ${result.exitCode}）：${result.output.trim().takeLast(300)}")
            }
            val items = json.optJSONArray("items")
            if (items == null) return Pair(null, "check 输出缺少 items：${result.output.trim().takeLast(200)}")
            // 仅凭"容器目录非空"决定是否走强制部署确认；其他自检项不阻塞、不误报
            for (i in 0 until items.length()) {
                val detail = items.optJSONObject(i)?.optString("detail", "") ?: ""
                if (detail.contains("容器目录非空")) return Pair(true, "")
            }
            Pair(false, "")
        } catch (e: Exception) {
            Pair(null, "check 异常：${e.message}")
        }
    }

    /** 查询容器是否运行中（-c 指定配置 + status --json 的 running 字段） */
    fun isRunning(context: Context, name: String): Boolean {
        return getStatus(context, name)?.running == true
    }

    /**
     * 查询容器状态（-c 指定配置 + status --json）。
     * @return null 表示 CLI 执行/解析失败（调用方应保留原状态，不要当成"已停止"）
     */
    fun getStatus(context: Context, name: String): ContainerStatus? {
        val json = try {
            runCliJson(context, listOf("-c", name, "--json", "status"))
        } catch (e: Exception) {
            android.util.Log.w("CliManager", "status 查询失败: $name: ${e.message}")
            null
        } ?: return null
        return ContainerStatus(
            running = json.optBoolean("running", false),
            mounted = json.optBoolean("mounted", false),
            sshEnabled = json.optBoolean("ssh_enabled", false),
            sshRunning = json.optBoolean("ssh_running", false),
            ipv4 = json.optString("ipv4", ""),
        )
    }

    /** 查询宿主局域网 IPv4（CLI `ip` 命令，轻量，供列表页显示） */
    fun hostIpv4(context: Context): String {
        val json = try {
            runCliJson(context, listOf("--json", "ip"))
        } catch (_: Exception) {
            null
        }
        return json?.optString("ipv4", "").orEmpty()
    }

    /** 容器状态快照（status --json 的解析结果） */
    data class ContainerStatus(
        val running: Boolean,
        val mounted: Boolean,
        val sshEnabled: Boolean,
        val sshRunning: Boolean,
        val ipv4: String = "",
    )

    /** 导出 rootfs 归档（-c 指定配置） */
    fun exportRootfs(
        context: Context,
        name: String,
        outFile: File,
        onLine: (String) -> Unit = {},
    ): Boolean =
        runCli(context, listOf("-c", name, "export", outFile.absolutePath), onLine, drainMs = DRAIN_MS_LONG).exitCode == 0

    /**
     * 导入 rootfs 归档。
     * 归档须已复制到应用私有目录（SAF Uri 无法直接给 CLI 子进程读取）。
     */
    fun importRootfs(
        context: Context,
        name: String,
        archiveFile: File,
        onLine: (String) -> Unit = {},
    ): Boolean =
        runCli(context, listOf("-c", name, "import", archiveFile.absolutePath), onLine, drainMs = DRAIN_MS_LONG).exitCode == 0

    /** 导入归档的应用私有暂存目录 */
    fun defaultImportDir(context: Context): File =
        File(context.filesDir, "imports").apply { mkdirs() }

    /** 生成导出归档的默认路径（应用专属 Download 目录，无需存储权限） */
    fun defaultExportFile(context: Context, name: String): File {
        val dir = File(context.getExternalFilesDir(null) ?: context.filesDir, "exports")
        dir.mkdirs()
        val stamp = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.getDefault()).format(Date())
        return File(dir, "$name-$stamp.tar.gz")
    }

    /**
     * 打开容器 shell（持久进程）。
     *
     * 用 -c 显式指定配置。优先探测容器内是否有 script：
     * 有则用 script 分配 PTY（交互式、行缓冲、命令状态保留）；没有则退回
     * 纯管道 shell（无提示符，但 cd/变量等状态同样保留）。
     * 返回的 ShellSession 拥有独立 stdin/stdout，供内置终端读写；失败返回 null。
     */
    fun openShell(context: Context, name: String): ShellSession? {
        return try {
            val dir = ensureExtracted(context) ?: return null
            if (!isRootAvailable()) return null
            val script = File(dir, "cli.sh")
            // 探测容器内是否有 script（输出形如 /usr/bin/script）
            val hasScript = try {
                runCli(context, listOf("-c", name, "shell", "-c", "command -v script"))
                    .output
                    .contains("script")
            } catch (_: Exception) {
                false
            }
            // 脚本路径与配置名为无空格字符，不加引号。
            val cmdTail = if (hasScript) {
                // script -qfc：-q 静默、-f 逐条刷新输出、-c 执行命令
                "sh ${script.absolutePath} -c $name shell -c " +
                    shellQuote("script -qfc /bin/bash /dev/null")
            } else {
                "sh ${script.absolutePath} -c $name shell"
            }
            val proc = ProcessBuilder("su", "-c", cmdTail)
                .redirectErrorStream(true)
                .start()
            ShellSession(process = proc, ptyMode = hasScript)
        } catch (_: Exception) {
            null
        }
    }
}
