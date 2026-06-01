//go:build !windows

package main

import (
	"context"
	"os"
	"os/exec"
	"syscall"
	"time"
)

// ── lark-cli 调用 ──
//
// Unix 上 lark-cli 是带 shebang 的可执行脚本，直接按名字调用即可（依赖 PATH）。

func larkCLICmd(args ...string) *exec.Cmd {
	return exec.Command("lark-cli", args...)
}

func larkCLICmdCtx(ctx context.Context, args ...string) *exec.Cmd {
	return exec.CommandContext(ctx, "lark-cli", args...)
}

// ── 进程组 / 信号 ──

// setProcGroup 让子进程进入独立 process group，daemon 退出时可对整组发信号。
func setProcGroup(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
}

// processAlive 用 signal 0 探测进程是否存活（不真正发送信号）。
func processAlive(pid int) bool {
	proc, err := os.FindProcess(pid)
	if err != nil {
		return false
	}
	return proc.Signal(syscall.Signal(0)) == nil
}

// cleanupStaleLarkCLIEvent 尽力清理可能遗留的 lark-cli event +subscribe 进程。
// reason 仅用于日志区分是启动清理还是冲突清理。
func cleanupStaleLarkCLIEvent(reason string) {
	patterns := []string{
		"lark-cli.*event .subscribe",
		"@larksuite/cli.*event .subscribe",
	}
	cleaned := false
	for _, p := range patterns {
		// -9 保证即使子进程在 uninterruptible sleep / sigterm 被忽略时也能被清
		if err := exec.Command("pkill", "-9", "-f", p).Run(); err == nil {
			cleaned = true
		}
	}
	if cleaned {
		logInfo("[cleanup:%s] 已清理残留的 lark-cli event 进程", reason)
	}
}

// terminateProcessTree 对子进程组发 SIGTERM，3s 仍未退出则升级到 SIGKILL。
func terminateProcessTree(proc *os.Process) {
	pid := proc.Pid
	// 负 PID 向整个 process group 发信号；Setpgid 时 pgid == pid
	_ = syscall.Kill(-pid, syscall.SIGTERM)
	// 冗余一次向直接子进程发 SIGTERM，兼容 Setpgid 失败的场景
	_ = syscall.Kill(pid, syscall.SIGTERM)

	done := make(chan struct{})
	go func() {
		for {
			if err := proc.Signal(syscall.Signal(0)); err != nil {
				close(done)
				return
			}
			time.Sleep(100 * time.Millisecond)
		}
	}()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		_ = syscall.Kill(-pid, syscall.SIGKILL)
		_ = syscall.Kill(pid, syscall.SIGKILL)
	}
}

// shutdownSignals 返回需要监听的优雅退出信号。
func shutdownSignals() []os.Signal {
	return []os.Signal{syscall.SIGINT, syscall.SIGTERM}
}
