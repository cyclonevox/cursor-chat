import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:gpt_markdown/custom_widgets/selectable_adapter.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

class AnswerBody extends StatelessWidget {
  const AnswerBody({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = text.trim();
    if (t.isEmpty) return const SizedBox.shrink();
    if (_looksLikeHtml(t)) {
      return SelectableAdapter(
        selectedText: t,
        child: Html(
          data: t,
          shrinkWrap: true,
          style: {
            'body': Style(
              margin: Margins.zero,
              padding: HtmlPaddings.zero,
              fontSize: FontSize(15.0),
            ),
          },
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width * 0.78;
        return GptMarkdown(
          t,
          isStreaming: false,
          useDollarSignsForLatex: true,
          textDirection: Directionality.of(context),
          latexBuilder: (context, tex, style, inline) {
            return FittedMath(
              tex: tex,
              style: style,
              inline: inline,
              maxWidth: maxW,
            );
          },
        );
      },
    );
  }
}

/// Scales maths down to [maxWidth] so long display formulas are not clipped.
class FittedMath extends StatelessWidget {
  const FittedMath({
    super.key,
    required this.tex,
    required this.style,
    required this.inline,
    required this.maxWidth,
  });

  final String tex;
  final TextStyle style;
  final bool inline;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final math = Math.tex(
      tex,
      textStyle: style,
      mathStyle: inline ? MathStyle.text : MathStyle.display,
      textScaleFactor: 1,
      settings: const TexParserSettings(strict: Strict.ignore),
      onErrorFallback: (err) => Text(tex, style: style),
    );

    return SelectableAdapter(
      selectedText: tex,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: math,
        ),
      ),
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
