# Cursor Chat

**A simple Cursor chat client for Android.**

Paste an API key and talk to **no-repo** Cloud Agents.

**简易的 Cursor 对话安卓客户端。** 设置里粘贴 API Key，就能和不绑仓库的 Cloud Agent 聊天。

> Unofficial. Not affiliated with Anysphere / Cursor. You need your own [API key](https://cursor.com/dashboard/api), and an account that can create **no-repo** Cloud Agents.
>
> 非官方，与 Anysphere / Cursor 无关。需要自己的 [API Key](https://cursor.com/dashboard/api)，账号还得能创建**不绑仓库**的 Cloud Agent。

## Features / 功能

- Paste an API key in Settings; it stays on the device.
设置里粘贴 API Key，只留在本机。
- Conversation list — each chat is one Cloud Agent.
会话列表，每条对话对应一个 Cloud Agent。
- Text, gallery images, and camera (Android).
文字、相册图片；安卓可用相机。
- Follow-ups in the same thread; retry if the network drops.
同一线程里追问；断网可重试。
- Model picker + Fast / thinking params from the live catalog.
模型选择，以及在线目录里的 Fast / 思考参数。
- Markdown / math in replies.
回复支持 Markdown / 公式。
- History stored locally, not in this repo.
历史存在本地，不进这个仓库。



## How it works / 原理

Cursor does not expose a Chat Completions API. This app **reuses Cloud Agents**: each sidebar chat is one durable agent, each send is a run.

Cursor 没有 Chat Completions API。这个应用**复用 Cloud Agents**：侧栏里每条对话是一个长期 Agent，每次发送是一次 run。

```
phone  →  POST /v1/agents          (first turn, no repository field)
       →  POST /v1/agents/{id}/runs  (follow-up)
       →  GET  …/runs/{id}/stream    (SSE; 410 / dropped socket → poll GET)
```

Images: base64 on the prompt, max 12 MB. Cloud-side, Cursor still stores the agent; deleting a chat here does not delete the agent on their servers.

图片以 base64 附在提示词上，最大 12 MB。云端 Cursor 仍会保存 Agent；这里删对话不会删他们服务器上的 Agent。

## Limitations / 局限性

This is the important part. The UI looks like ChatGPT. The backend is a **coding-agent API** used off-label.

界面看起来像 ChatGPT，后台其实是拿**编程 Agent API** 来聊天。

**Not a chat model API.** Cloud Agents are built to work on repos, tools, PRs, and VMs. We omit `repository` so the account must allow **no-repo** agents. If create fails, the account probably cannot do that. There is no guarantee Cursor will keep no-repo agents.

**不是聊天模型 API。** Cloud Agents 是给仓库、工具、PR、虚拟机用的。我们不传 `repository`，所以账号必须允许**不绑仓库**的 Agent。创建失败多半是账号没这个权限。Cursor 会不会一直提供不绑仓库的 Agent，没有保证。

**One agent ≈ one model.** Model / Fast / thinking are sent on **create**. Changing settings does not rewrite an existing thread. Open a new chat after switching. There is no UI to stop a run (`cancelRun` exists in the client, unused).

**一个 Agent ≈ 一个模型。** 模型 / Fast / 思考参数只在**创建**时发送。改设置不会改已有对话。换完请开新聊天。没有停止 run 的界面（客户端里有 `cancelRun`，没用上）。

**Follow-up is another run, not a local context window you control.** Cursor keeps agent memory on their side. If the follow-up cannot attach (404, dead agent, some network loss), we **rebuild the thread as one prompt** (`conversationContinuityPrompt`): assistant turns clipped at 4 000 characters, error bubbles dropped. Long chats lose detail; a “continued” chat may be a **new** agent.

**追问是再开一次 run，不是你能控制的本地上下文窗口。** Agent 记忆在 Cursor 那边。追问接不上时（404、Agent 没了、部分断网），会把本地记录裁成一条提示词再开（`conversationContinuityPrompt`）：助手回复截到 4000 字，错误气泡丢掉。长对话会丢细节；所谓「继续」可能是一个**新** Agent。

**Streaming is best-effort.** SSE can return 410 (`stream_unavailable`) if we subscribe late. Android may drop the socket in the background; we then poll. You can get a finished answer with no live tokens, a retry that pulls an already-finished run, or a duplicate-looking turn. Not a desktop-grade socket.

**流式是尽力而为。** 订阅晚了 SSE 可能返回 410（`stream_unavailable`）。安卓在后台可能丢掉套接字，然后改轮询。可能直接拿到已完成的回答、重试拉到已经结束的 run、或看起来像重复的一轮。不是桌面级长连接。

**Local list ≠ cloud source of truth.** History is this device only. Reinstall / new phone = empty sidebar; old agents may still exist (and bill) on Cursor. No sync, export, or “delete on server”.

**本地列表不是云端真相。** 历史只在这台设备。重装 / 换手机侧栏是空的；旧 Agent 可能还在 Cursor 上（也还可能计费）。没有同步、导出、或「在服务器上删除」。

**Images are attachments on a prompt, not a vision product.** Gallery / camera (Android) or file picker (Linux). No annotation like Cursor iOS. Large photos are rejected at 12 MB.

**图片只是提示词上的附件，不是视觉产品。** 安卓用相册 / 相机，Linux 用文件选择器。没有 Cursor iOS 那种标注。超过 12 MB 的照片会被拒。

**iOS features are not here for now.** The iOS app is a first-party agent control surface: repos, plans, diffs, merge, Live Activities, voice, MCP, screenshot annotation, remote control. This client is a thin chat wrapper around `POST /v1/agents` without a repository. Same company API, different product. Don’t expect those surfaces here yet.

**iOS 上那些能力暂时都还没有。** 官方 iOS 是第一方的 Agent 控制面：仓库、计划、diff、合并、Live Activity、语音、MCP、截图标注、远程控制。这个客户端只是对不绑仓库的 `POST /v1/agents` 包了一层聊天界面。同一家公司的 API，不是同一个产品。先别按「安卓上的 Cursor iOS」来预期。

## Development / 开发

```bash
flutter test
dart analyze
```

Optional live smoke (does not print the key) / 可选的在线冒烟（不会打印密钥）：

```bash
CURSOR_API_KEY=cursor_… dart run tool/live_qa.dart
```



## License / 许可

[MIT](LICENSE)

## Disclaimer / 免责声明

Unofficial. Not affiliated with Anysphere / Cursor. Cursor, Cloud Agents, and related marks belong to their owners. Using the API is subject to Cursor’s terms and billing.

非官方。与 Anysphere / Cursor 无关。Cursor、Cloud Agents 及相关标识归其权利人所有。使用 API 须遵守 Cursor 的条款和计费。