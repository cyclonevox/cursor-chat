import 'package:cursor_chat/api/cursor_api.dart';
import 'package:cursor_chat/models/models.dart';
import 'package:cursor_chat/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_cursor_api.dart';

CursorModel get _composer => CursorModel.fromJson({
  'id': 'composer-2.5',
  'displayName': 'Composer 2.5',
  'parameters': [
    {
      'id': 'fast',
      'values': [
        {'value': 'false'},
        {'value': 'true', 'displayName': 'Fast'},
      ],
    },
  ],
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('cached catalog is reused and not fetched again on load', () async {
    final api = FakeCursorApi()..catalog = [_composer];
    final store = ChatStore(client: api)
      ..apiKey = 'k'
      ..rescheduleModelsOnFailure = false
      ..modelsRetryDelays = const [];
    await store.refreshModels(force: true);
    expect(api.listModelsCalls, 1);
    expect(store.models.single.id, 'composer-2.5');

    final api2 = FakeCursorApi()
      ..listModelsError = CursorApiException(0, 'Connection reset');
    final store2 = ChatStore(client: api2)..rescheduleModelsOnFailure = false;
    await store2.load();
    expect(store2.models.single.id, 'composer-2.5');
    expect(api2.listModelsCalls, 0);
    expect(store2.error, isNull);
    expect(store2.visibleError, isNull);
  });

  test('listModels retries then succeeds without a chat error', () async {
    final api = FakeCursorApi()
      ..catalog = [_composer]
      ..listModelsFailTimes = 2;
    final store = ChatStore(client: api)
      ..apiKey = 'k'
      ..rescheduleModelsOnFailure = false
      ..modelsRetryDelays = const [Duration.zero, Duration.zero];
    await store.refreshModels(force: true);
    expect(api.listModelsCalls, 3);
    expect(store.models, isNotEmpty);
    expect(store.error, isNull);
    expect(store.modelsError, isNull);
  });

  test('failed catalog fetch does not send the user to a chat error', () async {
    final api = FakeCursorApi()
      ..listModelsError = CursorApiException(0, 'Connection reset');
    final store = ChatStore(client: api)
      ..apiKey = 'k'
      ..rescheduleModelsOnFailure = false
      ..modelsRetryDelays = const [];
    await store.refreshModels(force: true);
    expect(store.models, isEmpty);
    expect(store.error, isNull);
    expect(store.visibleError, isNull);
    expect(store.modelsError, contains('自动再试'));
  });

  test('401 is not retried', () async {
    final api = FakeCursorApi()
      ..listModelsError = CursorApiException(401, 'unauthorized');
    final store = ChatStore(client: api)
      ..apiKey = 'k'
      ..rescheduleModelsOnFailure = false
      ..modelsRetryDelays = const [Duration.zero, Duration.zero];
    await store.refreshModels(force: true);
    expect(api.listModelsCalls, 1);
    expect(store.modelsError, contains('Key'));
  });

  test('failed refresh keeps the previous catalog', () async {
    final api = FakeCursorApi()..catalog = [_composer];
    final store = ChatStore(client: api)
      ..apiKey = 'k'
      ..rescheduleModelsOnFailure = false
      ..modelsRetryDelays = const [];
    await store.refreshModels(force: true);
    api.listModelsError = CursorApiException(0, 'down');
    await store.refreshModels(force: true);
    expect(store.models.single.id, 'composer-2.5');
    expect(store.modelsError, isNotNull);
    expect(store.error, isNull);
  });

  test('skips network when a catalog is already in memory', () async {
    final api = FakeCursorApi();
    final store = ChatStore(client: api)
      ..apiKey = 'k'
      ..models = [_composer];
    await store.refreshModels();
    expect(api.listModelsCalls, 0);
  });
}
