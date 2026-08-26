import 'package:cursor_chat/main.dart';
import 'package:cursor_chat/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shows empty chat and settings entry', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = ChatStore();
    store.conversations.clear();
    store.newChat();
    await tester.pumpWidget(ChatApp(store: store));
    expect(find.textContaining('有问题就问'), findsOneWidget);
    expect(find.textContaining('API Key'), findsOneWidget);
  });
}
