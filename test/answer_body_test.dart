import 'package:cursor_chat/widgets/answer_body.dart';
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('wide display latex stays inside a phone-width bubble', (
    tester,
  ) async {
    const formula =
        r'$$\lim_{(x,y)\to(0,0)}\frac{f(x,y)-f_x(0,0)x-f_y(0,0)y}{r}=\lim_{(x,y)\to(0,0)}\frac{xy}{r}=0$$';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              child: AnswerBody(text: formula),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    expect(find.byType(Math), findsWidgets);
    expect(find.byType(FittedBox), findsWidgets);
    expect(tester.getSize(find.byType(AnswerBody)).width, lessThanOrEqualTo(320.5));
    expect(
      tester.getSize(find.byType(FittedBox).first).width,
      lessThanOrEqualTo(320.5),
    );
    expect(
      tester.getSize(find.byType(FittedBox).first).width,
      lessThan(tester.getSize(find.byType(Math).first).width),
    );
  });

  testWidgets('inline latex also stays inside the bubble', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 280,
            child: AnswerBody(
              text: r'因此 $f_x(0,0)=f_y(0,0)=0$ 且可微当且仅当极限为 0。',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(AnswerBody)).width, lessThanOrEqualTo(280.5));
  });
}
