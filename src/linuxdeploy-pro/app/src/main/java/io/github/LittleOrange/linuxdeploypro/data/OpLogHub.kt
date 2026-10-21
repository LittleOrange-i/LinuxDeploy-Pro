package io.github.LittleOrange.linuxdeploypro.data

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import io.github.LittleOrange.linuxdeploypro.BuildConfig
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * 进程级日志与长任务状态中心（单例）。
 *
 * 为什么需要：此前日志状态（会话日志 / 文件尾随缓冲 / 当前日志文件）都挂在
 * Composable 的 remember 状态上：
 * - 日志页的文件尾随协程挂在 LogScreen 组合里，切换 tab 即被取消、缓冲清零；
 *   回到日志页要从文件头按 64KB/500ms 逐段重读——部署日志可达数 MB，
 *   恢复需数十秒，期间窗口停留在文件开头、最新进度迟迟不出现（表现为"日志丢失"）；
 * - MainScreen 因主题切换 / Activity 重建而销毁时，logFile 等未持久化状态直接丢失。
 *
 * 现在日志与长任务运行态全部上移到本单例：
 * - 尾随协程常驻（进程存活期间不中断），切页 / 重建只是观察者重建，内容瞬时恢复；
 * - 长任务协程（部署等）跑在 [opScope]，Activity 重建不再中断部署与日志回流。
 *
 * 进程被杀则一切归零（此时部署协程必然也已终止，属不可恢复场景，
 * 由 KeepAliveService 前台服务尽量避免）。
 */
object OpLogHub {

    /** 会话日志（短消息 + CLI 实时回显，旧在上新在下，500 行上限） */
    val logs = mutableStateListOf<String>()

    /** 从日志文件尾随读出的完整行（旧在上、新在下），日志页直接展示 */
    val fileLines = mutableStateListOf<String>()

    /** 当前尾随的 CLI 日志文件（每次操作一个独立时间戳文件；null 时日志页显示会话日志） */
    var logFile: File? by mutableStateOf(null)

    /** 长任务互斥：同一时间只允许一个 CLI 长任务（启停/部署/导出/删除/保存） */
    var busy: Boolean by mutableStateOf(false)

    /** busy 起始时间（异常挂起超过时限强制解除的兜底依据） */
    var busySince: Long by mutableStateOf(0L)

    /** 进行中的长任务文案（顶部进度横幅）；null = 空闲 */
    var opLabel: String? by mutableStateOf(null)

    /** 正在部署的配置名（容器页"部署中"徽标）；null = 无 */
    var deployingName: String? by mutableStateOf(null)

    /**
     * 进程级协程域：长任务与文件尾随都跑在这里，不随任何 Composable 销毁而取消。
     * Main.immediate：日志追加/状态更新天然在主线程，UI 状态读写线程安全。
     */
    val opScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    /** 尾随协程句柄（懒启动，进程内唯一） */
    private var tailJob: Job? = null

    /** 尾随读偏移（字节）；清空显示时保留，保证新日志继续增量出现 */
    private var tailOffset = 0L

    /** 末尾不完整行的字节残留（跨轮拼接，避免中文日志断行乱码） */
    private val tailPending = ByteArrayOutputStream()

    init {
        logs.add("v${BuildConfig.VERSION_NAME} 启动，CLI 后端已接入")
    }

    /** 追加一条会话日志（带时间戳，主线程调用；500 行上限，超出丢弃最旧） */
    fun append(msg: String) {
        val time = java.text.SimpleDateFormat("HH:mm:ss", java.util.Locale.getDefault())
            .format(java.util.Date())
        logs.add("$time  $msg")
        if (logs.size > 500) logs.removeAt(0)
    }

    /**
     * 设置当前尾随的日志文件（写 logFile 请一律走本函数）。
     * 路径变化（新操作）时重置尾随状态，从新文件头重读；
     * 同一路径重复设置不动作，避免清屏闪烁。
     * （直接赋值 logFile 会跳过重置，导致新旧操作日志混显。）
     */
    fun attachLogFile(file: File?) {
        if (file == null) {
            logFile = null
            return
        }
        if (logFile?.absolutePath == file.absolutePath) return
        tailOffset = 0L
        tailPending.reset()
        fileLines.clear()
        logFile = file
        ensureTail()
    }

    /** 清空显示（会话日志 + 文件尾随窗口）；尾随偏移保留，后续新日志继续增量出现 */
    fun clearDisplay() {
        logs.clear()
        fileLines.clear()
    }

    /** 确保尾随协程在跑（懒启动，进程内唯一） */
    private fun ensureTail() {
        if (tailJob?.isActive == true) return
        tailJob = opScope.launch { tailLoop() }
    }

    /**
     * 文件尾随主循环：500ms 轮询增量读取。
     * 常驻不随页面销毁——这正是修复"切页丢日志"的关键。
     */
    private suspend fun tailLoop() {
        while (coroutineContext.isActive) {
            val f = logFile
            if (f != null) {
                try {
                    if (f.exists()) {
                        val len = f.length()
                        if (len < tailOffset) {
                            // 文件被替换/截断：整体重读
                            tailOffset = 0L
                            tailPending.reset()
                            fileLines.clear()
                        }
                        if (len > tailOffset) {
                            val chunk = ByteArray((len - tailOffset).toInt().coerceAtMost(64 * 1024))
                            val read = RandomAccessFile(f, "r").use { raf ->
                                raf.seek(tailOffset)
                                raf.read(chunk)
                            }
                            if (read > 0) {
                                tailOffset += read
                                fileLines.addAll(decodeUtf8Lines(tailPending, chunk.copyOf(read)))
                            }
                        }
                    }
                } catch (_: Exception) {
                    // 文件写入过程中短暂不可读（如刚创建/被占用），下一轮重试
                }
            }
            delay(500)
        }
    }

    /**
     * 增量解码 UTF-8 字节流为完整行列表。
     *
     * 轮询读取可能把一行拆到两次读取中间，末尾的不完整多字节序列需要
     * 保留到下一轮继续拼接（否则中文日志会出现乱码/断行）。
     *
     * @param pending 上一轮残留的不完整字节
     * @param chunk   本轮新读到的字节
     * @return 本轮可展示的完整行（以换行符结尾的部分）
     */
    private fun decodeUtf8Lines(pending: ByteArrayOutputStream, chunk: ByteArray): List<String> {
        pending.write(chunk)
        val bytes = pending.toByteArray()
        // 末尾最多可能是 3 字节的不完整 UTF-8 序列；从 0 到 3 逐字节试探截断，
        // 找到能完整解码的最大前缀，剩下的字节留在 pending 里下一轮拼接。
        for (cut in 0..3) {
            if (cut > bytes.size) break
            try {
                val decoder = Charsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                val text = decoder.decode(ByteBuffer.wrap(bytes, 0, bytes.size - cut)).toString()
                pending.reset()
                if (cut > 0) pending.write(bytes, bytes.size - cut, cut)
                val lines = text.split("\n")
                if (lines.isNotEmpty() && lines.last().isEmpty()) {
                    // 末尾是换行符：没有未完成行
                    return lines.dropLast(1)
                }
                // 最后一段是不完整行，放回 pending 下一轮拼接
                pending.reset()
                pending.write(lines.last().toByteArray(Charsets.UTF_8))
                return lines.dropLast(1)
            } catch (_: CharacterCodingException) {
                // 截断后仍无法解码，继续增加截断长度
            }
        }
        // 全部无法解码（异常字节流）：丢弃，避免 pending 无限增长
        pending.reset()
        return emptyList()
    }
}
