// beforeMCPExecution hook：拦截 MCP 工具调用，经飞书远程审批。
const L = require("./clb-lib");

// MCP 场景脱敏：JSON 串里 "api_key":"xxx" 等形式（刻意不含单独的 "key"，误伤率高）。
const MCP_SENSITIVE = /((?:api[_-]?key|password|token|secret|bearer)["\s:=]+)"?[^"\s,}]+/gi;

(async () => {
  const d = await L.readStdinJSON();
  if (!(await L.isRemoteActive())) return L.emit({ permission: "allow" });

  const toolName = d.tool_name || "";
  let toolInput = d.tool_input;
  let tiStr;
  if (toolInput && typeof toolInput === "object") {
    tiStr = JSON.stringify(toolInput);
  } else {
    tiStr = String(toolInput == null ? "" : toolInput);
  }
  tiStr = tiStr.replace(MCP_SENSITIVE, "$1***").slice(0, 500);

  const body = {
    type: "mcp",
    kind: "mcp",
    title: "🔧 MCP 工具调用待授权",
    content: `**工具** \`${toolName}\`\n**参数摘要**\n\`\`\`\n${tiStr}\n\`\`\``,
    context: "MCP 工具调用",
    summary: L.clip(toolName, 80),
    workspace: L.getWorkspace(d),
    agent: L.getAgentLabel(d),
  };

  const resp = await L.daemonRequest("POST", "/approve", body, 600000);
  if (!resp) return L.emit({ permission: "allow" });

  if (resp.decision === "deny") {
    return L.emit({
      permission: "deny",
      user_message: "飞书远程审批：已拒绝此 MCP 调用",
      agent_message: `用户通过飞书远程拒绝了 MCP 工具 ${toolName} 的调用。请考虑替代方案。`,
    });
  }
  return L.emit({ permission: "allow" });
})();
