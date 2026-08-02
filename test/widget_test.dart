import 'package:flutter/cupertino.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:notilus/app.dart';

import 'native_test_support.dart';

void main() {
  setUpAll(() async {
    // `main()` normally does both of these before the first frame. This test
    // pumps NotilusApp directly, so without them TransferController throws
    // while reading its config during construction.
    // An empty string is rejected, so seed a single inert key.
    dotenv.loadFromString(envString: 'NOTILUS_TEST=1');
    await NativeTestSupport.ensureLoaded();
  });

  testWidgets('App boots without crashing', (WidgetTester tester) async {
    await tester.pumpWidget(const NotilusApp());
    await tester.pump();
    expect(find.byType(CupertinoApp), findsOneWidget);
  });
}
