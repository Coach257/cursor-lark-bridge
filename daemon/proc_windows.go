//go:build windows

package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
)

// ── lark-cli 调用（Windows）──
//
// Windows 上 `lark-cli` 是一个 .cmd 批处理 shim：
//   - Go 的 exec/CreateProcess 不能直接执行 .cmd；
//   - 走 `cmd /c lark-cli ...` 又会让 cmd.exe 重新解析参数，破坏卡片 JSON 里的大量引号。
//
// 因此优先解析出 lark-cli 背后的 node 入口脚本（scripts/run.js），直接用
// `node run.js ...` 调用：node.exe 是真正的可执行文件，Go 的参数转义规则与
// node(CommandLineToArgvW) 解析一致，JSON 引号能原样传入。
// 解析失败时回退到 `cmd /c lark-cli`（无引号参数的命令仍可用）。

var (
	larkScriptOnce sync.Once
	larkScriptPath string
)

// resolveLarkScript 通过 `npm root -g` 定位全局安装的 @larksuite/cli 入口脚本。
// 用 cmd /c 调用 npm 仅为读取一行路径输出，不涉及复杂参数转义，安全。
func resolveLarkScript() string {
	larkScriptOnce.Do(func() {
		out, err := exec.Command("cmd", "/c", "npm root -g").Output()
		if err != nil {
			return
		}
		root := strings.TrimSpace(string(out))
		if root == "" {
			return
		}
		p := filepath.Join(root, "@larksuite", "cli", "scripts", "run.js")
		if _, err := os.Stat(p); err == nil {
			larkScriptPath = p
		}
	})
	return larkScriptPath
}

func larkCLICmd(args ...string) *exec.Cmd {
	if s := resolveLarkScript(); s != "" {
		return exec.Command("node", append([]string{s}, args...)...)
	}
	return exec.Command("cmd", append([]string{"/c", "lark-cli"}, args...)...)
}

func larkCLICmdCtx(ctx context.Context, args ...string) *exec.Cmd {
	if s := resolveLarkScript(); s != "" {
		return exec.CommandContext(ctx, "node", append([]string{s}, args...)...)
	}
	return exec.CommandContext(ctx, "cmd", append([]string{"/c", "lark-cli"}, args...)...)
}

// ── 进程树 / 信号（Windows）──

// setProcGroup 在 Windows 上是 no-op：没有 Setpgid 概念，子进程作为当前进程的
// 子节点留在同一进程树里，退出时统一用 `taskkill /T` 整树终止。
func setProcGroup(cmd *exec.Cmd) {}

// processAlive 用 tasklist 过滤指定 PID 判断进程是否存活。
// 仅在 daemon 启动抢 PID 锁时调用一次，开销可接受。
func processAlive(pid int) bool {
	out, err := exec.Command("tasklist", "/FI", fmt.Sprintf("PID eq %d", pid), "/NH", "/FO", "CSV").Output()
	if err != nil {
		return false
	}
	// 命中时输出形如  "image.exe","1234",...；未命中时是一行中文/英文提示
	return strings.Contains(string(out), "\""+strconv.Itoa(pid)+"\"")
}

// cleanupStaleLarkCLIEvent 用 PowerShell 按命令行匹配并结束遗留的
// lark-cli event +subscribe 进程（Windows 没有 pkill）。
func cleanupStaleLarkCLIEvent(reason string) {
	ps := `Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine -match 'event \+subscribe' -and ($_.CommandLine -match 'lark-cli' -or $_.CommandLine -match '@larksuite') } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }`
	if err := exec.Command("powershell", "-NoProfile", "-NonInteractive", "-Command", ps).Run(); err == nil {
		logInfo("[cleanup:%s] 已尝试清理残留的 lark-cli event 进程", reason)
	}
}

// terminateProcessTree 用 taskkill /T 终止整棵进程树（含 node 及其孙子进程），/F 强制。
func terminateProcessTree(proc *os.Process) {
	pid := proc.Pid
	_ = exec.Command("taskkill", "/F", "/T", "/PID", strconv.Itoa(pid)).Run()
}

// shutdownSignals：Windows 只有 os.Interrupt（Ctrl+C / CTRL_BREAK），没有 SIGTERM。
// daemon 通常由 `fb kill`（taskkill /T）强制结束，此处主要服务于前台运行场景。
func shutdownSignals() []os.Signal {
	return []os.Signal{os.Interrupt}
}
