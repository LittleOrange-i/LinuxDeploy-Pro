package io.github.LittleOrange.linuxdeploypro.ui

import io.github.LittleOrange.linuxdeploypro.BuildConfig
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.widget.Toast
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import io.github.LittleOrange.linuxdeploypro.data.CliManager
import io.github.LittleOrange.linuxdeploypro.data.KeepAlivePrefs
import io.github.LittleOrange.linuxdeploypro.ui.theme.ThemeMode
import top.yukonga.miuix.kmp.basic.Card
import top.yukonga.miuix.kmp.basic.CardDefaults
import top.yukonga.miuix.kmp.basic.Icon
import top.yukonga.miuix.kmp.basic.IconButton
import top.yukonga.miuix.kmp.basic.Scaffold
import top.yukonga.miuix.kmp.basic.SmallTopAppBar
import top.yukonga.miuix.kmp.basic.Text
import top.yukonga.miuix.kmp.preference.ArrowPreference
import top.yukonga.miuix.kmp.preference.OverlayDropdownPreference
import top.yukonga.miuix.kmp.preference.SwitchPreference
import top.yukonga.miuix.kmp.theme.MiuixTheme

/**
 * 设置页：主题 + 保活 + 运行环境 + 关于。
 * 顶栏用 SmallTopAppBar 与容器/日志页一致；行样式统一 Miuix（关于区
 * 用 ArrowPreference / 信息行）；重装运行环境前弹确认窗。
 * 保活分组对标老版 Linux Deploy 的「保持 CPU 唤醒 / 锁定 WiFi」，
 * 开关即时生效（通过 onKeepAliveChanged 回调同步常驻保活服务）。
 */
@Composable
fun SettingsScreen(
    themeMode: ThemeMode,
    onThemeModeChange: (ThemeMode) -> Unit,
    containersRunning: Boolean,
    onKeepAliveChanged: () -> Unit,
    onBack: () -> Unit,
) {
    val context = LocalContext.current
    // 重装运行环境确认窗
    var showReinstallConfirm by remember { mutableStateOf(false) }
    // 保活开关状态（本地镜像，写入 KeepAlivePrefs 后同步刷新）
    var wakeLockOn by remember { mutableStateOf(KeepAlivePrefs.wakeLockEnabled(context)) }
    var wifiLockOn by remember { mutableStateOf(KeepAlivePrefs.wifiLockEnabled(context)) }
    // 电池优化白名单状态：从系统设置返回（ON_RESUME）后重新读取
    var batteryWhitelisted by remember { mutableStateOf(isBatteryWhitelisted(context)) }
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                batteryWhitelisted = isBatteryWhitelisted(context)
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    Scaffold(
        topBar = {
            SmallTopAppBar(
                title = "设置",
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = "返回",
                        )
                    }
                },
            )
        },
        containerColor = MiuixTheme.colorScheme.background,
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 4.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            GroupTitle("显示")
            // 主题
            Card(
                modifier = Modifier.fillMaxWidth(),
                colors = CardDefaults.defaultColors(
                    color = MiuixTheme.colorScheme.background,
                    contentColor = MiuixTheme.colorScheme.onSurface,
                ),
            ) {
                OverlayDropdownPreference(
                    title = "主题",
                    summary = themeMode.label,
                    items = ThemeMode.entries.map { it.label },
                    selectedIndex = themeMode.ordinal,
                    onSelectedIndexChange = { onThemeModeChange(ThemeMode.entries[it]) },
                )
            }

            GroupTitle("保活")
            // 息屏保活（对标老版 Linux Deploy「保持 CPU 唤醒 / 锁定 WiFi」）：
            // 容器运行期间持有前台服务 + WakeLock/WifiLock，息屏后容器不掉线。
            // 开关即时生效：写 KeepAlivePrefs 后经 onKeepAliveChanged 同步服务。
            Card(
                modifier = Modifier.fillMaxWidth(),
                colors = CardDefaults.defaultColors(
                    color = MiuixTheme.colorScheme.background,
                    contentColor = MiuixTheme.colorScheme.onSurface,
                ),
            ) {
                Column {
                    SwitchPreference(
                        title = "保持唤醒（息屏保活）",
                        summary = "容器运行期间保持 CPU 唤醒，息屏后 SSH 等服务不中断",
                        checked = wakeLockOn,
                        onCheckedChange = {
                            KeepAlivePrefs.setWakeLockEnabled(context, it)
                            wakeLockOn = it
                            onKeepAliveChanged()
                        },
                    )
                    SwitchPreference(
                        title = "锁定 WiFi",
                        summary = "容器运行期间阻止 WiFi 休眠，息屏后网络不断",
                        checked = wifiLockOn,
                        onCheckedChange = {
                            KeepAlivePrefs.setWifiLockEnabled(context, it)
                            wifiLockOn = it
                            onKeepAliveChanged()
                        },
                    )
                    ArrowPreference(
                        title = "电池优化白名单",
                        summary = if (batteryWhitelisted) {
                            "已忽略电池优化，深度休眠下保活最可靠"
                        } else {
                            "强烈建议开启：深度休眠（Doze）会忽略 WakeLock，导致息屏断连"
                        },
                        onClick = { requestIgnoreBatteryOptimization(context) },
                    )
                }
            }
            // 生效状态与国产 ROM 提示（小字说明，不占独立卡片）
            Text(
                text = if (containersRunning) {
                    "当前有容器运行中，保活设置立即生效"
                } else {
                    "当前无运行中的容器，保活将在容器启动后自动生效"
                },
                fontSize = 12.sp,
                color = MiuixTheme.colorScheme.onSurfaceContainerVariant,
                modifier = Modifier.padding(horizontal = 16.dp),
            )
            Text(
                text = "提示：部分国产 ROM（MIUI / EMUI / ColorOS 等）还会额外清理后台，" +
                    "请在系统设置中允许本应用「自启动」与「后台运行」。",
                fontSize = 12.sp,
                color = MiuixTheme.colorScheme.onSurfaceContainerVariant,
                modifier = Modifier.padding(horizontal = 16.dp),
            )

            GroupTitle("运行环境")
            // 重装运行环境（确认后执行）
            Card(
                modifier = Modifier.fillMaxWidth(),
                colors = CardDefaults.defaultColors(
                    color = MiuixTheme.colorScheme.background,
                    contentColor = MiuixTheme.colorScheme.onSurface,
                ),
            ) {
                ArrowPreference(
                    title = "重装运行环境",
                    summary = "重新部署内置 cli.sh / busybox / resize2fs 并更新环境变量",
                    onClick = { showReinstallConfirm = true },
                )
            }

            GroupTitle("关于")
            // 关于：作者/开源地址可点击（右箭头）置顶；版本/包名/许可信息行置底
            Card(
                modifier = Modifier.fillMaxWidth(),
                colors = CardDefaults.defaultColors(
                    color = MiuixTheme.colorScheme.background,
                    contentColor = MiuixTheme.colorScheme.onSurface,
                ),
            ) {
                Column {
                    ArrowPreference(
                        title = "作者",
                        summary = "LittleOrange-i",
                        onClick = { openUrl(context, "https://github.com/LittleOrange-i") },
                    )
                    ArrowPreference(
                        title = "开源地址",
                        summary = "github.com/LittleOrange-i/LinuxDeploy-Pro",
                        onClick = { openUrl(context, "https://github.com/LittleOrange-i/LinuxDeploy-Pro") },
                    )
                    AboutInfoLine("版本", "v${BuildConfig.VERSION_NAME}")
                    AboutInfoLine("包名", "io.github.LittleOrange.linuxdeploypro")
                    AboutInfoLine("许可", "GPL-3.0")
                }
            }
        }
    }

    // 重装运行环境确认窗
    if (showReinstallConfirm) {
        ConfirmDialog(
            title = "重装运行环境",
            content = "将重新部署内置的 cli.sh / busybox / resize2fs 等文件，\n并更新环境变量。会覆盖这些程序文件，但保留你的配置与容器数据。",
            confirmText = "重新部署",
            onConfirm = {
                showReinstallConfirm = false
                Thread {
                    val ok = CliManager.reinstall(context)
                    val msg = if (ok) {
                        "运行环境已重新部署"
                    } else {
                        "运行环境重新部署失败，请检查应用数据目录"
                    }
                    Handler(Looper.getMainLooper()).post {
                        Toast.makeText(context, msg, Toast.LENGTH_SHORT).show()
                    }
                }.start()
            },
            onDismiss = { showReinstallConfirm = false },
        )
    }
}

/** 打开外部链接（失败时 Toast 提示） */
private fun openUrl(context: android.content.Context, url: String) {
    try {
        context.startActivity(
            Intent(Intent.ACTION_VIEW, Uri.parse(url)),
        )
    } catch (_: Exception) {
        Toast.makeText(context, "无法打开链接", Toast.LENGTH_SHORT).show()
    }
}

/** 应用是否已在电池优化白名单（忽略电池优化）中 */
private fun isBatteryWhitelisted(context: Context): Boolean =
    (context.getSystemService(Context.POWER_SERVICE) as PowerManager)
        .isIgnoringBatteryOptimizations(context.packageName)

/**
 * 申请电池优化白名单：息屏保活可靠性的关键一步。
 * 深度休眠（Doze）下系统忽略非白名单应用的 PARTIAL_WAKE_LOCK 并掐断网络，
 * 仅前台服务 + WakeLock 不足以对抗；加入白名单后锁才真正生效。
 */
private fun requestIgnoreBatteryOptimization(context: Context) {
    val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
    if (pm.isIgnoringBatteryOptimizations(context.packageName)) {
        Toast.makeText(context, "已在电池优化白名单中", Toast.LENGTH_SHORT).show()
        return
    }
    try {
        // 直接弹系统确认框（需 REQUEST_IGNORE_BATTERY_OPTIMIZATIONS 权限；
        // 本应用经 GitHub 分发、面向 root 设备，无 Play 商店政策限制）
        context.startActivity(
            Intent(
                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                Uri.parse("package:${context.packageName}"),
            ),
        )
    } catch (_: Exception) {
        // 个别 ROM 裁剪了确认框页面：退回电池优化列表页（无需权限）让用户手动设置
        try {
            context.startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
        } catch (_: Exception) {
            Toast.makeText(context, "无法打开电池优化设置，请手动前往系统设置", Toast.LENGTH_LONG).show()
        }
    }
}

/** 关于信息行（Miuix 风格）：标签左、值右对齐，无箭头 */
@Composable
private fun AboutInfoLine(
    label: String,
    value: String,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = label,
            fontSize = 17.sp,
            fontWeight = FontWeight.Medium,
            color = MiuixTheme.colorScheme.onSurface,
        )
        Spacer(modifier = Modifier.width(12.dp))
        Text(
            text = value,
            modifier = Modifier.weight(1f),
            fontSize = 14.sp,
            textAlign = androidx.compose.ui.text.style.TextAlign.End,
            color = MiuixTheme.colorScheme.onSurfaceContainerVariant,
        )
    }
}
