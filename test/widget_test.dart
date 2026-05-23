import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:notilus/app.dart';

void main() {
  testWidgets('App boots without crashing', (WidgetTester tester) async {
    await tester.pumpWidget(const NotilusApp());
    await tester.pump();
    expect(find.byType(CupertinoApp), findsOneWidget);
  });
}
