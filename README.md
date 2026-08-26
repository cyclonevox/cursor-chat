# Cursor Chat

自用的 ChatGPT 式客户端，走 Cursor Cloud Agents HTTP API。文字、相册、拍照都可以，不绑仓库。

## 功能

- 设置里粘贴 [API Key](https://cursor.com/dashboard/api)
- 会话列表（每条对话对应一个 Cloud Agent）
- 发文字 / 相册图 / 拍照（安卓）
- 同一条对话里继续问
- 记录只存在本机

## 电脑上调试

```bash
cd ~/dev/cursor-chat
flutter run -d linux
```

Linux 没有相机按钮，用相册/文件选择加图。

## 装到手机

```bash
flutter build apk --release
# 产物：build/app/outputs/flutter-apk/app-release.apk
```

手机打开 App → 设置 → 填 Key → 保存。账号需要能创建 **no-repo** Cloud Agent。
