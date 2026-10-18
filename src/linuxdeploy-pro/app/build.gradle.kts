plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    // 新包名：与原版 ru.meefik.linuxdeploy 彻底区分
    namespace = "io.github.ganyu256.linuxdeploypro"
    // compileSdk 37：仅编译基线。Miuix 0.9.3 / core-ktx 1.19.0 已按 37 编译，
    // 若不跟进会触发 AAR 元数据校验失败。targetSdk 仍保持 36（Android 16 行为）。
    compileSdk = 37

    defaultConfig {
        applicationId = "io.github.ganyu256.linuxdeploypro"
        // minSdk 28：Android 9，兼顾老设备；私有二进制执行限制也以 28 为基线
        minSdk = 28
        // targetSdk 36：Android 16，启用新一代系统行为与特性
        targetSdk = 36
        versionCode = 40120
        versionName = "4.1.20"
    }

    signingConfigs {
        // 本地 release 签名（keystore/ 不入库；口令仅本地开发用，发布请改用注入）
        create("release") {
            storeFile = rootProject.file("keystore/linuxdeploy-pro.jks")
            storePassword = "linuxdeploy2026"
            keyAlias = "linuxdeploy"
            keyPassword = "linuxdeploy2026"
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            signingConfig = signingConfigs.getByName("release")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    lint {
        // 离线环境无 lint-gradle 依赖缓存，release 构建跳过 lintVital（lint 可单独执行）
        checkReleaseBuilds = false
        abortOnError = false
    }

    buildFeatures {
        compose = true
        // BuildConfig.VERSION_NAME/VERSION_CODE 供 UI 统一显示版本号
        buildConfig = true
    }
}

/**
 * 构建前自动同步 CLI 到 APK assets。
 *
 * src/linuxdeploy-cli 是权威版本：每次 assemble/install 前都会把它覆盖进
 * app/src/main/assets/linuxdeploy-cli，杜绝"改了源码却忘记复制 assets、设备
 * 仍在跑旧脚本"的问题（曾导致 bootstrap 组件被静默跳过、部署秒失败）。
 * 设备端 CliManager 按 assets 内容指纹判断是否重新解压，无需手工改版本号。
 */
val cliRepoDir = rootProject.file("../linuxdeploy-cli")
val assetsCliDir = file("src/main/assets/linuxdeploy-cli")

// 运行时目录与开发机脚本不随 APK 分发
val cliSyncExcludes = listOf("config", "tmp", "builds", ".git", "scripts/regression.sh")

val syncCli = tasks.register<Sync>("syncCli") {
    description = "把 src/linuxdeploy-cli 同步到 app assets/linuxdeploy-cli"
    group = "build"
    doFirst {
        require(cliRepoDir.isDirectory) { "CLI 源目录不存在: $cliRepoDir" }
        logger.lifecycle("[sync-cli] ${cliRepoDir} -> ${assetsCliDir}")
    }
    from(cliRepoDir) {
        cliSyncExcludes.forEach { exclude(it) }
    }
    into(assetsCliDir)
}

// assets 必须在 mergeAssets 之前就位
tasks.matching { it.name == "preBuild" }.configureEach { dependsOn(syncCli) }

dependencies {
    // Compose BOM：统一管理 androidx.compose 各组件版本
    implementation(platform("androidx.compose:compose-bom:2026.06.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.foundation:foundation")
    // 基础图标集（Home / Settings / Add 等）
    implementation("androidx.compose.material:material-icons-core:1.7.8")

    implementation("androidx.core:core-ktx:1.19.0")
    implementation("androidx.activity:activity-compose:1.13.0")

    // Miuix：HyperOS 风格 UI 组件库（0.9.3）
    implementation("top.yukonga.miuix.kmp:miuix-ui:0.9.3")
    // Miuix preference：官方设置行组件（Arrow / Switch / OverlayDropdown），与 SukiSU 同款
    implementation("top.yukonga.miuix.kmp:miuix-preference-android:0.9.3")

    debugImplementation("androidx.compose.ui:ui-tooling")
}
