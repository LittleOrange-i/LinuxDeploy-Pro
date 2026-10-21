package io.github.LittleOrange.linuxdeploypro.data

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.content.ContextCompat

/**
 * 容器常驻保活前台服务（specialUse 类型）。
 *
 * 背景：容器（chroot）启动后用户息屏，Android 进入 Doze 并挂起 CPU、WiFi
 * 休眠断网，容器内 sshd / init 服务随之"罢工"。老版 Linux Deploy 用设置里的
 * 「保持 CPU 唤醒 / 锁定 WiFi」解决；本服务在容器运行期间常驻，按
 * [KeepAlivePrefs] 的开关持有对应锁：
 * 1. startForeground（specialUse）提升进程优先级，进程不被回收；
 * 2. PARTIAL_WAKE_LOCK 保持 CPU 唤醒（息屏后容器继续运行）；
 * 3. WifiLock（HIGH_PERF）阻止 WiFi 休眠（息屏后网络可用）。
 *
 * 为什么不复用 [KeepAliveService]（dataSync 类型）：Android 15 起 dataSync
 * 前台服务 24 小时内最多累计运行 6 小时（超时系统强制停止），且 BOOT_COMPLETED
 * 自启场景禁止拉起 dataSync 服务；specialUse 类型均不受限，适合
 * "容器运行多久就保活多久"的常驻场景。
 *
 * 生命周期由 [sync] 统一驱动：容器启停（MainScreen）、开机自启（BootReceiver）、
 * 设置变更（SettingsScreen）、应用启动补同步（MainScreen LaunchedEffect）后调用；
 * START_STICKY 保证服务被系统杀死后自动重启并重新持锁。
 *
 * 注意：息屏保活的可靠性还依赖电池优化白名单——深度休眠（Doze）下系统会
 * 忽略非白名单应用的 WakeLock，设置页提供一键申请入口。
 */
class ContainerKeepAliveService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // API 34+ 显式声明 specialUse 类型（startForegroundService 约束：5 秒内前台化）；
        // API 34 以下 specialUse 类型不存在，走无类型前台化（manifest 里的未知类型被忽略）
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        applyLocks()
        // 被系统杀死后自动重启（intent 为 null）并重新按设置持锁
        return START_STICKY
    }

    override fun onDestroy() {
        releaseLocks()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /** 按 KeepAlivePrefs 当前值持有/释放锁；两项全关时自行停止 */
    private fun applyLocks() {
        // WakeLock：息屏保活。不设超时——服务前台化且由 sync 驱动停止；
        // 进程被杀时内核会回收该进程持有的全部 WakeLock，不会泄漏
        if (KeepAlivePrefs.wakeLockEnabled(this)) {
            if (wakeLock?.isHeld != true) {
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKELOCK_TAG).apply {
                    setReferenceCounted(false)
                    acquire()
                }
            }
        } else {
            wakeLock?.let { if (it.isHeld) it.release() }
            wakeLock = null
        }
        // WifiLock（HIGH_PERF）：保持 WiFi 高性能连接，阻止息屏后进入省电休眠
        if (KeepAlivePrefs.wifiLockEnabled(this)) {
            if (wifiLock?.isHeld != true) {
                @Suppress("DEPRECATION")
                val mode = WifiManager.WIFI_MODE_FULL_HIGH_PERF
                val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                wifiLock = wm.createWifiLock(mode, WIFILOCK_TAG).apply {
                    setReferenceCounted(false)
                    acquire()
                }
            }
        } else {
            wifiLock?.let { if (it.isHeld) it.release() }
            wifiLock = null
        }
        // 设置里两项全关：保活无从谈起，撤下通知并停止服务
        if (!KeepAlivePrefs.anyEnabled(this)) {
            stopSelf()
        }
    }

    private fun releaseLocks() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        wifiLock?.let { if (it.isHeld) it.release() }
        wifiLock = null
    }

    private fun ensureChannel() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "容器保活",
                NotificationManager.IMPORTANCE_LOW,
            ).apply { description = "容器运行期间的息屏保活通知" },
        )
    }

    private fun buildNotification(): Notification =
        Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("LinuxDeploy 容器运行中")
            .setContentText("息屏保活已开启，容器服务保持可用")
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .build()

    companion object {
        private const val CHANNEL_ID = "container_keepalive"
        private const val NOTIFICATION_ID = 4002
        private const val WAKELOCK_TAG = "linuxdeploy:container_keepalive"
        private const val WIFILOCK_TAG = "linuxdeploy:wifi_keepalive"

        /**
         * 同步保活服务状态（所有联动入口统一走这里）。
         * @param containersRunning 是否有容器处于运行状态
         * 有容器在跑且至少开启一项保活 → 启动/刷新服务（重复调用即应用最新设置）；
         * 否则停止服务。失败静默降级：部分 ROM 限制后台启动前台服务时容器仍可运行，
         * 只是息屏后可能被挂起。
         */
        fun sync(context: Context, containersRunning: Boolean) {
            val need = containersRunning && KeepAlivePrefs.anyEnabled(context)
            try {
                if (need) {
                    ContextCompat.startForegroundService(
                        context,
                        Intent(context, ContainerKeepAliveService::class.java),
                    )
                } else {
                    context.stopService(Intent(context, ContainerKeepAliveService::class.java))
                }
            } catch (_: Exception) {
                // 降级：不阻塞容器启停主流程
            }
        }
    }
}
