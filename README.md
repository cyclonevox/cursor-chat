# Cursor Chat

Unofficial Flutter client for the [Cursor Cloud Agents API](https://cursor.com/docs/cloud-agent/api/endpoints). ChatGPT-style chat on **Android** and **Linux** — no repo binding, no IDE.

Cursor still has no Android app, only a browser. This is a native client for that gap: paste an API key, talk, send photos, continue the same thread.

非官方 Flutter 客户端，走 [Cursor Cloud Agents HTTP API](https://cursor.com/docs/cloud-agent/api/endpoints)。Cursor 一直没有安卓端，只有浏览器；这个应用把同一套云端对话接到手机上。

> Not affiliated with Anysphere / Cursor. You need your own [Cursor API key](https://cursor.com/dashboard/api), and an account that can create **no-repo** Cloud Agents.

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

The app talks to `https://api.cursor.com`:

- `GET /v1/models` — catalog and parameters
- `POST /v1/agents` — new chat (no repository)
- `POST /v1/agents/{id}/runs` — follow-up
- SSE stream on the run, with HTTP poll fallback

API key and conversations live in app storage (`SharedPreferences` + a local JSON file). Nothing is uploaded except the prompts you send to Cursor.

## Development

```bash
flutter test
dart analyze
```

Optional live smoke (does not print the key):

```bash
CURSOR_API_KEY=cursor_… dart run tool/live_qa.dart
```

## 中文摘要

Cursor 没有安卓 App，网页版用起来别扭。这个仓库是一个 ChatGPT 式的原生客户端：设置里粘贴 [API Key](https://cursor.com/dashboard/api)，就可以在手机上开对话、发图、拍照、继续追问。每条会话对应一个不绑仓库的 Cloud Agent；Key 和聊天记录只存在本机。

直接装：[Releases](https://github.com/cyclonevox/cursor-chat/releases/latest) 里的 `cursor-chat.apk`。合并进 `main` 会自动打包。

```bash
flutter build apk --release
# build/app/outputs/flutter-apk/app-release.apk
```

## License

[MIT](LICENSE)

## Disclaimer

This project is unofficial. Cursor, Cloud Agents, and related marks belong to their owners. Using the API is subject to Cursor’s terms and billing.
