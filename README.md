# Cursor Chat

**A stopgap for Android (and Linux), not Cursor for iOS.**

Cursor ships a native [iOS app](https://cursor.com/blog/ios-mobile-app). There is still no Android client—only the browser. This unofficial Flutter app is a **temporary workaround**: paste an API key and talk to **no-repo Cloud Agents** from your phone. It is **not** an equivalent substitute for Cursor iOS (or desktop, or cursor.com/agents).

When Cursor releases an official Android app, use that. This project does not aim to clone iOS feature-for-feature.

**这是方便安卓端进行 Cursor 对话的临时方案，不是 Cursor iOS 的等价替代品。** 官方有 iOS，没有安卓，网页版不好用，所以用 Cloud Agents API 自己接了一层聊天界面。仓库、PR、Live Activity、语音、MCP、远程控制桌面会话等，这里都没有，也不会做成「安卓版 Cursor」。

> Unofficial. Not affiliated with Anysphere / Cursor. You need your own [API key](https://cursor.com/dashboard/api), and an account that can create **no-repo** Cloud Agents.

## Download

Latest APK (built automatically when `main` is updated):

**https://github.com/cyclonevox/cursor-chat/releases/latest/download/cursor-chat.apk**

On Android, allow installing from the browser / GitHub. Then Settings → paste your API key.

合并进 `main` 后，GitHub Actions 会跑测试、打 release APK，并发布到 [Releases](https://github.com/cyclonevox/cursor-chat/releases/latest)。

## Features

- Paste an API key in Settings; it stays on the device
- Conversation list — each chat is one Cloud Agent
- Text, gallery images, and camera (Android)
- Follow-ups in the same thread; retry if the network drops
- Model picker + Fast / thinking params from the live catalog
- Markdown / math in replies
- History stored locally, not in this repo

## Requirements

- [Flutter](https://flutter.dev) 3.44+ (Dart 3.12)
- A Cursor account with Cloud Agents API access
- Android: SDK for `flutter build apk`
- Linux: GTK desktop target (`flutter run -d linux`)

## Get an API key

1. Open [cursor.com/dashboard/api](https://cursor.com/dashboard/api)
2. Create a key (`cursor_…`)
3. In the app: **Settings → paste key → Save**
4. Models load automatically. Start a new chat after changing model or params.

## Install on Android

```bash
git clone https://github.com/cyclonevox/cursor-chat.git
cd cursor-chat
flutter pub get
flutter build apk --release
```

APK path: `build/app/outputs/flutter-apk/app-release.apk`

If `android/key.properties` (or the matching GitHub Actions secrets) is present, release builds use that upload keystore so later APKs can overwrite-install. Otherwise CI signs with the debug key.

## Run on Linux (debug)

```bash
flutter run -d linux
```

Linux has no camera button; attach images with the gallery / file picker.

## How it works

Cursor does not expose a Chat Completions API. This app **reuses Cloud Agents**: each sidebar chat is one durable agent, each send is a run.

```
phone  →  POST /v1/agents          (first turn, no repository field)
       →  POST /v1/agents/{id}/runs  (follow-up)
       →  GET  …/runs/{id}/stream    (SSE; 410 / dropped socket → poll GET)
```

The first prompt is not what you typed. The client prepends a system-style prefix (`kFirstTurnPrefix` in `lib/api/cursor_api.dart`) that tells the agent it is a phone assistant, plus a clock/`recencyPreamble` that asks it to search the web for versions, news, and prices. Follow-ups only add the recency line.

API key: `SharedPreferences`. Threads: `conversations.json` in app documents. Images: base64 on the prompt, max 12 MB. Cloud-side, Cursor still stores the agent; deleting a chat here does not delete the agent on their servers.

## Limitations / 局限性

This is the important part. The UI looks like ChatGPT. The backend is a **coding-agent API** used off-label.

**Not a chat model API.** Cloud Agents are built to work on repos, tools, PRs, and VMs. We omit `repository` so the account must allow **no-repo** agents. If create fails, the account probably cannot do that. There is no guarantee Cursor will keep no-repo agents.

**Steering is just extra prompt text.** “Don’t open a PR / don’t dump code” is a prefix, not a product mode. The agent can still reach for tools, talk like an IDE assistant, or ignore the prefix. It is not ChatGPT, Claude.ai, or Cursor Tab.

**Web-freshness is hoped, not guaranteed.** We inject today’s datetime and ask it to search. Whether it actually searches, and whether that search is current, is entirely Cursor’s runtime.

**One agent ≈ one model.** Model / Fast / thinking are sent on **create**. Changing settings does not rewrite an existing thread. Open a new chat after switching. There is no UI to stop a run (`cancelRun` exists in the client, unused).

**Follow-up is another run, not a local context window you control.** Cursor keeps agent memory on their side. If the follow-up cannot attach (404, dead agent, some network loss), we **rebuild the thread as one prompt** (`conversationContinuityPrompt`): assistant turns clipped at 4 000 characters, error bubbles dropped. Long chats lose detail; a “continued” chat may be a **new** agent.

**Streaming is best-effort.** SSE can return 410 (`stream_unavailable`) if we subscribe late. Android may drop the socket in the background; we then poll. You can get a finished answer with no live tokens, a retry that pulls an already-finished run, or a duplicate-looking turn. Not a desktop-grade socket.

**Local list ≠ cloud source of truth.** History is this device only. Reinstall / new phone = empty sidebar; old agents may still exist (and bill) on Cursor. No sync, export, or “delete on server”.

**Images are attachments on a prompt, not a vision product.** Gallery / camera (Android) or file picker (Linux). No annotation like Cursor iOS. Large photos are rejected at 12 MB.

**Billing is Cloud Agents, not “chat.”** Usage follows Cursor API / Cloud Agent pricing and spend limits. A long “casual” thread can still be an expensive agent. Unofficial client: if the v1 API moves, this app breaks until we catch up.

**Not Cursor for iOS — and not trying to be.** The iOS app is a first-party agent control surface: repos, plans, diffs, merge, Live Activities, voice, MCP, screenshot annotation, remote control. This client is a thin chat wrapper around `POST /v1/agents` without a repository. Same company API, different product. Do not install this expecting “Cursor iOS on Android.”

**Frost is cosmetic.** Bars use Flutter `BackdropFilter` over the transcript (niri-like). That is not the compositor blurring your wallpaper through a transparent window.

**Release APKs.** Merges to `main` build APKs on Actions. Without an upload keystore in secrets, the APK is **debug-signed**; later official-signed builds cannot overwrite-install.

## 中文摘要

这是**临时方案**：安卓上没有官方 Cursor，用 Cloud Agents HTTP API 凑合对话。**不是** Cursor iOS 的安卓移植，也不是桌面端/网页 Agents 的等价替代。官方一旦出安卓，应以官方为准。

实现上每条会话是一个不绑仓库的 Agent，每句发送是一次 run。开头会塞「当手机助手、别乱开 PR」的前缀和当前时间——都是提示词，不是官方聊天模式。换模型只对**新对话**生效。断线后可能 SSE 变成轮询，或把本地记录裁剪后塞进**新 Agent**。记录只在这台设备；删 App 不会删云端 Agent。费用按 Cloud Agents 计。

直接装：[Releases](https://github.com/cyclonevox/cursor-chat/releases/latest) 里的 `cursor-chat.apk`。合并进 `main` 会自动打包。限制见 **Limitations**。

## Development

```bash
flutter test
dart analyze
```

Optional live smoke (does not print the key):

```bash
CURSOR_API_KEY=cursor_… dart run tool/live_qa.dart
```

## License

[MIT](LICENSE)

## Disclaimer

Unofficial stopgap. Not affiliated with Anysphere / Cursor, and **not an equivalent to Cursor for iOS**. Cursor, Cloud Agents, and related marks belong to their owners. Using the API is subject to Cursor’s terms and billing.
