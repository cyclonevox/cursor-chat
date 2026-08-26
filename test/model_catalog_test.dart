import 'package:cursor_chat/api/cursor_api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('composer only exposes fast true/false, not a fake effort ladder', () {
    final m = CursorModel.fromJson({
      'id': 'composer-2.5',
      'displayName': 'Composer 2.5',
      'parameters': [
        {
          'id': 'fast',
          'displayName': 'Fast',
          'values': [
            {'value': 'false'},
            {'value': 'true', 'displayName': 'Fast'},
          ],
        },
      ],
      'variants': [
        {
          'params': [
            {'id': 'fast', 'value': 'true'},
          ],
          'displayName': 'Composer 2.5',
          'isDefault': true,
        },
        {
          'params': [
            {'id': 'fast', 'value': 'false'},
          ],
          'displayName': 'Composer 2.5',
        },
      ],
    });
    expect(m.parameters.single.id, 'fast');
    expect(m.parameters.single.values.map((v) => v.value), ['false', 'true']);
    expect(m.alignedParams({})['fast'], 'true');
    expect(m.alignedParams({'fast': 'false'})['fast'], 'false');
    expect(
      m
          .alignedParams({'reasoningEffort': 'high'})
          .containsKey('reasoningEffort'),
      isFalse,
    );
  });

  test('thinking model keeps its own effort values, drops composer fast', () {
    final m = CursorModel.fromJson({
      'id': 'claude-4.6-sonnet-thinking',
      'displayName': 'Claude 4.6 Sonnet (Thinking)',
      'parameters': [
        {
          'id': 'effort',
          'displayName': 'Effort',
          'values': [
            {'value': 'low', 'displayName': 'Low'},
            {'value': 'medium', 'displayName': 'Medium'},
            {'value': 'high', 'displayName': 'High'},
          ],
        },
      ],
      'variants': [
        {
          'params': [
            {'id': 'effort', 'value': 'medium'},
          ],
          'displayName': 'Medium',
          'isDefault': true,
        },
      ],
    });
    final aligned = m.alignedParams({'fast': 'false', 'effort': 'xhigh'});
    expect(aligned.containsKey('fast'), isFalse);
    expect(aligned['effort'], 'medium');
    expect(m.alignedParams({'effort': 'high'})['effort'], 'high');
  });

  test('router model only accepts optimize_for', () {
    final m = CursorModel.fromJson({
      'id': 'auto-smart',
      'displayName': 'Cursor Router',
      'parameters': [
        {
          'id': 'optimize_for',
          'displayName': 'Optimize for',
          'values': [
            {'value': 'cost'},
            {'value': 'balanced'},
            {'value': 'intelligence'},
          ],
        },
      ],
    });
    expect(m.alignedParams({'fast': 'true'})['optimize_for'], 'cost');
    expect(
      m.alignedParams({'optimize_for': 'intelligence'})['optimize_for'],
      'intelligence',
    );
  });
}
