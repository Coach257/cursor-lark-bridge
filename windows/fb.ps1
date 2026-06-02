# cursor-lark-bridge —— Windows 控制脚本 (fb)
#
# 用法:
#   fb init     首次引导配置（open_id + 合并 hooks.json）
#   fb start    启动 daemon 并激活远程模式
#   fb stop     关闭远程模式（daemon 保持运行）
#   fb kill     停止 daemon 进程（整树）
#   fb restart  重启 daemon 并激活
#   fb status   查看状态
#   fb doctor   诊断常见问题

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = "help",
    [string]$OpenId = ""
)

$ErrorActionPreference = "Stop"

# ── 路径 ──
$CursorDir  = Join-Path $env:USERPROFILE ".cursor"
$BridgeDir  = Join-Path $CursorDir "cursor-lark-bridge"
$HooksDir   = Join-Path $CursorDir "hooks\cursor-lark-bridge"
$DaemonExe  = Join-Path $BridgeDir "daemon\cursor-lark-bridge-daemon.exe"
$PidFile    = Join-Path $BridgeDir "daemon.pid"
$ConfigFile = Join-Path $BridgeDir "config.json"
$LogsDir    = Join-Path $BridgeDir "logs"
$HooksJson  = Join-Path $CursorDir "hooks.json"
$Addr       = "http://127.0.0.1:19836"
$CLB_MARKER = "hooks\cursor-lark-bridge\"

# ── 工具函数 ──

function Write-Ok($m)   { Write-Host "  [OK] $m"   -ForegroundColor Green }
function Write-Warn($m) { Write-Host "  [!] $m"    -ForegroundColor Yellow }
function Write-Err($m)  { Write-Host "  [x] $m"    -ForegroundColor Red }
function Write-Step($m) { Write-Host "`n> $m"      -ForegroundColor Blue }

# 写 UTF-8 无 BOM —— Go 的 json 解析器不接受 BOM，务必无 BOM。
function Write-TextNoBom($path, $text) {
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, $text, $enc)
}

function Get-DaemonPid {
    if (-not (Test-Path $PidFile)) { return $null }
    try {
        $info = Get-Content $PidFile -Raw | ConvertFrom-Json
        if ($info.pid -gt 0) { return [int]$info.pid }
    } catch {
        $line = (Get-Content $PidFile -TotalCount 1).Trim()
        if ($line -match '^\d+$') { return [int]$line }
    }
    return $null
}

function Test-DaemonRunning {
    $dpid = Get-DaemonPid
    if (-not $dpid) { return $false }
    return [bool](Get-Process -Id $dpid -ErrorAction SilentlyContinue)
}

# 调用 daemon HTTP；失败返回 $null。
function Invoke-Daemon($method, $path, $bodyObj, $timeoutSec) {
    if (-not $timeoutSec) { $timeoutSec = 5 }
    try {
        $params = @{ Method = $method; Uri = "$Addr$path"; TimeoutSec = $timeoutSec }
        if ($bodyObj) {
            $params.ContentType = "application/json; charset=utf-8"
            $params.Body = ([System.Text.Encoding]::UTF8.GetBytes(($bodyObj | ConvertTo-Json -Depth 10 -Compress)))
        }
        return Invoke-RestMethod @params
    } catch {
        return $null
    }
}

# ── daemon 生命周期 ──

function Start-DaemonProc {
    if (Test-DaemonRunning) {
        Write-Warn "daemon 已在运行 (PID=$(Get-DaemonPid))"
        return $true
    }
    if (-not (Test-Path $DaemonExe)) {
        Write-Err "找不到 daemon 可执行文件：$DaemonExe"
        Write-Host "    请先运行安装脚本 install-windows.ps1"
        return $false
    }
    if (-not (Test-Path $ConfigFile)) {
        Write-Err "找不到 config.json，请先运行：fb init"
        return $false
    }
    New-Item -ItemType Directory -Force -Path $LogsDir | Out-Null
    $errLog = Join-Path $LogsDir "daemon-stderr.log"
    $outLog = Join-Path $LogsDir "daemon-stdout.log"
    Write-Step "启动 daemon..."
    Start-Process -FilePath $DaemonExe -WindowStyle Hidden `
        -RedirectStandardError $errLog -RedirectStandardOutput $outLog | Out-Null
    Start-Sleep -Seconds 1
    if (Test-DaemonRunning) {
        Write-Ok "daemon 已启动 (PID=$(Get-DaemonPid))"
        return $true
    }
    Write-Err "daemon 启动失败，最近日志："
    if (Test-Path $errLog) { Get-Content $errLog -Tail 8 | ForEach-Object { Write-Host "    $_" } }
    return $false
}

function Set-RemoteMode($active) {
    $r = Invoke-Daemon "Post" "/mode" @{ active = $active } 5
    return ($null -ne $r)
}

function Send-Notify($title, $content, $color, $context) {
    Invoke-Daemon "Post" "/notify" @{
        title = $title; content = $content; color = $color; context = $context
    } 10 | Out-Null
}

function Activate-Remote {
    if (Set-RemoteMode $true) {
        Write-Ok "远程模式已激活"
        $content = @"
**Cursor Agent 现在通过本单聊与你协作**

会推送的事件：
- Shell 命令审批
- MCP 工具调用授权
- Agent 提问 / 模式切换
- Agent 暂停时的下一步指令

如何回复：点击卡片按钮，或直接发文字消息（作为下一条指令）。
"@
        Send-Notify "🟢 远程交互桥已就绪" $content "green" "回到电脑后运行 fb stop 关闭"
    } else {
        Write-Err "激活失败，daemon 可能未运行"
    }
}

function Deactivate-Remote {
    if (Set-RemoteMode $false) {
        Write-Ok "远程模式已关闭"
        Send-Notify "🌙 远程交互桥已关闭" "远程接管已结束，后续交互回到 IDE 内完成。" "blue" "通道关闭"
    } else {
        Write-Warn "关闭失败，daemon 可能未运行"
    }
}

function Kill-Daemon {
    if (Test-DaemonRunning) {
        $dpid = Get-DaemonPid
        Write-Step "停止 daemon (PID=$dpid)..."
        & taskkill /F /T /PID $dpid 2>&1 | Out-Null
        Start-Sleep -Milliseconds 500
        Write-Ok "daemon 已停止"
    } else {
        Write-Warn "daemon 未在运行"
    }
    if (Test-Path $PidFile) { Remove-Item $PidFile -Force -ErrorAction SilentlyContinue }
}

function Show-Status {
    Write-Host "=== cursor-lark-bridge 状态 ===" -ForegroundColor Blue
    if (-not (Test-DaemonRunning)) {
        Write-Host "Daemon:    未运行" -ForegroundColor Red
        return
    }
    Write-Host "Daemon:    运行中 (PID=$(Get-DaemonPid))" -ForegroundColor Green
    $h = Invoke-Daemon "Get" "/health" $null 3
    if (-not $h) {
        Write-Host "HTTP API:  无法连接 (进程在但端口 19836 未响应)" -ForegroundColor Red
        return
    }
    Write-Host "Version:   $($h.version)"
    if ($h.active) { Write-Host "远程模式:  已激活" -ForegroundColor Green }
    else           { Write-Host "远程模式:  未激活" -ForegroundColor Yellow }
    if (-not $h.event_running) {
        Write-Host "事件订阅:  未运行 (lark-cli 子进程不存在)" -ForegroundColor Red
    } elseif (-not $h.subscribe_ok) {
        Write-Host "事件订阅:  不稳定 (累计重启 $($h.restart_count) 次)" -ForegroundColor Yellow
    } else {
        Write-Host "事件订阅:  健康" -ForegroundColor Green
    }
}

# ── init ──

function Resolve-OpenId($flag) {
    if ($flag) { return $flag }
    Write-Host "  尝试从 lark-cli 自动探测身份..."
    try {
        $profileJson = & lark-cli contact +get-user 2>$null | Out-String
        if ($profileJson.Trim()) {
            $p = $profileJson | ConvertFrom-Json
            $oid = $p.data.user.open_id
            $name = $p.data.user.name
            if ($oid) {
                Write-Host ""
                Write-Ok "已探测到飞书身份："
                if ($name) { Write-Host "      姓名     : $name" }
                Write-Host "      open_id  : $oid"
                $yn = Read-Host "? 使用这个 open_id 吗？[Y/n]"
                if ($yn -notmatch '^(n|N)') { return $oid }
            }
        }
    } catch { }
    Write-Host ""
    Write-Warn "无法自动探测（可能未运行 lark-cli auth login）。请手动粘贴："
    Write-Host "     lark-cli auth login           # 首次需 OAuth 登录"
    Write-Host "     lark-cli contact +get-user    # 输出里 data.user.open_id 即是"
    return (Read-Host "? 粘贴你的 open_id")
}

# 用 Node 安全地合并 hooks.json（保留用户已有条目，幂等替换我们自己的条目，无 BOM 输出）。
function Merge-HooksJson {
    $additions = Build-HookAdditions
    $tmpAdd = Join-Path $env:TEMP "clb-additions.json"
    Write-TextNoBom $tmpAdd ($additions | ConvertTo-Json -Depth 10)

    $mergerJs = Join-Path $BridgeDir "hooks-merge.js"
    if (-not (Test-Path $mergerJs)) {
        Write-Err "找不到 hooks-merge.js（安装不完整）"
        return
    }
    if (Test-Path $HooksJson) {
        $backup = "$HooksJson.bak.$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        Copy-Item $HooksJson $backup
        Write-Ok "已备份现有 hooks.json -> $backup"
    }
    & node $mergerJs $HooksJson $tmpAdd $CLB_MARKER
    if ($LASTEXITCODE -eq 0) { Write-Ok "hooks 已合并到 $HooksJson" }
    else { Write-Err "hooks 合并失败" }
    Remove-Item $tmpAdd -Force -ErrorAction SilentlyContinue
}

# 生成 Windows 版 hooks 追加片段（command 用 node + 绝对路径，引号包裹防空格）。
function Build-HookAdditions {
    # 选一个真正的 node.exe：优先非 Cursor 自带的，其次标准安装路径，最后裸 node。
    # 用全路径是因为 Cursor 执行 hook 时的 PATH 不可控（机器上常有多个 node.exe）。
    $node = (Get-Command node -ErrorAction SilentlyContinue | Where-Object { $_.Source -notlike '*cursor*' } | Select-Object -First 1).Source
    if (-not $node) { $node = "C:\Program Files\nodejs\node.exe" }
    if (-not (Test-Path $node)) { $node = "node" }
    function HookCmd($script) { return "`"$node`" `"$(Join-Path $HooksDir $script)`"" }
    # 按用户偏好：不注册 shell / MCP 审批 hook（命令直接执行，不走飞书逐条把关）。
    # 如需恢复审批，取消下面两行注释即可。
    # 注：preToolUse 对内置交互工具（AskQuestion / SwitchMode）实测不触发，故不再注册。
    # timeout 单位为秒，且 Cursor 内部用 32 位毫秒定时器（上限约 24.8 天）——
    # 切勿超过该上限，否则定时器溢出会导致 stop hook 一启动即被杀（卡片完全收不到）。
    # 1209600 秒 = 14 天，足够“等同永久”，且安全落在上限内。loop_limit=null 表示飞书多轮往返无上限。
    return [ordered]@{
        afterAgentResponse   = @(@{ command = (HookCmd "agent-response.js"); timeout = 5 })
        stop                 = @(@{ command = (HookCmd "on-stop.js"); timeout = 1209600; loop_limit = $null })
    }
}

function Invoke-Init {
    New-Item -ItemType Directory -Force -Path $BridgeDir | Out-Null
    Write-Host "欢迎使用 cursor-lark-bridge (Windows)"

    Write-Step "Step 1/3 · lark-cli 检查"
    $larkVer = & lark-cli --version 2>$null
    if (-not $larkVer) {
        Write-Err "未找到 lark-cli。请先安装并运行 lark-cli config init --new / auth login"
        return
    }
    Write-Ok "找到 lark-cli: $larkVer"

    Write-Step "Step 2/3 · 配置接收消息的 open_id"
    if ((Test-Path $ConfigFile) -and -not $OpenId) {
        $cur = (Get-Content $ConfigFile -Raw | ConvertFrom-Json).open_id
        Write-Warn "已存在 config.json（当前 open_id: $cur）。如需覆盖，重跑 fb init 并用 -OpenId 指定。"
    } else {
        $oid = Resolve-OpenId $OpenId
        if (-not $oid) { Write-Err "未提供 open_id，已中止"; return }
        if ($oid -notmatch '^ou_[a-f0-9]{32}$') { Write-Warn "'$oid' 不太像标准 ou_[32hex] 格式，仍按原值保存，请核对" }
        Write-TextNoBom $ConfigFile (@{ open_id = $oid } | ConvertTo-Json -Compress)
        Write-Ok "已保存到 $ConfigFile"
    }

    Write-Step "Step 3/3 · 合并 Cursor hooks.json"
    Merge-HooksJson

    Write-Host "`n配置完成。下一步：" -ForegroundColor Green
    Write-Host "   fb start    # 激活远程模式（会向飞书发送测试卡片）" -ForegroundColor Cyan
    Write-Host "   fb status   # 查看 daemon 状态" -ForegroundColor Cyan
}

function Invoke-Doctor {
    Write-Host "=== cursor-lark-bridge doctor ===" -ForegroundColor Blue
    # node
    if (Get-Command node -ErrorAction SilentlyContinue) { Write-Ok "node 可用: $(node --version)" } else { Write-Err "node 不在 PATH" }
    # lark-cli
    $lv = & lark-cli --version 2>$null
    if ($lv) { Write-Ok "lark-cli: $lv" } else { Write-Err "lark-cli 不在 PATH 或未安装" }
    # config
    if (Test-Path $ConfigFile) { Write-Ok "config.json 存在" } else { Write-Warn "config.json 缺失，运行 fb init" }
    # daemon exe
    if (Test-Path $DaemonExe) { Write-Ok "daemon.exe 存在" } else { Write-Err "daemon.exe 缺失" }
    # hooks
    if (Test-Path $HooksJson) {
        $cnt = (Select-String -Path $HooksJson -Pattern "cursor-lark-bridge" -ErrorAction SilentlyContinue | Measure-Object).Count
        if ($cnt -gt 0) { Write-Ok "hooks.json 已含 $cnt 条 bridge 注册" } else { Write-Warn "hooks.json 未含 bridge 条目，运行 fb init" }
    } else { Write-Warn "hooks.json 不存在，运行 fb init" }
    # running
    if (Test-DaemonRunning) { Write-Ok "daemon 运行中 (PID=$(Get-DaemonPid))" } else { Write-Warn "daemon 未运行" }
    # port
    $p = Get-NetTCPConnection -LocalPort 19836 -State Listen -ErrorAction SilentlyContinue
    if ($p) { Write-Ok "端口 19836 正在监听 (PID=$($p.OwningProcess))" } else { Write-Warn "端口 19836 无监听" }
}

# ── 主分发 ──

switch ($Command.ToLower()) {
    "init"    { Invoke-Init }
    "start"   { if (Start-DaemonProc) { Activate-Remote; Write-Host "`n现在可以离开电脑了，Cursor 交互将通过飞书完成。回来后运行: fb stop" -ForegroundColor Green } }
    "stop"    { Deactivate-Remote }
    "kill"    { Deactivate-Remote 2>$null; Kill-Daemon }
    "restart" { Deactivate-Remote 2>$null; Kill-Daemon; if (Start-DaemonProc) { Activate-Remote } }
    "status"  { Show-Status }
    "doctor"  { Invoke-Doctor }
    default {
        Write-Host "用法: fb {init|start|stop|kill|restart|status|doctor}"
        Write-Host ""
        Write-Host "  init     首次引导配置（open_id + 合并 hooks.json）"
        Write-Host "  start    启动 daemon 并激活远程模式"
        Write-Host "  stop     关闭远程模式（daemon 保持运行）"
        Write-Host "  kill     停止 daemon 进程"
        Write-Host "  restart  重启 daemon 并激活"
        Write-Host "  status   查看状态"
        Write-Host "  doctor   诊断常见问题"
    }
}
