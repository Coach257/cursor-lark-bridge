# 飞书开放平台配置（Windows / 通用）

桥接器用 `lark-cli event +subscribe` **长连接**收事件，不是 HTTP Webhook。文字消息和卡片按钮走**两条不同的后台入口**，只配其一会出现「能收字、点按钮报 200340」。

## 1. 事件订阅（文字消息 → Cursor）

路径：**开发者后台 → 你的应用 → 事件与回调 → 事件订阅**

| 项 | 要求 |
|---|---|
| 接收方式 | **长连接**（与 `lark-cli` 一致；不要填 Webhook URL） |
| 已订阅事件 | `im.message.receive_v1` |

配好后，你在单聊里发的文字可以进 daemon，再转给 Cursor。

## 2. 回调配置（卡片按钮 → daemon）

路径：**开发者后台 → 你的应用 → 事件与回调 → 回调配置**（不是「事件订阅」页）

| 项 | 要求 |
|---|---|
| 接收方式 | **长连接** |
| 已订阅回调 | `card.action.trigger` |

同时在 **应用功能 → 机器人** 打开 **「卡片回传交互 / Interactive Card」**。

> 常见坑：只在「事件订阅」里加了 `card.action.trigger`，但按钮回调必须在 **「回调配置」** 页单独走长连接，否则客户端报 **200340**（应用未配置卡片回调地址或地址无效）。

## 3. 发布版本

改完权限 / 事件 / 回调后，在 **版本管理与发布** 创建并**发布**新版本，配置才会线上生效。

## 4. 验证

```powershell
fb start
fb status    # 事件订阅应为「正常」
```

在飞书对 bot 发一条会触发 Agent 的消息，等暂停卡片出现后：

- 点 **▶️ 继续执行** / **🛑 结束会话** 应不再报 200340
- 若仍报错，看 `~/.cursor/cursor-lark-bridge/logs/daemon-*.log`

## 5. 按钮未配好时的临时做法

文字走事件通道，仍可用：

| 操作 | 效果 |
|---|---|
| 发文字 `skip` | 结束当前这轮 stop 等待（≈ 点「结束会话」） |
| `/stop` 或 `/停止` | 批量取消所有 pending |

多开 Cursor 窗口时：**用卡片上的按钮**（带 `request_id`）精确控制；**不要用文字**指定某个窗口（文字是 FIFO，会派给等待最久的那条）。

用 `/status` 或 `/状态` 查看当前所有挂起的 agent（含 workspace、等待时长、Agent 标识）。

## 6. 与本机安装的关系

```powershell
# 安装 / 更新 hook + daemon
powershell -ExecutionPolicy Bypass -File install-windows.ps1

fb init
fb start
```

Hook 与 daemon 只负责把 Cursor 和飞书连起来；**200340 必须在飞书后台按上文第 2 节配好**，代码无法代替。
