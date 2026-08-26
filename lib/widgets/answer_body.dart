import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

class AnswerBody extends StatelessWidget {
  const AnswerBody({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = text.trim();
    if (t.isEmpty) return const SizedBox.shrink();
    if (_looksLikeHtml(t)) {
      return Html(
        data: t,
        shrinkWrap: true,
        style: {
          'body': Style(
            margin: Margins.zero,
            padding: HtmlPaddings.zero,
            fontSize: FontSize(15.0),
          ),
        },
      );
    }
    return GptMarkdown(
      t,
      isStreaming: false,
      useDollarSignsForLatex: true,
      textDirection: Directionality.of(context),
    );
  }
}

bool _looksLikeHtml(String t) {
  final s = t.trimLeft();
  if (!s.startsWith('<')) return false;
  return RegExp(
    r'^<(html|body|div|p|table|ul|ol|h[1-6]|span)\b',
    caseSensitive: false,
  ).hasMatch(s);
}
