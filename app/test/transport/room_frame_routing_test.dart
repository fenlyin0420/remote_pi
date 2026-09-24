// The inbound-frame routing rule: which room's traffic reaches the open chat,
// and which only reaches the background-notification path.
//
// This is the one place that can silently corrupt a chat (a foreign room's
// message written into the open session) or silently kill notifications (a
// frame dropped instead of surfaced), so it is pinned down directly.

import 'dart:typed_data';

import 'package:app/data/transport/ws_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final payload = Uint8List.fromList([1, 2, 3]);

  test('a frame from the addressed room goes to the session and is surfaced',
      () {
    final routed = classifyInboundFrame(
      senderRoom: 'room-a',
      activeRoom: 'room-a',
      payload: payload,
    );

    expect(routed.forSession, isTrue);
    expect(routed.frame.roomId, 'room-a');
    expect(routed.frame.payload, payload);
  });

  test('a frame from another room is surfaced but never reaches the session',
      () {
    final routed = classifyInboundFrame(
      senderRoom: 'room-b',
      activeRoom: 'room-a',
      payload: payload,
    );

    expect(routed.forSession, isFalse);
    expect(routed.frame.roomId, 'room-b');
    expect(routed.frame.payload, payload);
  });

  test('a legacy Pi without a room stamp routes to the session', () {
    final routed = classifyInboundFrame(
      senderRoom: null,
      activeRoom: 'room-a',
      payload: payload,
    );

    expect(routed.forSession, isTrue);
    // Tagged with the active room: a legacy Pi only has one.
    expect(routed.frame.roomId, 'room-a');
  });
}
