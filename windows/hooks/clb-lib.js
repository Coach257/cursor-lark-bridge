// cursor-lark-bridge —— Windows hook 共享库（Node.js，无第三方依赖）
//
// 这些 hook 由 Cursor 通过 hooks.json 调用：
//   - 输入：stdin 一段 JSON
//   - 输出：stdout 一段 JSON（决策 / followup）
// 跨平台用 Node 重写，替代原 bash + python3 + curl 组合（Windows 上不可靠）。

const fs = require("fs");
const http = require("http");

const DAEMON_HOST = "127.0.0.1";
const DAEMON_PORT = 19836;

// 读取 stdin 全部内容并按 JSON 解析；失败返回 {}。
// 必须等到 stdin 关闭或达到 maxWaitMs，不能过早超时（否则 afterAgentResponse 会拿到 {}）。
function readStdinJSON(maxWaitMs) {
  const limit = maxWaitMs || 30000;
  return new Promise((resolve) => {
    let data = "";
    let settled = false;
    const finish = () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try {
        // Cursor 在 Windows 下会给 stdin 前置一个 UTF-8 BOM(\uFEFF)，
        // 直接 JSON.parse 会抛错（拿到 {}）—— 必须先剥掉 BOM 再解析。
        const cleaned = data.replace(/^\uFEFF/, "").trim();
        resolve(cleaned ? JSON.parse(cleaned) : {});
      } catch (_e) {
        resolve({});
      }
    };
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (c) => (data += c));
    process.stdin.on("end", finish);
    process.stdin.on("error", finish);
    const timer = setTimeout(finish, limit);
    timer.unref?.();
  });
}

// afterAgentResponse / stop 等 hook 的文本字段（Cursor 版本间字段名不同）。
function extractAgentText(d) {
  if (!d || typeof d !== "object") return "";
  const candidates = [
    d.text, d.response, d.message, d.content,
    d.assistant_message, d.output, d.final_text, d.reply,
  ];
  for (const c of candidates) {
    if (typeof c === "string" && c.trim()) return c.trim();
  }
  if (d.response && typeof d.response === "object" && typeof d.response.text === "string") {
    return d.response.text.trim();
  }
  if (d.message && typeof d.message === "object" && typeof d.message.text === "string") {
    return d.message.text.trim();
  }
  return "";
}

// 从 Cursor 会话 transcript（jsonl）取最后一条 assistant 文本。
function extractLastAssistantFromTranscript(transcriptPath) {
  if (!transcriptPath || !fs.existsSync(transcriptPath)) return "";
  let raw = "";
  try {
    raw = fs.readFileSync(transcriptPath, "utf8");
  } catch (_e) {
    return "";
  }
  const lines = raw.split(/\r?\n/).filter((l) => l.trim());
  for (let i = lines.length - 1; i >= 0; i--) {
    try {
      const row = JSON.parse(lines[i]);
      if (row.role !== "assistant") continue;
      const parts = row.message && row.message.content;
      if (!Array.isArray(parts)) continue;
      const texts = parts
        .filter((p) => p && p.type === "text" && typeof p.text === "string")
        .map((p) => p.text);
      const joined = texts.join("\n").trim();
      if (joined) return joined;
    } catch (_e) {
      /* skip malformed line */
    }
  }
  return "";
}

// 向 daemon 发请求。method: GET/POST；返回解析后的 JSON 或 null（任何失败都 null）。
function daemonRequest(method, path, bodyObj, timeoutMs) {
  return new Promise((resolve) => {
    const payload = bodyObj ? Buffer.from(JSON.stringify(bodyObj), "utf8") : null;
    const opts = {
      host: DAEMON_HOST,
      port: DAEMON_PORT,
      path,
      method,
      headers: payload
        ? { "Content-Type": "application/json", "Content-Length": payload.length }
        : {},
    };
    // timeoutMs <= 0 表示「无限等待」（stop 用：暂停卡片永久等用户回复，不自动结束）。
    // 注意：Node 定时器上限约 24.8 天，故无限等待必须靠「不设置 timeout」实现。
    if (timeoutMs && timeoutMs > 0) opts.timeout = timeoutMs;
    const req = http.request(opts, (res) => {
      let buf = "";
      res.setEncoding("utf8");
      res.on("data", (c) => (buf += c));
      res.on("end", () => {
        try {
          resolve(buf.trim() ? JSON.parse(buf) : {});
        } catch (_e) {
          resolve(null);
        }
      });
    });
    req.on("error", () => resolve(null));
    if (timeoutMs && timeoutMs > 0) {
      req.on("timeout", () => {
        req.destroy();
        resolve(null);
      });
    }
    if (payload) req.write(payload);
    req.end();
  });
}

// 远程模式是否激活。连不上 daemon 或解析失败都视为未激活（fail-open）。
async function isRemoteActive() {
  const r = await daemonRequest("GET", "/mode", null, 2000);
  return !!(r && r.active === true);
}

// 统一脱敏：覆盖 api_key / password / token / secret / key / bearer 的各种写法。
const SENSITIVE = /((?:api[_-]?key|password|token|secret|key|bearer)[=:\s]+)[^\s]+/gi;
function sanitize(text) {
  return String(text || "").replace(SENSITIVE, "$1***");
}

// 取路径 basename（去尾随分隔符，兼容 / 和 \）。
function baseName(p) {
  if (!p) return "";
  const s = String(p).replace(/[\\/]+$/, "");
  const idx = Math.max(s.lastIndexOf("/"), s.lastIndexOf("\\"));
  return idx >= 0 ? s.slice(idx + 1) : s;
}

// 从 hook input 提取 workspace（workspace_roots[0] 的 basename）。
function getWorkspace(d) {
  const roots = (d && d.workspace_roots) || [];
  const first = (roots && roots[0]) || "";
  return baseName(first);
}

// Agent 标识：环境变量覆盖 > 项目名 · #会话短id。
function getAgentLabel(d) {
  const override = (process.env.FEISHU_BRIDGE_AGENT_LABEL || "").trim();
  if (override) return override;
  const project = getWorkspace(d);
  const conv = String((d && d.conversation_id) || "").trim();
  const shortId = conv ? conv.slice(0, 8) : "";
  const parts = [];
  if (project) parts.push(project);
  if (shortId) parts.push("#" + shortId);
  return parts.join(" · ");
}

// 截断到 n 字（按字符）。
function clip(s, n) {
  s = String(s || "");
  return s.length > n ? s.slice(0, n - 3) + "..." : s;
}

// 把多行压成一行再截断，给 summary 用。
function oneLine(s, n) {
  return clip(String(s || "").replace(/\s*\n\s*/g, " ").trim(), n);
}

// 输出结果并退出（始终 exit 0，避免打断 Agent）。
function emit(obj) {
  process.stdout.write(JSON.stringify(obj || {}));
  process.exit(0);
}

module.exports = {
  readStdinJSON,
  extractAgentText,
  extractLastAssistantFromTranscript,
  daemonRequest,
  isRemoteActive,
  sanitize,
  getWorkspace,
  getAgentLabel,
  baseName,
  clip,
  oneLine,
  emit,
};
