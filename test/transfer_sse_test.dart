import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:notilus/models/transfer/inbox_message.dart';
import 'package:notilus/services/transfer/sse.dart';

void main() {
  group('decodeSse', () {
    test('parses events, joins multi-line data, strips leading space', () async {
      final lines = Stream.fromIterable([
        'event: put',
        'data: {"path":"/",',
        'data: "data":null}',
        '', // dispatch event 1
        ': keep this comment ignored',
        'event: keep-alive',
        'data: null',
        '', // dispatch event 2
        'event: put',
        'data: {"path":"/m1","data":{"type":"ping"}}',
        '', // dispatch event 3
      ]);

      final events = await decodeSse(lines).toList();
      expect(events.length, 3);

      expect(events[0].event, 'put');
      // Two data lines are newline-joined.
      expect(events[0].data, '{"path":"/",\n"data":null}');

      expect(events[1].event, 'keep-alive');
      expect(events[1].data, 'null');

      expect(events[2].event, 'put');
      expect(jsonDecode(events[2].data)['path'], '/m1');
    });

    test('flushes a trailing event with no final blank line', () async {
      final events = await decodeSse(Stream.fromIterable([
        'event: put',
        'data: {"path":"/x","data":{"type":"cancel"}}',
      ])).toList();
      expect(events.length, 1);
      expect(events.single.event, 'put');
    });
  });

  group('InboxMessage', () {
    test('toMap/fromMap round-trips', () {
      const m = InboxMessage(
        type: InboxMessage.typeTransferRequest,
        from: 'uid-alice',
        ts: 1720000000000,
        payload: {'count': 3, 'files': ['a.png', 'b.pdf']},
      );
      final map = m.toMap();
      final back = InboxMessage.fromMap('push-1', map);
      expect(back.id, 'push-1');
      expect(back.type, InboxMessage.typeTransferRequest);
      expect(back.from, 'uid-alice');
      expect(back.ts, 1720000000000);
      expect(back.payload['count'], 3);
      expect((back.payload['files'] as List).length, 2);
      expect(back.signature, isNull);
    });

    test('tolerates string ts and missing payload', () {
      final back = InboxMessage.fromMap('id', {
        'type': 'x',
        'from': 'y',
        'ts': '123',
      });
      expect(back.ts, 123);
      expect(back.payload, isEmpty);
    });
  });
}
