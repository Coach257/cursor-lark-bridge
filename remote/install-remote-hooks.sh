#!/usr/bin/env bash
# =============================================================================
# cursor-lark-bridge —— 远程服务器 hook 安装器（路线①：反向隧道回连本地 daemon）
# -----------------------------------------------------------------------------
# 用途：在「Cursor Remote-SSH 连接的 Linux 服务器」上安装一套纯 bash hook。
#       hook 只把消息 POST 到 127.0.0.1:19836，由 SSH 反向隧道转发回你
#       【本机】正在运行的 cursor-lark-bridge daemon。
#
# 本脚本【不】安装 daemon、【不】需要 Node.js、【不】需要 lark-cli。
# 远程只需要：bash + curl + python3（绝大多数 Linux 服务器自带）。
#
# 用法（在远程服务器上执行）：
#       bash install-remote-hooks.sh
# 卸载：
#       bash install-remote-hooks.sh --uninstall
# =============================================================================
set -euo pipefail

CURSOR_DIR="$HOME/.cursor"
HOOKS_DIR="$CURSOR_DIR/hooks/cursor-lark-bridge"
STATE_DIR="$CURSOR_DIR/cursor-lark-bridge"
HOOKS_JSON="$CURSOR_DIR/hooks.json"
DAEMON_PORT="19836"

c_green() { printf '\033[32m%s\033[0m\n' "$1"; }
c_red()   { printf '\033[31m%s\033[0m\n' "$1"; }
c_cyan()  { printf '\033[36m%s\033[0m\n' "$1"; }

# ---------------------------------------------------------------------------
# 卸载
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--uninstall" ]; then
    python3 - "$HOOKS_JSON" <<'MERGE_PY'
import json, os, sys
path = sys.argv[1]
MARKER = "hooks/cursor-lark-bridge/"
if not os.path.exists(path):
    sys.exit(0)
with open(path, "r", encoding="utf-8-sig") as f:
    text = f.read().strip()
doc = json.loads(text) if text else {}

def clean(events):
    for ev in list(events.keys()):
        v = events[ev]
        if isinstance(v, list):
            events[ev] = [e for e in v if MARKER not in str((e or {}).get("command", ""))]
    return events

if isinstance(doc.get("hooks"), dict):
    doc["hooks"] = clean(doc["hooks"])
else:
    doc = clean(doc)
with open(path, "w", encoding="utf-8") as f:
    f.write(json.dumps(doc, indent=2, ensure_ascii=False) + "\n")
print("  已从 hooks.json 移除 cursor-lark-bridge 条目")
MERGE_PY
    rm -rf "$HOOKS_DIR"
    c_green "✓ 已卸载远程 hook（hooks.json 已清理，hook 文件已删除）"
    exit 0
fi

# ---------------------------------------------------------------------------
# 1. 依赖检查
# ---------------------------------------------------------------------------
for dep in bash curl python3; do
    if ! command -v "$dep" >/dev/null 2>&1; then
        c_red "✗ 缺少依赖: $dep — 请先在服务器上安装后重试"
        exit 1
    fi
done
c_green "✓ 依赖就绪：bash / curl / python3"

mkdir -p "$HOOKS_DIR" "$STATE_DIR"

# ---------------------------------------------------------------------------
# 2. 写入 hook 文件
# ---------------------------------------------------------------------------

cat > "$HOOKS_DIR/agent-label.py" <<'CLB_FILE_EOF'
#!/usr/bin/env python3
"""从 Cursor hook input (stdin JSON) 提取 Agent 标识，输出到 stdout。"""
import json, os, sys

def main() -> int:
    override = os.environ.get("FEISHU_BRIDGE_AGENT_LABEL", "").strip()
    if override:
        sys.stdout.write(override)
        return 0
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0
    if not isinstance(data, dict):
        return 0
    project = ""
    roots = data.get("workspace_roots")
    if isinstance(roots, list) and roots:
        first = str(roots[0] or "").rstrip("/")
        if first:
            project = os.path.basename(first)
    conv_id = str(data.get("conversation_id") or "").strip()
    short_id = conv_id[:8] if conv_id else ""
    parts = []
    if project:
        parts.append(project)
    if short_id:
        parts.append(f"#{short_id}")
    sys.stdout.write(" · ".join(parts))
    return 0

if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)
CLB_FILE_EOF

cat > "$HOOKS_DIR/agent-response.sh" <<'CLB_FILE_EOF'
#!/bin/bash
# afterAgentResponse hook: 缓存 Agent 最后一次输出的文本，供 stop hook 使用
CACHE_DIR="$HOME/.cursor/cursor-lark-bridge"
CACHE_FILE="$CACHE_DIR/last-response.txt"
mkdir -p "$CACHE_DIR"
CACHE_FILE="$CACHE_FILE" python3 -c '
import sys, json, os
try:
    d = json.load(sys.stdin)
    text = (d.get("text", "") or "").strip()
    if text:
        with open(os.environ["CACHE_FILE"], "w", encoding="utf-8") as f:
            f.write(text)
except Exception:
    pass
' 2>/dev/null
echo "{}"
CLB_FILE_EOF

cat > "$HOOKS_DIR/on-stop.sh" <<'CLB_FILE_EOF'
#!/bin/bash
# stop hook: Agent 停止时，通过飞书发送暂停卡片并等待用户回复
DAEMON="http://127.0.0.1:19836"
CACHE_FILE="$HOME/.cursor/cursor-lark-bridge/last-response.txt"
HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

input=$(cat)
AGENT_LABEL=$(echo "$input" | python3 "$HOOKS_DIR/agent-label.py" 2>/dev/null)

mode=$(curl -s --connect-timeout 1 --max-time 2 "$DAEMON/mode" 2>/dev/null)
if [ $? -ne 0 ] || [ -z "$mode" ]; then
    echo '{}'
    exit 0
fi
active=$(echo "$mode" | python3 -c "import sys,json; print(json.load(sys.stdin).get('active',False))" 2>/dev/null)
if [ "$active" != "True" ]; then
    echo '{}'
    exit 0
fi

status=$(echo "$input" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null)
loop_count=$(echo "$input" | python3 -c "import sys,json; print(json.load(sys.stdin).get('loop_count',0))" 2>/dev/null)
if [ "$status" = "aborted" ]; then
    echo '{}'
    exit 0
fi

summary=""
if [ -f "$CACHE_FILE" ]; then
    summary=$(cat "$CACHE_FILE" 2>/dev/null)
fi

WORKSPACE=$(echo "$input" | python3 -c "
import sys, json, os
try:
    d = json.load(sys.stdin)
    roots = d.get('workspace_roots') or []
    root_path = (roots[0] if roots else '') or ''
    root_path = root_path.rstrip('/')
    print(os.path.basename(root_path))
except Exception:
    pass
" 2>/dev/null)

resp=$(STATUS="$status" LOOP_COUNT="$loop_count" SUMMARY="$summary" AGENT_LABEL="$AGENT_LABEL" WORKSPACE="$WORKSPACE" python3 <<'PYEOF'
import json, os, re, urllib.request, urllib.error, sys
SENSITIVE = re.compile(
    r'((?:api[_-]?key|password|token|secret|key|bearer)[=:\s]+)[^\s]+',
    re.IGNORECASE,
)
raw_summary = os.environ.get("SUMMARY", "")
safe_summary = SENSITIVE.sub(r'\1***', raw_summary)
body = json.dumps({
    "status": os.environ.get("STATUS", ""),
    "loop_count": int(os.environ.get("LOOP_COUNT", "0") or 0),
    "summary": safe_summary,
    "agent": os.environ.get("AGENT_LABEL", ""),
    "kind": "stop",
    "workspace": os.environ.get("WORKSPACE", ""),
}).encode("utf-8")
req = urllib.request.Request(
    "http://127.0.0.1:19836/stop",
    data=body,
    headers={"Content-Type": "application/json"},
    method="POST",
)
try:
    # 无限等待：与本地 Windows 版一致，stop 卡片永久存在直到手动结束
    with urllib.request.urlopen(req, timeout=31536000) as r:
        sys.stdout.write(r.read().decode("utf-8", errors="replace"))
except Exception:
    sys.stdout.write("")
PYEOF
)

if [ -z "$resp" ]; then
    echo '{}'
    exit 0
fi

echo "$resp" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    reply = (d.get('reply', '') or '').strip()
    if not reply or reply.lower() == 'skip':
        print(json.dumps({}))
    else:
        print(json.dumps({'followup_message': reply}))
except Exception:
    print(json.dumps({}))
" 2>/dev/null || echo '{}'
CLB_FILE_EOF

cat > "$HOOKS_DIR/shell-approve.sh" <<'CLB_FILE_EOF'
#!/bin/bash
# beforeShellExecution hook: 拦截 shell 命令，通过飞书远程审批
DAEMON="http://127.0.0.1:19836"
HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
input=$(cat)
AGENT_LABEL=$(echo "$input" | python3 "$HOOKS_DIR/agent-label.py" 2>/dev/null)
export AGENT_LABEL
command=$(echo "$input" | python3 -c "import sys,json; print(json.load(sys.stdin).get('command',''))" 2>/dev/null)
case "$command" in
    curl*127.0.0.1:19836*|curl*localhost:19836*|fb\ *|*cursor-lark-bridge/bridge.sh*|*lark-cli*|cat\ *|tail\ *|head\ *|ls\ *|echo\ *|which\ *|pwd|whoami)
        echo '{"permission":"allow"}'
        exit 0
        ;;
esac
mode=$(curl -s --connect-timeout 1 --max-time 2 "$DAEMON/mode" 2>/dev/null)
if [ $? -ne 0 ]; then
    echo '{"permission":"allow"}'
    exit 0
fi
active=$(echo "$mode" | python3 -c "import sys,json; print(json.load(sys.stdin).get('active',False))" 2>/dev/null)
if [ "$active" != "True" ]; then
    echo '{"permission":"allow"}'
    exit 0
fi
body=$(echo "$input" | python3 -c "
import sys, json, os, re
d = json.load(sys.stdin)
cmd = d.get('command', '')
cwd = d.get('cwd', '')
roots = d.get('workspace_roots') or []
root_path = (roots[0] if roots else '') or ''
root_path = root_path.rstrip('/')
workspace = os.path.basename(root_path)
SENSITIVE = re.compile(r'((?:api[_-]?key|password|token|secret|key|bearer)[=:\s]+)[^\s]+', re.IGNORECASE)
safe_cmd = SENSITIVE.sub(r'\1***', cmd)
summary_cmd = safe_cmd.replace('\n', ' ').strip()
if len(summary_cmd) > 80:
    summary_cmd = summary_cmd[:77] + '...'
cwd_base = os.path.basename(cwd.rstrip('/')) if cwd else ''
summary = f'{summary_cmd} @ {cwd_base}' if cwd_base else summary_cmd
if len(summary) > 80:
    summary = summary[:77] + '...'
print(json.dumps({
    'type': 'shell',
    'kind': 'shell',
    'title': '🖥️ Shell 命令待授权',
    'content': f'**命令**\n\`\`\`\n{safe_cmd}\n\`\`\`\n**目录** \`{cwd}\`',
    'context': 'Shell 命令执行',
    'summary': summary,
    'workspace': workspace,
    'agent': os.environ.get('AGENT_LABEL', ''),
}))
" 2>/dev/null)
if [ -z "$body" ]; then
    echo '{"permission":"allow"}'
    exit 0
fi
resp=$(curl -s --max-time 600 -X POST "$DAEMON/approve" \
    -H "Content-Type: application/json" \
    -d "$body" 2>/dev/null)
if [ $? -ne 0 ] || [ -z "$resp" ]; then
    echo '{"permission":"allow"}'
    exit 0
fi
echo "$resp" | python3 -c "
import sys, json
d = json.load(sys.stdin)
decision = d.get('decision', 'allow')
if decision == 'deny':
    print(json.dumps({
        'permission': 'deny',
        'user_message': '飞书远程审批：已拒绝',
        'agent_message': '用户通过飞书远程拒绝了此命令的执行。请考虑替代方案或跳过此步骤。'
    }))
else:
    print(json.dumps({'permission': 'allow'}))
" 2>/dev/null || echo '{"permission":"allow"}'
CLB_FILE_EOF

cat > "$HOOKS_DIR/mcp-approve.sh" <<'CLB_FILE_EOF'
#!/bin/bash
# beforeMCPExecution hook: 拦截 MCP 工具调用，通过飞书远程审批
DAEMON="http://127.0.0.1:19836"
HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
input=$(cat)
AGENT_LABEL=$(echo "$input" | python3 "$HOOKS_DIR/agent-label.py" 2>/dev/null)
export AGENT_LABEL
mode=$(curl -s --connect-timeout 1 --max-time 2 "$DAEMON/mode" 2>/dev/null)
if [ $? -ne 0 ]; then
    echo '{"permission":"allow"}'
    exit 0
fi
active=$(echo "$mode" | python3 -c "import sys,json; print(json.load(sys.stdin).get('active',False))" 2>/dev/null)
if [ "$active" != "True" ]; then
    echo '{"permission":"allow"}'
    exit 0
fi
body=$(echo "$input" | python3 -c "
import sys, json, os, re
d = json.load(sys.stdin)
tool_name = d.get('tool_name', '')
tool_input = d.get('tool_input', '{}')
roots = d.get('workspace_roots') or []
root_path = (roots[0] if roots else '') or ''
root_path = root_path.rstrip('/')
workspace = os.path.basename(root_path)
SENSITIVE = re.compile(r'((?:api[_-]?key|password|token|secret|bearer)[\"\s:=]+)\"?[^\"\s,\}]+', re.IGNORECASE)
if isinstance(tool_input, dict):
    ti_str = json.dumps(tool_input, ensure_ascii=False)
else:
    ti_str = str(tool_input)
ti_str = SENSITIVE.sub(r'\1***', ti_str)[:500]
summary = tool_name[:80]
print(json.dumps({
    'type': 'mcp',
    'kind': 'mcp',
    'title': '🔧 MCP 工具调用待授权',
    'content': f'**工具** \`{tool_name}\`\n**参数摘要**\n\`\`\`\n{ti_str}\n\`\`\`',
    'context': 'MCP 工具调用',
    'summary': summary,
    'workspace': workspace,
    'agent': os.environ.get('AGENT_LABEL', ''),
}))
" 2>/dev/null)
if [ -z "$body" ]; then
    echo '{"permission":"allow"}'
    exit 0
fi
resp=$(curl -s --max-time 600 -X POST "$DAEMON/approve" \
    -H "Content-Type: application/json" \
    -d "$body" 2>/dev/null)
if [ $? -ne 0 ] || [ -z "$resp" ]; then
    echo '{"permission":"allow"}'
    exit 0
fi
echo "$resp" | python3 -c "
import sys, json
d = json.load(sys.stdin)
decision = d.get('decision', 'allow')
if decision == 'deny':
    print(json.dumps({
        'permission': 'deny',
        'user_message': '飞书远程审批：已拒绝此 MCP 调用',
        'agent_message': '用户通过飞书远程拒绝了 MCP 工具调用。请考虑替代方案。'
    }))
else:
    print(json.dumps({'permission': 'allow'}))
" 2>/dev/null || echo '{"permission":"allow"}'
CLB_FILE_EOF

cat > "$HOOKS_DIR/pretool-approve.sh" <<'CLB_FILE_EOF'
#!/bin/bash
# preToolUse hook: 拦截 AskQuestion 和 SwitchMode 工具调用
DAEMON="http://127.0.0.1:19836"
HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
input=$(cat)
AGENT_LABEL=$(echo "$input" | python3 "$HOOKS_DIR/agent-label.py" 2>/dev/null)
export AGENT_LABEL
mode=$(curl -s --connect-timeout 1 --max-time 2 "$DAEMON/mode" 2>/dev/null)
if [ $? -ne 0 ]; then
    echo '{}'
    exit 0
fi
active=$(echo "$mode" | python3 -c "import sys,json; print(json.load(sys.stdin).get('active',False))" 2>/dev/null)
if [ "$active" != "True" ]; then
    echo '{}'
    exit 0
fi
echo "$input" | python3 -c "
import sys, json, os, re
DAEMON = 'http://127.0.0.1:19836'
AGENT = os.environ.get('AGENT_LABEL', '')
d = json.load(sys.stdin)
tool_name = d.get('tool_name', '')
tool_input = d.get('tool_input', {})
if isinstance(tool_input, str):
    try:
        tool_input = json.loads(tool_input)
    except:
        tool_input = {}
roots = d.get('workspace_roots') or []
root_path = (roots[0] if roots else '') or ''
root_path = root_path.rstrip('/')
workspace = os.path.basename(root_path)
SENSITIVE = re.compile(r'((?:api[_-]?key|password|token|secret|key|bearer)[=:\s]+)[^\s]+', re.IGNORECASE)
def sanitize(text):
    return SENSITIVE.sub(r'\1***', text or '')
def curl_post(endpoint, data):
    import urllib.request
    req = urllib.request.Request(
        DAEMON + endpoint,
        data=json.dumps(data).encode(),
        headers={'Content-Type': 'application/json'},
        method='POST'
    )
    try:
        with urllib.request.urlopen(req, timeout=600) as resp:
            return json.loads(resp.read())
    except Exception:
        return None
if tool_name == 'AskQuestion':
    questions = tool_input.get('questions', [])
    parts = []
    options_all = []
    for q in questions:
        parts.append(q.get('prompt', ''))
        for o in q.get('options', []):
            options_all.append(o.get('label', ''))
    question_text = ' | '.join(parts) if parts else '需要您做选择'
    first_q = sanitize((parts[0] if parts else question_text).replace('\n', ' ').strip())
    summary = first_q[:77] + '...' if len(first_q) > 80 else first_q
    resp = curl_post('/ask', {
        'question': question_text,
        'options': options_all,
        'context': 'AskQuestion 交互',
        'kind': 'askQuestion',
        'summary': summary,
        'workspace': workspace,
        'agent': AGENT,
    })
    if resp and resp.get('reply'):
        reply = resp['reply']
        print(json.dumps({
            'permission': 'deny',
            'user_message': f'飞书远程回复: {reply}',
            'agent_message': f'用户通过飞书远程回复了此问题，答案是: {reply}。请根据此回复继续工作，不需要再次提问。'
        }))
    else:
        print(json.dumps({}))
elif tool_name == 'SwitchMode':
    target_mode = tool_input.get('target_mode_id', '')
    explanation = tool_input.get('explanation', '')
    summary = sanitize(target_mode)[:80]
    resp = curl_post('/approve', {
        'type': 'mode_switch',
        'kind': 'switchMode',
        'title': '🔄 模式切换请求',
        'content': f'**目标模式** \`{target_mode}\`\n**说明** {explanation}',
        'context': '模式切换',
        'summary': summary,
        'workspace': workspace,
        'agent': AGENT,
    })
    if resp and resp.get('decision') == 'deny':
        print(json.dumps({
            'permission': 'deny',
            'user_message': '飞书远程审批：拒绝模式切换',
            'agent_message': f'用户通过飞书拒绝了切换到 {target_mode} 模式。请在当前模式下继续工作。'
        }))
    else:
        print(json.dumps({'permission': 'allow'}))
else:
    print(json.dumps({}))
" 2>/dev/null || echo '{}'
CLB_FILE_EOF

chmod +x "$HOOKS_DIR"/*.sh
c_green "✓ 已写入 6 个 hook 文件 → $HOOKS_DIR"

# ---------------------------------------------------------------------------
# 3. 合并 hooks.json（绝对路径，避免远程 cwd 不确定；幂等，自动备份）
# ---------------------------------------------------------------------------
python3 - "$HOOKS_JSON" "$HOOKS_DIR" <<'MERGE_PY'
import json, os, sys, datetime

path, hooks_dir = sys.argv[1], sys.argv[2]
MARKER = "hooks/cursor-lark-bridge/"

def h(name):
    # 远程恒为 Linux：强制正斜杠，确保命令路径含 MARKER（保证重装幂等）
    return f'bash {hooks_dir.rstrip("/")}/{name}'

# 所有本桥接可能注册的事件（用于重装时统一清理旧条目）
ALL_CLB_EVENTS = (
    "beforeShellExecution", "beforeMCPExecution",
    "preToolUse", "afterAgentResponse", "stop",
)

# 按用户偏好：不注册 shell / MCP 审批 hook（命令直接执行，不走飞书逐条把关）。
# 如需恢复审批，把下面两行取消注释即可。
additions = {
    # "beforeShellExecution": [{"command": h("shell-approve.sh"), "timeout": 600}],
    # "beforeMCPExecution":   [{"command": h("mcp-approve.sh"),   "timeout": 600}],
    "preToolUse":           [{"command": h("pretool-approve.sh"), "matcher": "AskQuestion|SwitchMode", "timeout": 600}],
    "afterAgentResponse":   [{"command": h("agent-response.sh"), "timeout": 5}],
    "stop":                 [{"command": h("on-stop.sh"), "timeout": 31536000, "loop_limit": 20}],
}

doc = {}
if os.path.exists(path):
    with open(path, "r", encoding="utf-8-sig") as f:
        text = f.read().strip()
    if text:
        doc = json.loads(text)

def is_clb(e):
    return isinstance(e, dict) and MARKER in str(e.get("command", ""))

def merge_events(target):
    # 先把所有事件里的旧 CLB 条目清掉（这样禁用某个 hook 后重装能真正移除它）
    for ev in ALL_CLB_EVENTS:
        cur = target.get(ev)
        if isinstance(cur, list):
            cleaned = [e for e in cur if not is_clb(e)]
            if cleaned:
                target[ev] = cleaned
            else:
                target.pop(ev, None)
    # 再加入当前要启用的 hook
    for ev, entries in additions.items():
        cur = target.get(ev)
        cur = list(cur) if isinstance(cur, list) else ([] if cur is None else [cur])
        cur = [e for e in cur if not is_clb(e)]
        cur.extend(entries)
        target[ev] = cur
    return target

# 兼容两种 schema：新版 {"hooks": {...}} 与旧版扁平 {event: [...]}
HOOK_EVENTS = ("beforeShellExecution","beforeMCPExecution","preToolUse","afterAgentResponse","stop")
new_schema = isinstance(doc.get("hooks"), dict) or not any(k in doc for k in HOOK_EVENTS)

if os.path.exists(path):
    ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = f"{path}.bak.{ts}"
    with open(backup, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=2, ensure_ascii=False)
    print(f"  ✓ 已备份原 hooks.json → {backup}")

if new_schema:
    doc.setdefault("version", 1)
    inner = doc.get("hooks")
    doc["hooks"] = merge_events(inner if isinstance(inner, dict) else {})
else:
    doc = merge_events(doc)

os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
with open(path, "w", encoding="utf-8") as f:
    f.write(json.dumps(doc, indent=2, ensure_ascii=False) + "\n")
print(f"  ✓ 已合并 cursor-lark-bridge hook 到 {path}")
MERGE_PY

# ---------------------------------------------------------------------------
# 4. 完成提示 + 反向隧道说明
# ---------------------------------------------------------------------------
echo ""
c_green "════════════════════════════════════════════════════════════"
c_green "  远程 hook 安装完成 ✓"
c_green "════════════════════════════════════════════════════════════"
echo ""
echo "下一步（关键）：建立 SSH 反向隧道，把远程的 127.0.0.1:$DAEMON_PORT"
echo "转发回你【本机】运行的 daemon。在你本机的 ~/.ssh/config 里，给这台"
echo "服务器的条目加一行："
echo ""
c_cyan "    RemoteForward $DAEMON_PORT 127.0.0.1:$DAEMON_PORT"
echo ""
echo "然后在 Cursor 里【重新连接】这台服务器（断开重连让隧道生效）。"
echo ""
echo "验证隧道是否通（在远程服务器终端执行）："
c_cyan "    curl -s http://127.0.0.1:$DAEMON_PORT/health"
echo "  能返回内容 = 隧道已通；连接被拒 = 隧道没建或本机 daemon 没开。"
echo ""
echo "别忘了：本机要先 fb start 激活远程模式，飞书才会收到卡片。"
