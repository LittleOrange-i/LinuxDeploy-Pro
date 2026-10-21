# ============================================================
# LinuxDeploy-Pro 快速构建安装脚本（由 run.bat 调用，也可直接运行）
# 用法:
#   run.bat              构建 + 覆盖安装 + 启动（保留容器配置，
#                        CLI 在构建前自动从 src/linuxdeploy-cli 同步，
#                        设备端按 assets 指纹自动重新解压）
#   run.bat --clear      同上，但先完全清除应用数据后全新初始化
#                        （会删除应用内容器配置；/data/local/tmp 下的
#                        容器目录不受影响；用于彻底排除旧数据干扰）
# ============================================================
# 注意：本文件必须保存为 UTF-8 with BOM 编码，否则 Windows
#       PowerShell 5.1 会按 ANSI 读取导致中文乱码。

$pkg = 'io.github.LittleOrange.linuxdeploypro'
Set-Location -LiteralPath $PSScriptRoot

function Fail($msg) {
    Write-Host "[错误] $msg" -ForegroundColor Red
    Read-Host '按回车键退出'
    exit 1
}

# --- 环境自检：adb 必须可用 ---
if (-not (Get-Command adb -ErrorAction SilentlyContinue)) {
    Fail '未找到 adb，请将 Android platform-tools 加入 PATH。'
}

# --- 环境自检：必须存在已授权设备 ---
$devices = (adb devices | Out-String) -split "`r?`n" | Where-Object { $_ -match "`tdevice\s*$" }
if (-not $devices) {
    Fail '未检测到已授权的设备，请先连接设备并授权 USB 调试。'
}

# --- 可选：--clear 彻底清除应用旧数据（在安装前执行） ---
if ($args -contains '--clear') {
    Write-Host "[步骤] 清除应用旧数据 ($pkg) ..."
    adb shell pm clear $pkg
}

# --- 构建 + 覆盖安装（installDebug 等价 adb install -r，覆盖安装保留应用数据） ---
Write-Host '[步骤] 构建 + 覆盖安装 Debug APK ...'
& .\gradlew.bat installDebug
if ($LASTEXITCODE -ne 0) {
    Fail '构建或安装失败，请检查上方日志。'
}

# --- 启动应用（EXTRACT_MARKER 变化时应用会自动重解压 CLI，覆盖旧脚本） ---
Write-Host '[步骤] 启动应用 ...'
adb shell am start -n "$pkg/.MainActivity"
if ($LASTEXITCODE -ne 0) {
    Write-Host '[警告] 应用启动命令执行失败，可手动打开应用确认。' -ForegroundColor Yellow
}

Write-Host '[完成] 部署成功。CLI 已在构建前自动同步到 assets，指纹变化时应用会自动重解压。' -ForegroundColor Green
