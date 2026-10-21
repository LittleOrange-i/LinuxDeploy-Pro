package io.github.ganyu256.linuxdeploypro.ui

import android.widget.Toast
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.input.TextFieldLineLimits
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.foundation.text.input.rememberTextFieldState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.github.ganyu256.linuxdeploypro.data.StorageValidator
import io.github.ganyu256.linuxdeploypro.model.ContainerConfig
import top.yukonga.miuix.kmp.basic.Button
import top.yukonga.miuix.kmp.basic.Card
import top.yukonga.miuix.kmp.basic.CardDefaults
import top.yukonga.miuix.kmp.basic.HorizontalDivider
import top.yukonga.miuix.kmp.basic.Icon
import top.yukonga.miuix.kmp.basic.IconButton
import top.yukonga.miuix.kmp.basic.Scaffold
import top.yukonga.miuix.kmp.basic.Text
import top.yukonga.miuix.kmp.basic.TextField
import top.yukonga.miuix.kmp.basic.TopAppBar
import top.yukonga.miuix.kmp.preference.OverlayDropdownPreference
import top.yukonga.miuix.kmp.preference.SwitchPreference
import top.yukonga.miuix.kmp.theme.MiuixTheme

/**
 * 系统 → 可选发行版本（代号）映射（与 CLI bootstrap 组件实际可安装的分支对齐）。
 * 该字段对应 CLI 的 SUITE 键：前端 release → ConfigStore 写 SUITE → CLI 透传
 * 至 bootstrap 组件，全链路均为任意代号字符串，各端数据格式保持一致。
 *
 * 注意（2026-10 联网核对）：
 * - 列表首项为新建配置时的默认值，保持既有行为不变：
 *   Debian=trixie(13)、Ubuntu=noble(24.04)、Kali=kali-rolling、Alpine=edge；
 * - Slackware 的 aarch64 分支只有 slackwareaarch64-current（16.0 未正式发布，
 *   15.0/14.2 仅提供 x86/x86_64 与 32 位 ARM），因此这里只能提供 current；
 *   早期提供 15.0 会导致 <源>/slackwareaarch64-15.0 404、部署必失败；
 * - debian 增加的 forky 为 14（当前 testing），内置 debootstrap 1.0.144 自带
 *   脚本、镜像源正常同步；ubuntu 增加的 resolute 为 26.04 LTS；已 EOL 的
 *   临时版（oracular/plucky/questing 等）已从 ports 源移除，不在此列出；
 * - kali 增加的三个代号均来自官方仓库池：kali-rolling（滚动稳定）、
 *   kali-dev（每日构建）、kali-last-snapshot（月度快照）；CLI 端
 *   bootstrap/debian 的 apt_repository 已改为按 SUITE 写源，三者可直接切换；
 * - alpine 增加的 latest-stable 由 CLI 端 apk_branch() 解析为当前稳定分支；
 *   任意 v3.x 分支 CLI 均可安装（自动补 v 前缀），此处仅列常用于选择的项。
 */
private val DISTRO_RELEASES = mapOf(
    "debian" to listOf("trixie", "forky", "bookworm", "bullseye"),
    "ubuntu" to listOf("noble", "resolute", "jammy", "focal"),
    "kali" to listOf("kali-rolling", "kali-dev", "kali-last-snapshot"),
    "alpine" to listOf("edge", "latest-stable", "3.22", "3.21", "3.20"),
    "archlinux" to listOf("rolling"),
    "slackware" to listOf("current"),
    // 本地 rootfs 包：没有发行版本概念
    "rootfs" to emptyList(),
)

/** 系统显示名称（内部值保持英文，界面展示中文名） */
private val DISTRO_LABELS = mapOf(
    "debian" to "Debian",
    "ubuntu" to "Ubuntu",
    "kali" to "Kali Linux",
    "alpine" to "Alpine Linux",
    "archlinux" to "Arch Linux",
    "slackware" to "Slackware",
    "rootfs" to "本地 rootfs 包",
)

/**
 * 系统 → 默认软件源。
 *
 * 新建配置时按所选系统自动填入对应默认源；用户仍可手动修改，
 * 清空后回退发行版官方源（CLI 层处理）。
 * 注意：
 * - alpine / archlinux 用清华镜像（USTC 索引文件不可下）；
 * - slackware 用官方 ARM 镜像（http）：国内主流镜像（USTC/TUNA 等）只同步了 x86 分支，
 *   没有 slackwarearm 目录；aarch64 分支仅官方 ftp.arm.slackware.com 提供；
 * - ubuntu 用阿里云镜像（2026-10 实测：清华 TUNA 对非浏览器自动化访问返回 403
 *   拦截，debootstrap/wget 高频抓取易触发；阿里云 http/https 均正常开放，
 *   ubuntu-ports/dists/jammy/Release 校验通过：Codename jammy、含 arm64、
 *   main/universe/multiverse 组件齐全）。
 */
private val DISTRO_MIRRORS = mapOf(
    "debian" to "https://mirrors.ustc.edu.cn/debian/",
    "ubuntu" to "https://mirrors.aliyun.com/ubuntu-ports/",
    "kali" to "https://mirrors.ustc.edu.cn/kali/",
    "alpine" to "https://mirrors.tuna.tsinghua.edu.cn/alpine/",
    "archlinux" to "https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm/",
    "slackware" to "http://ftp.arm.slackware.com/slackwarearm/",
    "rootfs" to "",
)

/** 系统内部值的有序列表（保证选择器选项顺序稳定） */
private val DISTRO_KEYS = DISTRO_LABELS.keys.toList()

/** 取某个系统的默认发行版本（rootfs 返回空） */
private fun defaultRelease(distro: String): String =
    DISTRO_RELEASES[distro]?.firstOrNull() ?: ""

/** 取某个系统的默认软件源（rootfs 返回空串，表示使用官方源） */
private fun defaultMirror(distro: String): String =
    DISTRO_MIRRORS[distro] ?: ""

/**
 * 新建 / 编辑配置页（Miuix 列表式风格）。
 *
 * 文本类字段直接平铺在页面上：小字标题在上方，下方就是输入框；
 * 选项类字段用 OverlayDropdownPreference（HyperOS 下拉面板）；
 * 开关类字段用 SwitchPreference。系统与发行版本两级联动；
 * 默认密码始终可用（与 SSH 开关无关）；安卓挂载用“开关 + 列表 + 弹窗添加”；
 */
@Composable
fun ConfigScreen(
    initial: ContainerConfig?,
    defaultSshPort: String = "22",
    onBack: () -> Unit,
    onSave: (ContainerConfig) -> Unit,
) {
    val context = LocalContext.current
    val isEdit = initial != null

    // 文本输入框状态（Miuix TextField 基于 TextFieldState 管理文本，直接平铺编辑）
    val nameState = rememberTextFieldState(initial?.name ?: "")
    val imageSizeState = rememberTextFieldState(initial?.imageSize ?: "4G")
    val pathState = rememberTextFieldState(initial?.path ?: "")
    // 新建时按系统自动填入默认中科大镜像；编辑时保留用户已保存的值
    val mirrorState = rememberTextFieldState(
        initial?.mirror ?: defaultMirror(initial?.distro ?: "debian"),
    )
    val userState = rememberTextFieldState(initial?.user ?: "root")
    val userGroupsState = rememberTextFieldState(
        initial?.userGroups ?: "aid_inet aid_sdcard_rw aid_graphics",
    )
    // 新建时用调用方给出的"下一个空闲端口"（默认 22 之外的容器顺延，避免所有容器都抢 22）
    val sshPortState = rememberTextFieldState(initial?.sshPort ?: defaultSshPort)
    val passwordState = rememberTextFieldState(initial?.password ?: "changeme")

    // 基础信息
    var distro by rememberSaveable(initial?.distro) { mutableStateOf(initial?.distro ?: "debian") }
    var release by rememberSaveable(initial?.release, initial?.distro) {
        mutableStateOf(initial?.release ?: defaultRelease(initial?.distro ?: "debian"))
    }

    // 安装设置
    var installType by rememberSaveable(initial?.installType) { mutableStateOf(initial?.installType ?: "directory") }

    // 路径实时校验（输入即查）：路径提示与保存按钮共用同一结论
    val pathText = pathState.text.toString()
    val pathResult = StorageValidator.validate(pathText, installType)

    // SSH 设置（旧配置可能在 INCLUDE 里带 extra/ssh 但没有 sshEnabled，读入时一并同步）
    var sshEnabled by rememberSaveable(initial?.sshEnabled, initial?.components) {
        mutableStateOf(
            (initial?.sshEnabled == true) ||
                initial?.components.orEmpty().split(Regex("[ ,]+")).contains("extra/ssh"),
        )
    }

    // 初始化系统：sysv（默认，启动时执行 /etc/rcN.d 的 S 脚本）/ run-parts（自定义脚本目录）
    var initSystem by rememberSaveable(initial?.init) { mutableStateOf(initial?.init ?: "sysv") }
    val initLevelState = rememberTextFieldState(initial?.initLevel ?: "3")
    val initPathState = rememberTextFieldState(initial?.initPath ?: "/etc/rc.d")

    // 安卓文件挂载：开关 + 挂载行列表（每行“源:目标”两个输入框，行内编辑）
    val mountRows = remember {
        mutableStateListOf<MountRow>().apply {
            initial?.mounts.orEmpty().forEach { entry ->
                val sep = entry.indexOf(':')
                val src = if (sep > 0) entry.substring(0, sep) else entry
                val dst = if (sep > 0) entry.substring(sep + 1) else ""
                add(MountRow(src, dst))
            }
        }
    }
    var mountsEnabled by rememberSaveable(initial?.mountsEnabled, initial?.mounts?.isEmpty()) {
        // 旧配置没有 mountsEnabled 字段时，列表非空视为已启用
        mutableStateOf(initial?.mountsEnabled ?: initial?.mounts?.isNotEmpty() == true)
    }

    /** 切换系统：发行版与默认镜像联动 */
    fun selectDistro(newDistro: String) {
        distro = newDistro
        val releases = DISTRO_RELEASES[newDistro].orEmpty()
        release = if (releases.isEmpty()) "" else if (release in releases) release else releases.first()
        // 切换系统后自动更新镜像源为新系统的默认源
        mirrorState.edit { replace(0, length, defaultMirror(newDistro)) }
    }

    /**
     * 组装 INCLUDE：编辑时保留用户已有组件（desktop/x11 等前端无选择器、
     * 但可能通过 CLI 或手工配置过的组件不能保存即丢），仅同步 SSH 开关；
     * 新建时 core 必选 + SSH（启用时）。
     */
    fun buildComponents(): String {
        val base = if (isEdit) {
            initial?.components
                ?.split(Regex("[ ,]+"))
                ?.filter { it.isNotBlank() && it != "extra/ssh" }
                ?.toMutableList()
                ?: mutableListOf()
        } else {
            mutableListOf("core")
        }
        if (base.isEmpty()) base.add("core")
        if (sshEnabled && "extra/ssh" !in base) base.add("extra/ssh")
        // 初始化系统启用时保证 INCLUDE 含 init 组件（sysv/run-parts 均依赖它生效）
        if ("init" !in base) base.add("init")
        return base.joinToString(" ")
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = if (isEdit) "编辑配置" else "新建配置",
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
                .padding(horizontal = 16.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            // ===== 基础信息 =====
            GroupTitle("基础信息")
            Card(
                modifier = Modifier.fillMaxWidth(),
                colors = CardDefaults.defaultColors(
                    color = MiuixTheme.colorScheme.background,
                    contentColor = MiuixTheme.colorScheme.onSurface,
                ),
            ) {
                Column {
                    LabeledTextField(
                        label = "配置名称",
                        state = nameState,
                    )
                    HorizontalDivider()
                    OverlayDropdownPreference(
                        title = "系统",
                        summary = DISTRO_LABELS[distro] ?: distro,
                        items = DISTRO_LABELS.values.toList(),
                        selectedIndex = DISTRO_KEYS.indexOf(distro).coerceAtLeast(0),
                        onSelectedIndexChange = { selectDistro(DISTRO_KEYS[it]) },
                    )
                    HorizontalDivider()
                    OverlayDropdownPreference(
                        title = "发行版本",
                        summary = if (distro == "rootfs") "本地包无需版本" else release.ifBlank { "请选择" },
                        items = DISTRO_RELEASES[distro].orEmpty().ifEmpty { listOf("本地包无需版本") },
                        selectedIndex = if (distro == "rootfs") {
                            0
                        } else {
                            DISTRO_RELEASES[distro].orEmpty().indexOf(release).coerceAtLeast(0)
                        },
                        enabled = distro != "rootfs" && DISTRO_RELEASES[distro].orEmpty().isNotEmpty(),
                        onSelectedIndexChange = { release = DISTRO_RELEASES[distro].orEmpty()[it] },
                    )
                }
            }

            // ===== 安装设置 =====
            GroupTitle("安装设置")
            Card(
                modifier = Modifier.fillMaxWidth(),
                colors = CardDefaults.defaultColors(
                    color = MiuixTheme.colorScheme.background,
                    contentColor = MiuixTheme.colorScheme.onSurface,
                ),
            ) {
                Column {
                    OverlayDropdownPreference(
                        title = "安装方式",
                        summary = if (installType == "image") "镜像（ext4 镜像文件）" else "目录（直接部署到目录）",
                        items = listOf("目录（直接部署到目录）", "镜像（ext4 镜像文件）"),
                        selectedIndex = if (installType == "image") 1 else 0,
                        onSelectedIndexChange = { installType = if (it == 1) "image" else "directory" },
                    )
                    // 安装方式说明：把两种方式的区别翻译成大白话，帮用户选对
                    Text(
                        text = if (installType == "image") {
                            "把 Linux 装进一个镜像文件：文件放哪都行（包括手机共享存储），装不下时还能随时扩容。"
                        } else {
                            "把 Linux 装进一个普通文件夹：速度快、占用小。注意：文件夹不能放在共享存储" +
                                "（相册、下载所在的地方），否则会无法启动。"
                        },
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp),
                        fontSize = 12.sp,
                        color = MiuixTheme.colorScheme.onSurfaceContainerVariant.copy(alpha = 0.8f),
                    )
                    if (installType == "image") {
                        HorizontalDivider()
                        LabeledTextField(
                            label = "镜像大小",
                            state = imageSizeState,
                            hint = "给 Linux 预留的空间，装不下时可随时调大",
                        )
                    }
                    HorizontalDivider()
                    LabeledTextField(
                        label = "容器路径",
                        state = pathState,
                        hint = if (installType == "image") "镜像文件会自动保存在这个路径，文件名后面加 .img" else null,
                    )
                    // 路径实时校验：填错立即提示并给出修正入口，不等保存/部署才发现
                    if (pathResult.message != null) {
                        Text(
                            text = if (pathResult.ok) "✓ ${pathResult.message}" else pathResult.message,
                            modifier = Modifier.padding(horizontal = 16.dp),
                            fontSize = 12.sp,
                            color = if (pathResult.ok) Color(0xFF43A047) else Color(0xFFE53935),
                        )
                        // 共享存储 + 目录方式：提供一键修正（换推荐路径 / 改用镜像方式）
                        if (!pathResult.ok && pathResult.sharedStorage) {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(horizontal = 16.dp, vertical = 6.dp),
                                horizontalArrangement = Arrangement.spacedBy(10.dp),
                            ) {
                                Text(
                                    text = "一键换成推荐路径",
                                    modifier = Modifier
                                        .clip(RoundedCornerShape(8.dp))
                                        .clickable {
                                            val rec = StorageValidator
                                                .recommendations(context, nameState.text.toString())
                                                .firstOrNull()?.second ?: "/data/local/tmp/linux"
                                            pathState.edit { replace(0, length, rec) }
                                        }
                                        .padding(horizontal = 10.dp, vertical = 6.dp),
                                    fontSize = 13.sp,
                                    color = MiuixTheme.colorScheme.primary,
                                )
                                Text(
                                    text = "改用镜像安装",
                                    modifier = Modifier
                                        .clip(RoundedCornerShape(8.dp))
                                        .clickable { installType = "image" }
                                        .padding(horizontal = 10.dp, vertical = 6.dp),
                                    fontSize = 13.sp,
                                    color = MiuixTheme.colorScheme.primary,
                                )
                            }
                        }
                    }
                    // 推荐路径：点一下直接填入，免去手动抄写
                    val recommendations = StorageValidator.recommendations(
                        context,
                        nameState.text.toString(),
                    )
                    recommendations.forEach { (label, path) ->
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(12.dp))
                                .clickable {
                                    pathState.edit { replace(0, pathState.text.length, path) }
                                }
                                .padding(horizontal = 16.dp, vertical = 8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(
                                text = "用「$label」",
                                fontSize = 13.sp,
                                color = MiuixTheme.colorScheme.primary,
                            )
                            Spacer(modifier = Modifier.padding(horizontal = 6.dp))
                            Text(
                                text = path,
                                fontSize = 12.sp,
                                color = MiuixTheme.colorScheme.onSurfaceContainerVariant.copy(alpha = 0.7f),
                                maxLines = 1,
                            )
                        }
                    }
                }
            }

            // ===== 系统设置 =====
            GroupTitle("系统设置")
            Card(
                modifier = Modifier.fillMaxWidth(),
                colors = CardDefaults.defaultColors(
                    color = MiuixTheme.colorScheme.background,
                    contentColor = MiuixTheme.colorScheme.onSurface,
                ),
            ) {
                Column {
                    LabeledTextField(
                        label = "软件源地址",
                        state = mirrorState,
                    )
                    HorizontalDivider()
                    LabeledTextField(
                        label = "特权用户",
                        state = userState,
                    )
                    HorizontalDivider()
                    LabeledTextField(
                        label = "辅助组",
                        state = userGroupsState,
                    )
                    HorizontalDivider()
                    // 默认密码始终需要（无论是否启用 SSH），放在系统设置里
                    LabeledTextField(
                        label = "默认密码",
                        state = passwordState,
                    )
                    HorizontalDivider()
                    SwitchPreference(
                        checked = mountsEnabled,
                        onCheckedChange = { mountsEnabled = it },
                        title = "安卓文件挂载",
                        summary = "将安卓目录挂载进容器，关闭时忽略以下列表",
                    )
                    if (mountsEnabled) {
                        HorizontalDivider()
                        // “+ 添加挂载”：直接新增一行，行内填写源/目标路径
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(12.dp))
                                .clickable {
                                    mountRows.add(MountRow())
                                }
                                .padding(horizontal = 16.dp, vertical = 12.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(
                                text = "添加挂载",
                                modifier = Modifier.weight(1f),
                                fontSize = 14.sp,
                                color = MiuixTheme.colorScheme.primary,
                            )
                            Icon(
                                imageVector = Icons.Filled.Add,
                                contentDescription = "添加挂载",
                                tint = MiuixTheme.colorScheme.primary,
                            )
                        }
                        // 已添加的挂载行：源/目标两个输入框（左上角小标题）+ 右侧删除
                        mountRows.forEachIndexed { index, row ->
                            HorizontalDivider()
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(start = 16.dp, end = 8.dp, top = 10.dp, bottom = 10.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Column(modifier = Modifier.weight(1f)) {
                                    Row {
                                        MountFieldLabel("源路径（安卓）", Modifier.weight(1f))
                                        Spacer(modifier = Modifier.padding(horizontal = 4.dp))
                                        MountFieldLabel("目标路径（容器内）", Modifier.weight(1f))
                                    }
                                    Spacer(modifier = Modifier.padding(top = 6.dp))
                                    Row {
                                        TextField(
                                            state = row.source,
                                            modifier = Modifier.weight(1f),
                                            lineLimits = TextFieldLineLimits.SingleLine,
                                        )
                                        Spacer(modifier = Modifier.padding(horizontal = 4.dp))
                                        TextField(
                                            state = row.target,
                                            modifier = Modifier.weight(1f),
                                            lineLimits = TextFieldLineLimits.SingleLine,
                                        )
                                    }
                                }
                                IconButton(onClick = { mountRows.removeAt(index) }) {
                                    Icon(
                                        imageVector = Icons.Filled.Delete,
                                        contentDescription = "删除挂载",
                                        tint = Color(0xFFE53935),
                                    )
                                }
                            }
                        }
                    }
                }
            }

            // ===== SSH 设置 =====
            GroupTitle("SSH 服务")
            Card(
                modifier = Modifier.fillMaxWidth(),
                colors = CardDefaults.defaultColors(
                    color = MiuixTheme.colorScheme.background,
                    contentColor = MiuixTheme.colorScheme.onSurface,
                ),
            ) {
                Column {
                    SwitchPreference(
                        checked = sshEnabled,
                        onCheckedChange = { sshEnabled = it },
                        title = "启用 SSH",
                        summary = "部署时自动加入 extra/ssh 组件并配置 sshd",
                    )
                    HorizontalDivider()
                    LabeledTextField(
                        label = "SSH 端口",
                        state = sshPortState,
                        enabled = sshEnabled,
                        hint = "每个容器必须使用不同端口：端口相同会连到别的容器的 SSH",
                    )
                }
            }

            // ===== 初始化系统 =====
            GroupTitle("初始化系统")
            Card(
                modifier = Modifier.fillMaxWidth(),
                colors = CardDefaults.defaultColors(
                    color = MiuixTheme.colorScheme.background,
                    contentColor = MiuixTheme.colorScheme.onSurface,
                ),
            ) {
                Column {
                    // 初始化系统按发行版提供（与 CLI 组件的真实支持范围一致）：
                    // - systemctl（init 模式）依赖 python3 + systemd 风格 unit：
                    //   Debian 系（debian/ubuntu/kali）自带 python3，可直接选用；
                    // - Alpine 用 OpenRC（rc-update/rc-service）；
                    // - 其余（Arch/Slackware）只有 /etc/rc.d 脚本，用 run-parts；
                    // - SysV（/etc/rcN.d）仅 Debian 系存在，其他系统选了也拉不起服务
                    //   （曾表现为“容器显示运行中、SSH 连不上”），因此不再提供。
                    val systemctlCapable = distro in listOf("debian", "ubuntu", "kali")
                    val openrcCapable = distro == "alpine"
                    val sysvCapable = distro in listOf("debian", "ubuntu", "kali")
                    val initItems = mutableListOf<String>()
                    val initValues = mutableListOf<String>()
                    if (sysvCapable) {
                        initItems.add("SysV（/etc/rcN.d）")
                        initValues.add("sysv")
                    }
                    initItems.add("run-parts（/etc/rc.d）")
                    initValues.add("run-parts")
                    if (systemctlCapable) {
                        initItems.add("systemctl（init 模式）")
                        initValues.add("systemctl")
                    }
                    if (openrcCapable) {
                        initItems.add("OpenRC（openrc default）")
                        initValues.add("openrc")
                    }
                    // 发行版不支持所选初始化系统时回落：Debian 系 sysv，其余 run-parts
                    val fallbackInit = if (sysvCapable) "sysv" else "run-parts"
                    val displayInit = if (initSystem in initValues) initSystem else fallbackInit
                    // 宿主机上配置值与回落后不一致时同步回状态，避免保存出不可用组合
                    if (displayInit != initSystem) initSystem = displayInit
                    OverlayDropdownPreference(
                        title = "初始化系统",
                        summary = when (displayInit) {
                            "run-parts" -> "run-parts（/etc/rc.d 服务脚本）"
                            "systemctl" -> "systemctl（init 模式，拉起 default.target 服务）"
                            "openrc" -> "OpenRC（Alpine 默认，等价 rc-service --all）"
                            else -> "SysV（/etc/rcN.d，Debian 默认）"
                        },
                        items = initItems,
                        selectedIndex = initValues.indexOf(displayInit).coerceAtLeast(0),
                        onSelectedIndexChange = { initSystem = initValues[it] },
                    )
                    if (displayInit == "sysv") {
                        HorizontalDivider()
                        LabeledTextField(
                            label = "运行级别",
                            state = initLevelState,
                            hint = "默认 3：启动时按序执行 /etc/rc3.d/ 的 S 脚本，停止时执行 rc6.d 的 K 脚本",
                        )
                    } else if (displayInit == "run-parts") {
                        HorizontalDivider()
                        LabeledTextField(
                            label = "脚本目录（容器内路径）",
                            state = initPathState,
                            hint = "目录内脚本按顺序执行 start；停止时逆序执行 stop",
                        )
                    } else if (displayInit == "openrc") {
                        HorizontalDivider()
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 16.dp, vertical = 12.dp),
                        ) {
                            Text(
                                text = "OpenRC（Alpine 默认）",
                                fontSize = 13.sp,
                                color = MiuixTheme.colorScheme.onSurfaceContainerVariant,
                            )
                            Spacer(modifier = Modifier.padding(top = 6.dp))
                            Text(
                                text = "启动时按 /etc/runlevels 顺序启动已启用的服务，停止时逆序停止",
                                fontSize = 12.sp,
                                color = MiuixTheme.colorScheme.onSurfaceContainerVariant.copy(alpha = 0.8f),
                            )
                        }
                    } else {
                        HorizontalDivider()
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 16.dp, vertical = 12.dp),
                        ) {
                            Text(
                                text = "systemctl（init 模式）",
                                fontSize = 13.sp,
                                color = MiuixTheme.colorScheme.onSurfaceContainerVariant,
                            )
                            Spacer(modifier = Modifier.padding(top = 6.dp))
                            Text(
                                text = "需要 python3（部署时默认安装）；启动时拉起 systemctl --init，自动按序启动 init.d 与已启用（enable）的 systemd 服务",
                                fontSize = 12.sp,
                                color = MiuixTheme.colorScheme.onSurfaceContainerVariant.copy(alpha = 0.8f),
                            )
                        }
                    }
                }
            }

            // ===== 图形配置（占位，暂不实现） =====
            GroupTitle("图形配置")
            Card(
                modifier = Modifier.fillMaxWidth(),
                colors = CardDefaults.defaultColors(
                    color = MiuixTheme.colorScheme.background,
                    contentColor = MiuixTheme.colorScheme.onSurface,
                ),
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = "图形配置",
                            fontSize = 15.sp,
                            fontWeight = FontWeight.Medium,
                            color = MiuixTheme.colorScheme.onSurfaceContainerVariant.copy(alpha = 0.5f),
                        )
                        Text(
                            text = "VNC / X11 等图形界面参数（尚未接入）",
                            fontSize = 12.sp,
                            color = MiuixTheme.colorScheme.onSurfaceContainerVariant.copy(alpha = 0.5f),
                        )
                    }
                    Icon(
                        imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
                        contentDescription = null,
                        tint = MiuixTheme.colorScheme.onSurfaceContainerVariant.copy(alpha = 0.5f),
                    )
                }
            }

            Spacer(modifier = Modifier.padding(top = 4.dp))

            Button(
                enabled = pathResult.ok,
                onClick = {
                    val trimmed = nameState.text.toString().trim()
                    if (trimmed.isEmpty()) {
                        Toast.makeText(context, "配置名称不能为空", Toast.LENGTH_SHORT).show()
                        return@Button
                    }
                    // 双保险：即使按钮状态异常，保存前仍按校验结论拦截
                    val pathTrimmed = pathState.text.toString().trim()
                    if (!pathResult.ok) {
                        Toast.makeText(
                            context,
                            pathResult.message ?: "容器路径暂不可用，请按页面提示修改",
                            Toast.LENGTH_LONG,
                        ).show()
                        return@Button
                    }
                    if (pathTrimmed.isEmpty()) {
                        Toast.makeText(context, "请填写容器路径", Toast.LENGTH_LONG).show()
                        return@Button
                    }
                    // SSH 端口格式校验（1~65535）；"各容器端口不重复"由列表侧校验（见 MainScreen.saveConfig）
                    val sshPortNum = sshPortState.text.toString().trim().ifBlank { "22" }.toIntOrNull()
                    if (sshEnabled && (sshPortNum == null || sshPortNum !in 1..65535)) {
                        Toast.makeText(context, "SSH 端口必须是 1~65535 的数字", Toast.LENGTH_LONG).show()
                        return@Button
                    }
                    onSave(
                        ContainerConfig(
                            name = trimmed,
                            distro = distro,
                            release = release,
                            path = pathTrimmed,
                            installType = installType,
                            imageSize = imageSizeState.text.toString().trim().ifBlank { "4G" },
                            mirror = mirrorState.text.toString().trim(),
                            user = userState.text.toString().trim().ifBlank { "root" },
                            userGroups = userGroupsState.text.toString().trim()
                                .ifBlank { "aid_inet aid_sdcard_rw aid_graphics" },
                            mountsEnabled = mountsEnabled,
                            // 开关关闭时不传任何挂载；未填完整（源/目标任一为空）的行保存时跳过
                            mounts = if (mountsEnabled) {
                                mountRows.mapNotNull { it.toEntry() }
                            } else {
                                emptyList()
                            },
                            sshEnabled = sshEnabled,
                            sshPort = sshPortState.text.toString().trim().ifBlank { "22" },
                            // 密码与其他文本字段一致做 trim：输入法/粘贴容易带首尾空格，
                            // 保存后写入 USER_PASSWORD 会跟着带空格，表现为"输对了密码仍被拒"
                            password = passwordState.text.toString().trim().ifBlank { "changeme" },
                            components = buildComponents(),
                            init = initSystem,
                            initLevel = initLevelState.text.toString().trim().ifBlank { "3" },
                            initPath = initPathState.text.toString().trim().ifBlank { "/etc/rc.d" },
                            running = initial?.running ?: false,
                        )
                    )
                },
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text("保存配置")
            }
        }
    }
}

/** 一行挂载：源路径（安卓） + 目标路径（容器内），行内直接编辑 */
private class MountRow {
    val source = TextFieldState()
    val target = TextFieldState()

    constructor() : this("", "")

    constructor(sourceText: String, targetText: String) {
        if (sourceText.isNotEmpty()) source.edit { replace(0, length, sourceText) }
        if (targetText.isNotEmpty()) target.edit { replace(0, length, targetText) }
    }

    /** 转成 "源:目标" 配置项；源/目标任一为空返回 null（保存时跳过） */
    fun toEntry(): String? {
        val s = source.text.toString().trim()
        val t = target.text.toString().trim()
        return if (s.isEmpty() || t.isEmpty()) null else "$s:$t"
    }
}

/** 挂载行输入框上方的小字标题 */
@Composable
private fun MountFieldLabel(text: String, modifier: Modifier = Modifier) {
    Text(
        text = text,
        modifier = modifier,
        fontSize = 11.sp,
        color = MiuixTheme.colorScheme.onSurfaceContainerVariant,
    )
}

/**
 * 平铺文本字段：小字标题在输入框上方（左上角），下方直接是输入框。
 *
 * 与 Miuix 下拉行水平对齐（左右各 16dp），文本直接编辑，无需点击弹窗。
 */
@Composable
private fun LabeledTextField(
    label: String,
    state: TextFieldState,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    hint: String? = null,
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 12.dp),
    ) {
        Text(
            text = label,
            fontSize = 13.sp,
            color = if (enabled) {
                MiuixTheme.colorScheme.onSurfaceContainerVariant
            } else {
                MiuixTheme.colorScheme.onSurfaceContainerVariant.copy(alpha = 0.5f)
            },
        )
        Spacer(modifier = Modifier.padding(top = 8.dp))
        TextField(
            state = state,
            modifier = Modifier.fillMaxWidth(),
            enabled = enabled,
            lineLimits = TextFieldLineLimits.SingleLine,
        )
        if (!hint.isNullOrBlank()) {
            Spacer(modifier = Modifier.padding(top = 6.dp))
            Text(
                text = hint,
                fontSize = 12.sp,
                color = MiuixTheme.colorScheme.onSurfaceContainerVariant.copy(alpha = 0.8f),
            )
        }
    }
}
