// beforeShellExecution hook：拦截 shell 命令，经飞书远程审批。
const L = require("./clb-lib");

// 不需要审批的安全命令（含 bridge 自身的调用，避免自我拦截死锁）。
function isSafeCommand(cmd) {
  const c = String(cmd || "").trim();
  if (!c) return true;
  if (/(127\.0\.0\.1|localhost):19836/.test(c)) return true; // 桥自己的 HTTP 调用
  if (/(^|[\\/\s])lark-cli(\.cmd)?(\s|$)/i.test(c)) return true;
  if (/(^|[\\/\s])fb(\.cmd|\.ps1)?(\s|$)/i.test(c)) return true;
  if (/cursor-lark-bridge/.test(c)) return true;
  // 只读 / 无害命令
  if (/^(cat|tail|head|ls|dir|echo|which|where|type|pwd|cd|whoami|Get-Content|Get-ChildItem)\b/i.test(c)) return true;
  return false;
}

(async () => {
  const d = await L.readStdinJSON();
  const command = d.command || "";

  if (isSafeCommand(command)) return L.emit({ permission: "allow" });
  if (!(await L.isRemoteActive())) return L.emit({ permission: "allow" });

  const cwd = d.cwd || "";
  const workspace = L.getWorkspace(d);
  const agent = L.getAgentLabel(d);
  const safeCmd = L.sanitize(command);

  let summary = L.oneLine(safeCmd, 80);
  const cwdBase = L.baseName(cwd);
  if (cwdBase) summary = L.clip(`${summary} @ ${cwdBase}`, 80);

  const body = {
    type: "shell",
    kind: "shell",
    title: "🖥️ Shell 命令待授权",
    content: `**命令**\n\`\`\`\n${safeCmd}\n\`\`\`\n**目录** \`${cwd}\``,
    context: "Shell 命令执行",
    summary,
    workspace,
    agent,
  };

  const resp = await L.daemonRequest("POST", "/approve", body, 600000);
  if (!resp) return L.emit({ permission: "allow" });

  if (resp.decision === "deny") {
    return L.emit({
      permission: "deny",
      user_message: "飞书远程审批：已拒绝",
      agent_message: "用户通过飞书远程拒绝了此命令的执行。请考虑替代方案或跳过此步骤。",
    });
  }
  return L.emit({ permission: "allow" });
})();
