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

bool looksLikeQuestion(String raw) {
  final t = raw.trim();
  if (t.contains('？') || t.contains('?')) return true;
  if (RegExp(r'(吗|呢)$').hasMatch(t)) return true;
  if (RegExp(r'为(什么|啥|何)').hasMatch(t)) return true;
  if (RegExp(r'(怎么|如何|怎样)').hasMatch(t)) return true;
  if (RegExp(r'是(多少|什么|啥|星期几)$').hasMatch(t)) return true;
  if (RegExp(
    r"^(what|what's|whats|how|why|when|where|who)\b",
    caseSensitive: false,
  ).hasMatch(t)) {
    return true;
  }
  return false;
}

/// Sidebar label for a chat: a short topic, never the raw user question.
String conversationTitle(
  String userText, {
  String? assistantText,
  String? agentName,
}) {
  final fromUser = topicFromUser(userText);
  final fromAsst = topicFromAssistant(assistantText ?? '') ?? '';
  final fromAgent = (agentName != null && isUsableTitle(agentName))
      ? clipTitle(agentName.trim())
      : '';
  final raw = userText.trim();

  bool ok(String s) =>
      s.isNotEmpty &&
      s != '新对话' &&
      isUsableTitle(s) &&
      !looksLikeQuestion(s) &&
      s != raw;

  if (fromUser.contains(RegExp(r'的(原因|做法|方法|修法)$')) && ok(fromUser)) {
    return clipTitle(fromUser);
  }
  if (ok(fromAsst)) return clipTitle(fromAsst);
  if (ok(fromUser)) return clipTitle(fromUser);
  if (ok(fromAgent)) return clipTitle(fromAgent);
  if (fromUser.isNotEmpty && fromUser != '新对话') {
    return clipTitle(_stripQuestionSurface(fromUser));
  }
  return '新对话';
}

/// Turn a question into a short sidebar topic, not a copy of the question.
String summarizeUserText(String text) => topicFromUser(text);

String topicFromUser(String text) {
  var t = text.replaceAll(RegExp(r'[\s\u3000]+'), ' ').trim();
  if (t.isEmpty || t == '（图片）') return '看图提问';

  final cut = RegExp(r'[。？！?\n；;]').firstMatch(t);
  if (cut != null && cut.start >= 2) {
    t = t.substring(0, cut.start);
  }

  const wrappers = [
    r'^(请用|用)?中文(一两句|简要|详细)?(话)?(来)?(回答|解释|说明)[：:]\s*',
    r'^(那|然后|还有|另外)?(请你?|请问|麻烦你?|帮我|我想问一下?|问一下|能不能|可以)(帮我)?(看看|看一下|讲一下|解释一下|说一下)?',
    r'^我想要\s*',
    r'^(那|然后|还有|另外)[，,]?',
    r'^现在[，,]?',
    r'^(please\s+)?(explain|tell me|help me)\s+',
  ];
  for (final p in wrappers) {
    t = t.replaceFirst(RegExp(p, caseSensitive: false), '');
  }
  t = t.replaceAll(RegExp(r'[（(][^)）]{0,24}[)）]'), '');
  t = t.trim();
  final colon = RegExp(r'[：:]').firstMatch(t);
  if (colon != null && colon.start >= 2) {
    t = t.substring(0, colon.start);
  }

  t = t.replaceAll(RegExp(r'(到底|究竟)'), '');
  t = t.replaceFirst(
    RegExp(r"^(what is|what's|whats)\s+", caseSensitive: false),
    '',
  );
  t = t.replaceFirst(
    RegExp(r'^(how (do i|to|can i))\s+', caseSensitive: false),
    '',
  );

  final whatIsPrefix = RegExp(r'^什么是\s*(.+)').firstMatch(t);
  if (whatIsPrefix != null) {
    return clipTitle(whatIsPrefix.group(1)!.trim());
  }

  final whatIsSuffix = RegExp(r'^(.+?)是(什么|啥)$').firstMatch(t);
  if (whatIsSuffix != null) {
    return clipTitle(whatIsSuffix.group(1)!.trim());
  }

  t = t.replaceFirst(RegExp(r'(的)?版本号是多少$'), '');

  final weekday = RegExp(r'^(.+?)是星期几$').firstMatch(t);
  if (weekday != null) {
    return clipTitle('${weekday.group(1)!.trim()}星期');
  }

  final howMuch = RegExp(r'^(.+?)是多少$').firstMatch(t);
  if (howMuch != null) {
    return clipTitle(howMuch.group(1)!.trim());
  }

  final why = RegExp(r'^(.*?)为(什么|啥|何)(要|会|是|得|又)?(.*)$').firstMatch(t);
  if (why != null) {
    final left = why.group(1)!.trim();
    final right = why.group(4)!.trim();
    var core = right.isNotEmpty ? (left.isEmpty ? right : '$left$right') : left;
    core = _dropWeakPrefix(core);
    if (core.isNotEmpty) return clipTitle(_withSuffix(core, '的原因'));
  }

  final how = RegExp(
    r'^(.*?)(怎么|如何|怎样)(样)?(做|弄|办|修|改|解决|理解|算)?(.*)$',
  ).firstMatch(t);
  if (how != null) {
    final left = _dropWeakPrefix(how.group(1)!.trim());
    final verb = how.group(4) ?? '';
    final right = how.group(5)!.trim();
    if (left.isNotEmpty) {
      if (verb == '修') return clipTitle(_withSuffix(left, '的修法'));
      if (verb.isNotEmpty) return clipTitle(_withSuffix(left, '的做法'));
      return clipTitle(left);
    }
    if (right.isNotEmpty) {
      return clipTitle(_withSuffix(_dropWeakPrefix(right), '的做法'));
    }
  }

  t = t.replaceAll(RegExp(r'[吗呢呀啊嘛]+$'), '');
  t = t.replaceAll(RegExp(r'[，,、.：:]+$'), '');
  t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
  t = t.replaceFirst(RegExp(r'^的'), '');
  t = _dropWeakPrefix(t);

  if (t.isEmpty) return '新对话';
  return clipTitle(_stripQuestionSurface(t));
}

String? topicFromAssistant(String text) {
  var t = text.trim();
  if (t.isEmpty ||
      t == '（没有文字回复）' ||
      t.startsWith('出错了：') ||
      t.startsWith('运行结束：') ||
      t.startsWith('网络中断')) {
    return null;
  }

  final heading = RegExp(r'^#{1,3}\s+(.+)$', multiLine: true).firstMatch(t);
  if (heading != null) {
    final h = _stripMd(heading.group(1)!);
    if (h.isNotEmpty && !looksLikeQuestion(h) && isUsableTitle(h)) {
      return clipTitle(h);
    }
  }

  t = t.replaceFirst(RegExp(r'^[#>*\-\s]+'), '');
  final nl = t.indexOf('\n');
  if (nl > 2 && nl < 48) t = t.substring(0, nl);
  final sent = RegExp(r'[。！]').firstMatch(t);
  if (sent != null && sent.start >= 2 && sent.start <= 36) {
    t = t.substring(0, sent.start);
  }
  t = _stripMd(t);

  final def = RegExp(r'^(.{2,20}?)(是指|指的是|是一种|是一个|意思是)').firstMatch(t);
  if (def != null) {
    final s = def.group(1)!.trim();
    if (s.isNotEmpty && !looksLikeQuestion(s) && isUsableTitle(s)) {
      return clipTitle(s);
    }
  }
  return null;
}

String _stripMd(String t) =>
    t.replaceAll(RegExp(r'[*_`#]+'), '').replaceAll(RegExp(r'\s+'), ' ').trim();

String _dropWeakPrefix(String t) {
  return t.replaceFirst(RegExp(r'^(这题|这道题|这个问题|题目|该题)'), '').trim();
}

String _withSuffix(String core, String suffix) {
  if (core.endsWith(suffix) || core.endsWith(suffix.substring(1))) return core;
  return '$core$suffix';
}

String _stripQuestionSurface(String t) {
  var s = t.replaceAll(RegExp(r'[？?]+'), '');
  s = s.replaceAll(RegExp(r'[吗呢呀啊嘛]+$'), '').trim();
  return s.isEmpty ? t : s;
}

String clipTitle(String text) {
  final t = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  final latin =
      RegExp(r'[A-Za-z]').hasMatch(t) &&
      !RegExp(r'[\u4e00-\u9fff]').hasMatch(t);
  if (latin) {
    final words = t.split(' ').where((w) => w.isNotEmpty).toList();
    if (words.length <= 5) return t;
    return '${words.take(5).join(' ')}…';
  }
  if (t.length <= 14) return t;
  return '${t.substring(0, 14)}…';
}

String recencyPreamble({bool followUp = false}) {
  const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
  final now = DateTime.now();
  final wd = weekdays[now.weekday - 1];
  String two(int n) => n.toString().padLeft(2, '0');
  final stamp =
      '${now.year}-${two(now.month)}-${two(now.day)} 周$wd ${two(now.hour)}:${two(now.minute)}';
  if (followUp) {
    return '[$stamp] 若本轮涉及版本、新闻、价格、政策或文档，按此时联网查；'
        '查不到就说不确定，不要用过时记忆凑数。\n\n';
  }
  return '现在是 $stamp。'
      '凡是版本号、新闻、价格、政策、接口、文档，必须按这个时间联网检索后再答。'
      '搜不到或对不上今天，就直接说不确定，不要猜旧数据。\n\n';
}
