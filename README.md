# Cursor Chat

非官方的 Cursor 对话客户端（Android / Linux）。设置里贴 API Key 就能聊。

Cursor 没有普通聊天 API，只能开 Cloud Agent。每只 Agent 同时只能跑一轮，云端记忆也清不掉。所以：

- **快速对话**共用一只 Agent。侧栏这一组下面是一堆独立话题；标题上的 + 只换话题，用提示词隔开，折叠可以把话题收起来。
- **独立 Agent** 是另一组。那边标题上的 + 才真正再开一只，用来隔离或换模型。
- 右上角只有一个按钮：在快速对话里是「新对话」，在独立 Agent 里是「新开 Agent」。
- 删隔离对话会一并删云端 Agent，避免越积越多撞上限。设置里也能看到并删除云端残留。

回复中可以继续打字：发送会排队，停止会取消当前这一轮，长按发送会停掉再立刻问。

```
日常话题  →  POST /v1/agents（第一次）→ 之后都是 /runs
独立 Agent 的 + → 再 POST /v1/agents
```

非官方，与 Anysphere / Cursor 无关。需要自己的 [API Key](https://cursor.com/dashboard/api)，账号还得能创建不绑仓库的 Cloud Agent。使用须遵守 Cursor 的条款和计费。

```bash
flutter test
dart analyze
```
