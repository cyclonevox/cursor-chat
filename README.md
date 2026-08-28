# Cursor Chat

**A temporary way to chat with Cursor on Android (and Linux). Not an equivalent substitute for Cursor iOS.**

Cursor ships a native [iOS app](https://cursor.com/blog/ios-mobile-app). There is still no official Android client, and the web UI is awkward on a phone. This unofficial Flutter app wraps the **Cloud Agents API** as a chat screen: paste an API key and talk to **no-repo** agents. Repos, PRs, Live Activities, voice, MCP, remote desktop control, and the rest of that iOS surface are **not here for now**.

**这是方便安卓端进行 Cursor 对话的临时方案（Linux 也能跑），不是 Cursor iOS 的等价替代品。** 官方有 iOS，没有安卓，网页版不好用，所以用 Cloud Agents API 自己接了一层聊天界面。仓库、PR、Live Activity、语音、MCP、远程控制桌面会话等，这里暂时都还没有。

> Unofficial. Not affiliated with Anysphere / Cursor. You need your own [API key](https://cursor.com/dashboard/api), and an account that can create **no-repo** Cloud Agents.
>
> 非官方，与 Anysphere / Cursor 无关。需要自己的 [API Key](https://cursor.com/dashboard/api)，账号还得能创建**不绑仓库**的 Cloud Agent。

## Download / 下载

CI builds **one** APK on every push and pull request. It is **not** published to GitHub Releases.

每次推送或开 PR 都会打 **一个** APK，挂在这次 CI 的 Artifacts 里，**不会**发到 GitHub Releases。

1. Open the run under [Actions](https://github.com/cyclonevox/cursor-chat/actions)
2. Download the `cursor-chat` artifact (GitHub login required) and unzip it
3. Install `cursor-chat.apk` (allow unknown sources). Then Settings → paste your API key.

1. 打开 [Actions](https://github.com/cyclonevox/cursor-chat/actions) 里对应那次运行
2. 下载 Artifacts 里的 `cursor-chat`（需要登录 GitHub）并解压
3. 安装 `cursor-chat.apk`（允许未知来源），然后到设置里粘贴 API Key

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

## Requirements / 环境

- [Flutter](https://flutter.dev) 3.44+ (Dart 3.12)
- A Cursor account with Cloud Agents API access / 能用 Cloud Agents API 的 Cursor 账号
- Android: SDK for `flutter build apk`
- Linux: GTK desktop target (`flutter run -d linux`)

## Get an API key / 获取 API Key

1. Open [cursor.com/dashboard/api](https://cursor.com/dashboard/api)
2. Create a key (`cursor_…`)
3. In the app: **Settings → paste key → Save**
4. Models load automatically. Start a new chat after changing model or params.

1. 打开 [cursor.com/dashboard/api](https://cursor.com/dashboard/api)
2. 创建密钥（`cursor_…`）
3. 应用里：**设置 → 粘贴密钥 → 保存**
4. 模型会自动拉取。改模型或参数后请开新对话。

## Install on Android / 本机打 APK

```bash
git clone https://github.com/cyclonevox/cursor-chat.git
cd cursor-chat
flutter pub get
flutter build apk --release
```

APK path / 产出路径：`build/app/outputs/flutter-apk/app-release.apk`

If `android/key.properties` is present, release builds use that upload keystore so later APKs can overwrite-install. Otherwise the APK is debug-signed.

若有 `android/key.properties`，release 会用上传密钥签名，方便以后覆盖安装；否则是 debug 签名。

## Run on Linux (debug) / Linux 调试

```bash
flutter run -d linux
```

Linux has no camera button; attach images with the gallery / file picker.

Linux 没有相机按钮，用相册 / 文件选择器附图。

## How it works / 原理

Cursor does not expose a Chat Completions API. This app **reuses Cloud Agents**: each sidebar chat is one durable agent, each send is a run.

Cursor 没有 Chat Completions API。这个应用**复用 Cloud Agents**：侧栏里每条对话是一个长期 Agent，每次发送是一次 run。

```
phone  →  POST /v1/agents          (first turn, no repository field)
       →  POST /v1/agents/{id}/runs  (follow-up)
       →  GET  …/runs/{id}/stream    (SSE; 410 / dropped socket → poll GET)
```

The first prompt is not what you typed. The client prepends a system-style prefix (`kFirstTurnPrefix` in `lib/api/cursor_api.dart`) that tells the agent it is a phone assistant, plus a clock / `recencyPreamble` that asks it to search the web for versions, news, and prices. Follow-ups only add the recency line.

第一条提示词不是你打的原文。客户端会加上系统式前缀（`lib/api/cursor_api.dart` 里的 `kFirstTurnPrefix`），告诉 Agent 它是手机助手，再加一段时钟 / `recencyPreamble`，让它去网上搜版本、新闻和价格。追问只加时效那一行。

API key: `SharedPreferences`. Threads: `conversations.json` in app documents. Images: base64 on the prompt, max 12 MB. Cloud-side, Cursor still stores the agent; deleting a chat here does not delete the agent on their servers.

API Key 存在 `SharedPreferences`。会话在应用文档目录的 `conversations.json`。图片以 base64 附在提示词上，最大 12 MB。云端 Cursor 仍会保存 Agent；这里删对话不会删他们服务器上的 Agent。

## Limitations / 局限性

This is the important part. The UI looks like ChatGPT. The backend is a **coding-agent API** used off-label.

界面看起来像 ChatGPT，后台其实是拿**编程 Agent API** 来聊天。

**Not a chat model API.** Cloud Agents are built to work on repos, tools, PRs, and VMs. We omit `repository` so the account must allow **no-repo** agents. If create fails, the account probably cannot do that. There is no guarantee Cursor will keep no-repo agents.

**不是聊天模型 API。** Cloud Agents 是给仓库、工具、PR、虚拟机用的。我们不传 `repository`，所以账号必须允许**不绑仓库**的 Agent。创建失败多半是账号没这个权限。Cursor 会不会一直提供不绑仓库的 Agent，没有保证。

**Steering is just extra prompt text.** “Don’t open a PR / don’t dump code” is a prefix, not a product mode. The agent can still reach for tools, talk like an IDE assistant, or ignore the prefix. It is not ChatGPT, Claude.ai, or Cursor Tab.

**「别乱开 PR」只是提示词。** 不是官方聊天模式。Agent 仍可能调用工具、像 IDE 助手那样说话、或忽略前缀。这不是 ChatGPT、Claude.ai，也不是 Cursor Tab。

**Web-freshness is hoped, not guaranteed.** We inject today’s datetime and ask it to search. Whether it actually searches, and whether that search is current, is entirely Cursor’s runtime.

**网上新信息不保证。** 我们会塞进今天的日期并请它搜索。它搜不搜、搜到的新不新，全看 Cursor 运行时。

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

**Billing is Cloud Agents, not “chat.”** Usage follows Cursor API / Cloud Agent pricing and spend limits. A long “casual” thread can still be an expensive agent. Unofficial client: if the v1 API moves, this app breaks until we catch up.

**计费按 Cloud Agents，不是「聊天」。** 用量走 Cursor API / Cloud Agent 定价和额度。闲聊长对话也可能很贵。非官方客户端：v1 API 一变，这个应用就会坏，直到跟上。

**iOS features are not here for now.** The iOS app is a first-party agent control surface: repos, plans, diffs, merge, Live Activities, voice, MCP, screenshot annotation, remote control. This client is a thin chat wrapper around `POST /v1/agents` without a repository. Same company API, different product. Don’t expect those surfaces here yet.

**iOS 上那些能力暂时都还没有。** 官方 iOS 是第一方的 Agent 控制面：仓库、计划、diff、合并、Live Activity、语音、MCP、截图标注、远程控制。这个客户端只是对不绑仓库的 `POST /v1/agents` 包了一层聊天界面。同一家公司的 API，不是同一个产品。先别按「安卓上的 Cursor iOS」来预期。

**Frost is cosmetic.** Bars use Flutter `BackdropFilter` over the transcript (niri-like). That is not the compositor blurring your wallpaper through a transparent window.

**毛玻璃只是外观。** 顶栏底栏用 Flutter `BackdropFilter` 模糊对话（有点像 niri）。并不是合成器透过透明窗口去糊壁纸。

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

Unofficial temporary client. Not affiliated with Anysphere / Cursor, and **not an equivalent to Cursor for iOS**. Cursor, Cloud Agents, and related marks belong to their owners. Using the API is subject to Cursor’s terms and billing.

非官方临时方案。与 Anysphere / Cursor 无关，也**不是** Cursor iOS 的等价替代。Cursor、Cloud Agents 及相关标识归其权利人所有。使用 API 须遵守 Cursor 的条款和计费。
