package io.github.ganyu256.linuxdeploypro

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import io.github.ganyu256.linuxdeploypro.data.CliManager
import io.github.ganyu256.linuxdeploypro.data.ConfigStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** 开机自启：系统 BOOT_COMPLETED 后拉起 config/.autostart 中标记的容器 */
class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        // 用 applicationContext：onReceive 返回后 Context 即失效，
        // 而重试等待期间协程仍在运行
        val appContext = context.applicationContext
        CoroutineScope(Dispatchers.IO).launch {
            ConfigStore.autostartList(appContext).forEach { name ->
                var attempt = 0
                var started = false
                // 指数退避重试：开机瞬间 su 授权/存储挂载可能尚未就绪，
                // 原实现一次失败即放弃，容器进入"假死"（进程不存在、无任何记录）
                while (attempt < MAX_ATTEMPTS && !started) {
                    attempt++
                    try {
                        started = CliManager.start(appContext, name) { }
                        if (!started) {
                            Log.w(TAG, "自启启动失败（第 $attempt/$MAX_ATTEMPTS 次）：$name")
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "自启异常（第 $attempt/$MAX_ATTEMPTS 次）：$name", e)
                    }
                    if (!started && attempt < MAX_ATTEMPTS) {
                        delay(RETRY_BASE_MS * (1L shl (attempt - 1))) // 2s → 4s
                    }
                }
                if (started) {
                    Log.i(TAG, "自启成功：$name")
                } else {
                    Log.e(TAG, "自启最终失败（已重试 $MAX_ATTEMPTS 次）：$name")
                }
            }
        }
    }

    companion object {
        private const val TAG = "BootReceiver"
        /** 每个配置最多重试次数（含首次） */
        private const val MAX_ATTEMPTS = 3
        /** 重试基础间隔（毫秒），按 2s → 4s 递增 */
        private const val RETRY_BASE_MS = 2000L
    }
}
