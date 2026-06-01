// stop hook：Agent 停止时发飞书暂停卡片并等待用户决定是否继续。
const fs = require("fs");
const os = require("os");
const path = require("path");
const L = require("./clb-lib");

(async () => {
  const d = await L.readStdinJSON(5000);
  if (!(await L.isRemoteActive())) return L.emit({});

  const status = d.status || "";
  const loopCount = parseInt(d.loop_count, 10) || 0;
  if (status === "aborted") return L.emit({});

  // 取 Agent 最后输出：优先 transcript（Cursor 写的干净 UTF-8，最可靠），
  // 缺失才回退 afterAgentResponse 缓存（其 stdin 在 Windows 上可能编码异常）。
  let summary = L.extractLastAssistantFromTranscript(d.transcript_path || process.env.CURSOR_TRANSCRIPT_PATH);
  if (!summary) {
    try {
      const cacheFile = path.join(os.homedir(), ".cursor", "cursor-lark-bridge", "last-response.txt");
      if (fs.existsSync(cacheFile)) summary = fs.readFileSync(cacheFile, "utf8").trim();
    } catch (_e) {}
  }

  const resp = await L.daemonRequest("POST", "/stop", {
    status,
    loop_count: loopCount,
    summary: L.sanitize(summary),
    agent: L.getAgentLabel(d),
    kind: "stop",
    workspace: L.getWorkspace(d),
  }, 0); // 0 = 无限等待：暂停卡片永久存在，直到用户回复或点「结束会话」

  if (!resp) return L.emit({});
  const reply = String(resp.reply || "").trim();
  if (!reply || reply.toLowerCase() === "skip") return L.emit({});
  return L.emit({ followup_message: reply });
})().catch(() => L.emit({}));
