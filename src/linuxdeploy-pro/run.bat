@echo off
chcp 65001 >nul
rem ============================================================
rem LinuxDeploy-Pro 快速构建安装脚本
rem 用法:
rem   run.bat            构建 + 覆盖安装 + 启动（保留容器配置，
rem                      CLI 在构建前自动从 src/linuxdeploy-cli 同步，
rem                      设备端按 assets 指纹自动重新解压）
rem   run.bat --clear    同上，但先完全清除应用数据后全新初始化
rem                      （会删除应用内容器配置；/data/local/tmp 下的
rem                      容器目录不受影响；用于彻底排除旧数据干扰）
rem ============================================================
setlocal
cd /d "%~dp0"

set PKG=io.github.ganyu256.linuxdeploypro

rem --- 环境自检：adb 必须可用 ---
where adb >nul 2>nul
if errorlevel 1 (
    echo [错误] 未找到 adb，请将 Android platform-tools 加入 PATH。
    pause
    exit /b 1
)
adb devices | findstr /r /c:"device$" >nul
if errorlevel 1 (
    echo [错误] 未检测到已授权的设备，请先连接设备并授权 USB 调试。
    pause
    exit /b 1
)

rem --- 可选：--clear 彻底清除应用旧数据（在安装前执行） ---
if /i "%~1"=="--clear" (
    echo [步骤] 清除应用旧数据 ^(%PKG%^) ...
    adb shell pm clear %PKG%
)

rem --- 构建 + 覆盖安装（installDebug 等价 adb install -r，覆盖安装保留应用数据） ---
rem 注意：gradlew 是批处理，必须用 call 调用，否则控制权不返回、后续步骤不执行。
echo [步骤] 构建 + 覆盖安装 Debug APK ...
call gradlew installDebug
if errorlevel 1 (
    echo [错误] 构建或安装失败，请检查上方日志。
    pause
    exit /b 1
)

rem --- 启动应用（EXTRACT_MARKER 变化时应用会自动重解压 CLI，覆盖旧脚本） ---
echo [步骤] 启动应用 ...
adb shell am start -n %PKG%/.MainActivity
if errorlevel 1 (
    echo [警告] 应用启动命令执行失败，可手动打开应用确认。
)

echo [完成] 部署成功。CLI 已在构建前自动同步到 assets，指纹变化时应用会自动重解压。
endlocal
