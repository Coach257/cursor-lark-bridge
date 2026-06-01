# install-windows.ps1 —— 把 cursor-lark-bridge 部署到 ~/.cursor（Windows 版）
#
# 部署内容：
#   ~/.cursor/cursor-lark-bridge/daemon/cursor-lark-bridge-daemon.exe
#   ~/.cursor/cursor-lark-bridge/{fb.ps1, fb.cmd, hooks-merge.js}
#   ~/.cursor/hooks/cursor-lark-bridge/*.js
# 并把 bridge 目录加入用户 PATH（让 `fb` 全局可用）。
#
# 用法:  powershell -ExecutionPolicy Bypass -File install-windows.ps1
#        加 -BuildDaemon 会用本地 Go 重新编译 daemon（默认用已编译好的 exe）。

param(
    [switch]$BuildDaemon,
    [string]$GoRoot = "C:\programming\goroot\go"
)

$ErrorActionPreference = "Stop"
function Ok($m)   { Write-Host "  [OK] $m" -ForegroundColor Green }
function Info($m) { Write-Host "  [i] $m"  -ForegroundColor Cyan }
function Warn($m) { Write-Host "  [!] $m"  -ForegroundColor Yellow }

$Src        = $PSScriptRoot                      # ...\cursor-lark-bridge\windows
$Repo       = Split-Path $Src -Parent            # ...\cursor-lark-bridge
$DaemonSrc  = Join-Path $Repo "daemon"
$DaemonExeSrc = Join-Path $DaemonSrc "cursor-lark-bridge-daemon.exe"

$CursorDir  = Join-Path $env:USERPROFILE ".cursor"
$BridgeDir  = Join-Path $CursorDir "cursor-lark-bridge"
$DaemonDir  = Join-Path $BridgeDir "daemon"
$HooksDir   = Join-Path $CursorDir "hooks\cursor-lark-bridge"

Write-Host "cursor-lark-bridge · Windows 安装" -ForegroundColor Blue

# 1) 可选：从源码编译 daemon
if ($BuildDaemon -or -not (Test-Path $DaemonExeSrc)) {
    Write-Host "`n> 编译 daemon (Go)..." -ForegroundColor Blue
    $goExe = Join-Path $GoRoot "bin\go.exe"
    if (-not (Test-Path $goExe)) { $goExe = "go" }
    $env:GOROOT = $GoRoot
    Push-Location $DaemonSrc
    & $goExe build -o $DaemonExeSrc .
    $code = $LASTEXITCODE
    Pop-Location
    if ($code -ne 0) { throw "go build 失败 (exit $code)" }
    Ok "daemon 编译完成"
}

# 2) 建目录
New-Item -ItemType Directory -Force -Path $DaemonDir, $HooksDir, (Join-Path $BridgeDir "logs") | Out-Null

# 3) 拷贝文件
Copy-Item $DaemonExeSrc (Join-Path $DaemonDir "cursor-lark-bridge-daemon.exe") -Force
Ok "daemon.exe -> $DaemonDir"
Copy-Item (Join-Path $Src "fb.ps1")          (Join-Path $BridgeDir "fb.ps1") -Force
Copy-Item (Join-Path $Src "fb.cmd")          (Join-Path $BridgeDir "fb.cmd") -Force
Copy-Item (Join-Path $Src "hooks-merge.js")  (Join-Path $BridgeDir "hooks-merge.js") -Force
Ok "fb.ps1 / fb.cmd / hooks-merge.js -> $BridgeDir"
Copy-Item (Join-Path $Src "hooks\*.js") $HooksDir -Force
Ok "hook 脚本 -> $HooksDir"

# 4) 把 bridge 目录加入用户 PATH（幂等）
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if (($userPath -split ';') -notcontains $BridgeDir) {
    [Environment]::SetEnvironmentVariable("Path", "$userPath;$BridgeDir", "User")
    Ok "已把 $BridgeDir 加入用户 PATH"
    Warn "需新开一个终端，`fb` 命令才会生效"
} else {
    Info "PATH 已包含 bridge 目录"
}

Write-Host "`n安装完成。下一步：" -ForegroundColor Green
Write-Host "   1) 新开一个终端" -ForegroundColor Cyan
Write-Host "   2) fb init       # 配置 open_id + 合并 hooks.json" -ForegroundColor Cyan
Write-Host "   3) 飞书后台配卡片回调（避免按钮 200340）:" -ForegroundColor Cyan
Write-Host "      $Src\FEISHU-APP-SETUP.zh-CN.md" -ForegroundColor DarkGray
Write-Host "   4) fb start      # 激活远程模式" -ForegroundColor Cyan
