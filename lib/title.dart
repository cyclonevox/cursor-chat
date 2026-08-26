final _junkTitle = RegExp(
  r'assistant|response\s*logic|tool[_\s-]?call|thinking process|system prompt|untitled|undefined|null\b|handler|function call',
  caseSensitive: false,
);

bool isUsableTitle(String raw) {
  final t = raw.trim();
  if (t.isEmpty || t == '新对话') return false;
  if (_junkTitle.hasMatch(t)) return false;
  if (t.length > 48 && !RegExp(r'[\u4e00-\u9fff]').hasMatch(t)) return false;
  return true;
}

String conversationTitle(String userText, {String? agentName}) {
  if (agentName != null && isUsableTitle(agentName)) {
    return clipTitle(agentName.trim());
  }
  return clipTitle(summarizeUserText(userText));
}

String summarizeUserText(String text) {
  var t = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (t.isEmpty || t == '（图片）') return '看图提问';
  final cut = RegExp(r'[。？！?\n]').firstMatch(t);
  if (cut != null && cut.start >= 4 && cut.start <= 36) {
    t = t.substring(0, cut.start);
  }
  return t;
}

String clipTitle(String text) {
  final t = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (t.length <= 22) return t;
  return '${t.substring(0, 22)}…';
}

String recencyPreamble() {
  const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
  final now = DateTime.now();
  final wd = weekdays[now.weekday - 1];
  String two(int n) => n.toString().padLeft(2, '0');
  return '【当前时间：${now.year}-${two(now.month)}-${two(now.day)} 周$wd '
      '${two(now.hour)}:${two(now.minute)}。'
      '涉及新闻、版本号、价格、政策、文档、接口时，必须按这个时间检索最新来源；'
      '不要用过时结论，若不确定请写明资料日期。】\n\n';
}
