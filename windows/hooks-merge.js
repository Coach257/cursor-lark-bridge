// hooks-merge.js —— 把 cursor-lark-bridge 的 hook 条目并入用户的 ~/.cursor/hooks.json
//
// 用法: node hooks-merge.js <existing-hooks.json> <additions.json> <marker>
//
// 安全契约（与原 hooks-merge.py 一致）：
//   - 保留用户自己的条目原样不动；
//   - 旧的 cursor-lark-bridge 条目（command 含 marker）替换而非重复，保证可重复执行；
//   - 兼容新 schema（顶层 "hooks" 包裹）和旧的扁平 {event:[...]} schema；
//   - 写出 UTF-8 无 BOM（Go json 解析器不接受 BOM）。

const fs = require("fs");

const HOOK_EVENTS = [
  "beforeShellExecution",
  "beforeMCPExecution",
  "preToolUse",
  "afterAgentResponse",
  "stop",
];

const [, , existingPath, additionsPath, marker] = process.argv;
if (!existingPath || !additionsPath || !marker) {
  console.error("usage: node hooks-merge.js <existing> <additions> <marker>");
  process.exit(2);
}

function loadJSON(p) {
  try {
    const t = fs.readFileSync(p, "utf8").replace(/^\uFEFF/, "").trim();
    return t ? JSON.parse(t) : {};
  } catch (_e) {
    return {};
  }
}

function isOurs(entry) {
  return entry && typeof entry === "object" && String(entry.command || "").includes(marker);
}

function asList(v) {
  if (v == null) return [];
  return Array.isArray(v) ? v.slice() : [v];
}

function hasNewSchema(doc) {
  if (doc.hooks && typeof doc.hooks === "object" && !Array.isArray(doc.hooks)) return true;
  for (const k of HOOK_EVENTS) if (k in doc) return false;
  return true; // 空文件默认用新 schema
}

function mergeEvents(target, additions) {
  const merged = Object.assign({}, target);
  for (const [event, entries] of Object.entries(additions)) {
    let current = asList(merged[event]).filter((e) => !isOurs(e));
    current = current.concat(asList(entries));
    merged[event] = current;
  }
  return merged;
}

const existing = loadJSON(existingPath);
const additions = loadJSON(additionsPath);
if (!additions || Object.keys(additions).length === 0) {
  console.error("error: additions file is empty");
  process.exit(2);
}

let merged;
if (hasNewSchema(existing)) {
  merged = Object.assign({}, existing);
  if (merged.version == null) merged.version = 1;
  const inner = merged.hooks && typeof merged.hooks === "object" ? merged.hooks : {};
  merged.hooks = mergeEvents(inner, additions);
} else {
  merged = mergeEvents(existing, additions);
}

const out = JSON.stringify(merged, null, 2) + "\n";
fs.mkdirSync(require("path").dirname(existingPath), { recursive: true });
fs.writeFileSync(existingPath, out, "utf8"); // utf8 无 BOM
process.exit(0);
