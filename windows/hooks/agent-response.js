// afterAgentResponse hook：缓存 Agent 最后一次输出，供 stop hook 读取。
const fs = require("fs");
const os = require("os");
const path = require("path");
const L = require("./clb-lib");

(async () => {
  const d = await L.readStdinJSON(5000);
  try {
    // 注意：Windows 下 Cursor 给 hook 的 stdin `text` 字段是双重错误编码（GBK round-trip，
    // 含私用区字符），不可信。改从 Cursor 自己写的干净 UTF-8 transcript 取最后一条 assistant 文本。
    const tp = (d && d.transcript_path) || process.env.CURSOR_TRANSCRIPT_PATH;
    let text = L.extractLastAssistantFromTranscript(tp);
    if (!text) text = L.extractAgentText(d); // 极少数拿不到 transcript 时的兜底
    if (text) {
      const dir = path.join(os.homedir(), ".cursor", "cursor-lark-bridge");
      fs.mkdirSync(dir, { recursive: true });
      fs.writeFileSync(path.join(dir, "last-response.txt"), text, "utf8");
    }
  } catch (_e) {}
  L.emit({});
})().catch(() => L.emit({}));
