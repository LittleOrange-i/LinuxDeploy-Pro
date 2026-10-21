package io.github.LittleOrange.linuxdeploypro.data

import android.content.Context

/**
 * 保活偏好（SharedPreferences 持久化）。
 *
 * 对标老版 Linux Deploy 设置里的「保持 CPU 唤醒 / 锁定 WiFi」两项：
 * 容器（chroot）启动后用户息屏，Android 会挂起 CPU（Doze）并让 WiFi 休眠，
 * 容器内的 sshd 等服务随之"罢工"。这两项开关决定 [ContainerKeepAliveService]
 * 是否持有对应的锁来对抗系统休眠。
 *
 * 存储独立于 config/（那是容器部署配置，CLI 感知）；保活是纯前端 App 行为，
 * 放 SharedPreferences 即可。
 */
object KeepAlivePrefs {

    private const val FILE = "keep_alive"

    /** 息屏保活：容器运行期间持 PARTIAL_WAKE_LOCK + 前台服务，默认开启 */
    const val KEY_WAKE_LOCK = "wake_lock"

    /** 锁定 WiFi：容器运行期间持 WifiLock 防止息屏后 WiFi 休眠断网，默认开启 */
    const val KEY_WIFI_LOCK = "wifi_lock"

    private fun prefs(context: Context) =
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    fun wakeLockEnabled(context: Context): Boolean =
        prefs(context).getBoolean(KEY_WAKE_LOCK, true)

    fun wifiLockEnabled(context: Context): Boolean =
        prefs(context).getBoolean(KEY_WIFI_LOCK, true)

    fun setWakeLockEnabled(context: Context, value: Boolean) {
        prefs(context).edit().putBoolean(KEY_WAKE_LOCK, value).apply()
    }

    fun setWifiLockEnabled(context: Context, value: Boolean) {
        prefs(context).edit().putBoolean(KEY_WIFI_LOCK, value).apply()
    }

    /** 两项全关 = 不需要常驻保活服务 */
    fun anyEnabled(context: Context): Boolean =
        wakeLockEnabled(context) || wifiLockEnabled(context)
}
