// preToolUse hook（matcher: AskQuestion|SwitchMode）：把交互转到飞书。
const L = require("./clb-lib");

(async () => {
  const d = await L.readStdinJSON();
  if (!(await L.isRemoteActive())) return L.emit({});

  const toolName = d.tool_name || "";
  let toolInput = d.tool_input || {};
  if (typeof toolInput === "string") {
    try {
      toolInput = JSON.parse(toolInput);
    } catch (_e) {
      toolInput = {};
    }
  }

  const workspace = L.getWorkspace(d);
  const agent = L.getAgentLabel(d);

  if (toolName === "AskQuestion") {
    const questions = toolInput.questions || [];
    const parts = [];
    const optionsAll = [];
    for (const q of questions) {
      parts.push(q.prompt || "");
      for (const o of q.options || []) optionsAll.push(o.label || "");
    }
    const questionText = parts.length ? parts.join(" | ") : "需要您做选择";
    const summary = L.oneLine(L.sanitize(parts[0] || questionText), 80);

    const resp = await L.daemonRequest(
      "POST",
      "/ask",
      {
        question: questionText,
        options: optionsAll,
        context: "AskQuestion 交互",
        kind: "askQuestion",
        summary,
        workspace,
        agent,
      },
      600000
    );

    if (resp && resp.reply) {
      return L.emit({
        permission: "deny",
        user_message: `飞书远程回复: ${resp.reply}`,
        agent_message: `用户通过飞书远程回复了此问题，答案是: ${resp.reply}。请根据此回复继续工作，不需要再次提问。`,
      });
    }
    return L.emit({});
  }

  if (toolName === "SwitchMode") {
    const targetMode = toolInput.target_mode_id || "";
    const explanation = toolInput.explanation || "";
    const resp = await L.daemonRequest(
      "POST",
      "/approve",
      {
        type: "mode_switch",
        kind: "switchMode",
        title: "🔄 模式切换请求",
        content: `**目标模式** \`${targetMode}\`\n**说明** ${explanation}`,
        context: "模式切换",
        summary: L.clip(L.sanitize(targetMode), 80),
        workspace,
        agent,
      },
      600000
    );
    if (resp && resp.decision === "deny") {
      return L.emit({
        permission: "deny",
        user_message: "飞书远程审批：拒绝模式切换",
        agent_message: `用户通过飞书拒绝了切换到 ${targetMode} 模式。请在当前模式下继续工作。`,
      });
    }
    return L.emit({ permission: "allow" });
  }

  return L.emit({});
})();
