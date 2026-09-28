import 'dart:async';

// Pi → App attachments: a `file_offer` writes a card, the bytes land in the
// local cache, a history replay rebuilds the card as metadata only, and a
// metadata-only offer never wipes bytes the user already has.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:app/data/attachments/attachment_store.dart';
import 'package:app/data/local/boxes.dart';
import 'package:app/data/local/records/message_record.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/sync/sync_service.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

class _FakeChannel implements IChannel, IControlLink {
  final _ctrl = StreamController<ServerMessage>.broadcast();
  final _control = StreamController<ControlInbound>.broadcast();
  final List<ClientMessage> sent = [];
  @override
  Stream<ServerMessage> get serverMessages => _ctrl.stream;
  @override
  Stream<ControlInbound> get controlFrames => _control.stream;
  @override
  Future<void> send(ClientMessage msg) async => sent.add(msg);
  @override
  void sendControl(Map<String, dynamic> json) {}
  @override
  Future<void> close() async {
    await _ctrl.close();
    await _control.close();
  }

  void push(ServerMessage m) => _ctrl.add(m);
}

class _FakeStorage extends PairingStorage {
  @override
  Future<List<PeerRecord>> listPeers() async => const [];
}

int _counter = 0;

late Directory _dir;
late AttachmentStore _store;

/// A 1×1 PNG, so the app has real image bytes to cache.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 40));

void main() {
  setUpAll(() async {
    _dir = Directory.systemTemp.createTempSync('rp_attach_sync_');
    await LocalBoxes.initForTest(_dir.path);
  });

  setUp(() {
    // One store per test, injected so nothing depends on where Hive put its
    // boxes, and so a leftover blob from a previous test can't be served.
    _store = AttachmentStore(
      Directory('${_dir.path}/blobs_${++_counter}'),
    );
  });

  tearDownAll(() async {
    await Hive.close();
    await _dir.delete(recursive: true);
  });

  Future<
    ({ConnectionManager conn, _FakeChannel ch, SyncService sync, String epk})
  >
  setup() async {
    final ch = _FakeChannel();
    final conn = ConnectionManager(
      factory: (_, _) async => ch,
      storage: _FakeStorage(),
      emitDebounce: Duration.zero,
    );
    final sync = SyncService(
      conn,
      LocalBoxes(),
      attachmentStore: _store,
    );
    final epk = 'epk_att_${++_counter}';
    conn.adopt(
      ch,
      PeerRecord(
        remoteEpk: epk,
        sessionName: 'Pi',
        relayUrl: 'ws://localhost',
        pairedAt: '2026-01-01T00:00:00Z',
      ),
    );
    await _settle();
    return (conn: conn, ch: ch, sync: sync, epk: epk);
  }

  List<MessageRecord> messages(String epk) {
    final box = LocalBoxes().openMsgsBox(epk, 'main');
    final out = [
      for (final v in box.values)
        MessageRecord.fromJson((v as Map).cast<String, dynamic>()),
    ];
    out.sort((a, b) => a.seq.compareTo(b.seq));
    return out;
  }

  test('a file_offer writes one card and caches the bytes', () async {
    final s = await setup();
    s.ch.push(
      FileOffer(
        id: 'att_tc-1',
        name: 'shot.png',
        path: '/home/p/shot.png',
        mime: 'image/png',
        size: _png.length,
        data: base64Encode(_png),
        note: 'the screenshot',
        resized: true,
        originalSize: 3 * 1024 * 1024,
      ),
    );
    await _settle();

    final m = messages(s.epk);
    expect(m, hasLength(1));
    final card = m.first;
    expect(card.role, MsgRole.attachment);
    expect(card.attachment!.name, 'shot.png');
    expect(card.attachment!.note, 'the screenshot');
    expect(card.attachment!.resized, isTrue);
    expect(card.attachment!.originalSize, 3 * 1024 * 1024);
    // The bytes are NOT in the record — they live in the cache.
    expect(card.toJson().toString(), isNot(contains(base64Encode(_png))));

    final domain = card.toChatMessage() as AttachmentMsg;
    expect(domain.isImage, isTrue);
    expect(domain.hasContent, isTrue);
    final bytes = await _store.get(card.attachment!.blobName!);
    expect(bytes, orderedEquals(_png));

    s.conn.dispose();
    s.sync.dispose();
  });

  test('the same offer twice updates one card instead of stacking', () async {
    final s = await setup();
    final offer = FileOffer(
      id: 'att_tc-1',
      name: 'shot.png',
      path: '/home/p/shot.png',
      mime: 'image/png',
      size: _png.length,
      data: base64Encode(_png),
    );
    s.ch.push(offer);
    await _settle();
    s.ch.push(offer);
    await _settle();

    expect(messages(s.epk), hasLength(1));
    s.conn.dispose();
    s.sync.dispose();
  });

  test('a metadata-only offer keeps bytes the card already has', () async {
    final s = await setup();
    s.ch.push(
      FileOffer(
        id: 'att_tc-1',
        name: 'shot.png',
        path: '/home/p/shot.png',
        mime: 'image/png',
        size: _png.length,
        data: base64Encode(_png),
      ),
    );
    await _settle();
    final blob = messages(s.epk).first.attachment!.blobName;

    // A replay-shaped event for the same card (no `data`).
    s.ch.push(
      SessionHistory(
        inReplyTo: 'sync1',
        sessionStartedAt: 0,
        events: const [
          AttachmentEvt(
            ts: 5,
            id: 'att_tc-1',
            name: 'shot.png',
            path: '/home/p/shot.png',
            mime: 'image/png',
            size: 68,
          ),
        ],
        eos: true,
      ),
    );
    await _settle();

    final m = messages(s.epk);
    expect(m, hasLength(1));
    expect(m.first.attachment!.blobName, blob, reason: 'bytes must survive a re-sync');
    s.conn.dispose();
    s.sync.dispose();
  });

  test('a history attachment event rebuilds a card with no bytes yet', () async {
    final s = await setup();
    s.ch.push(
      SessionHistory(
        inReplyTo: 'sync1',
        sessionStartedAt: 0,
        events: const [
          UserInputEvt(ts: 1, id: 'u1', text: 'show me the chart'),
          AttachmentEvt(
            ts: 2,
            id: 'att_tc-9',
            name: 'chart.png',
            path: '/home/p/chart.png',
            mime: 'image/png',
            size: 4096,
            note: 'throughput',
          ),
        ],
        eos: true,
      ),
    );
    await _settle();

    final m = messages(s.epk);
    expect(m.map((r) => r.role), [MsgRole.user, MsgRole.attachment]);
    final domain = m.last.toChatMessage() as AttachmentMsg;
    expect(domain.hasContent, isFalse, reason: 'history carries metadata only');
    expect(domain.note, 'throughput');
    s.conn.dispose();
    s.sync.dispose();
  });

  test('a send_to_phone tool row is not duplicated by its card', () async {
    final s = await setup();
    s.ch.push(
      SessionHistory(
        inReplyTo: 'sync1',
        sessionStartedAt: 0,
        events: const [
          ToolRequestEvt(
            ts: 1,
            toolCallId: 'tc-1',
            tool: 'send_to_phone',
            args: {'path': '/home/p/chart.png'},
          ),
          ToolResultEvt(ts: 2, toolCallId: 'tc-1', result: 'Sent chart.png'),
          AttachmentEvt(
            ts: 3,
            id: 'att_tc-1',
            name: 'chart.png',
            path: '/home/p/chart.png',
            mime: 'image/png',
            size: 100,
          ),
        ],
        eos: true,
      ),
    );
    await _settle();

    expect(messages(s.epk).map((r) => r.role), [MsgRole.attachment]);
    s.conn.dispose();
    s.sync.dispose();
  });

  test('a FAILED send_to_phone still shows up as a tool error', () async {
    final s = await setup();
    s.ch.push(
      SessionHistory(
        inReplyTo: 'sync1',
        sessionStartedAt: 0,
        events: const [
          ToolRequestEvt(
            ts: 1,
            toolCallId: 'tc-1',
            tool: 'send_to_phone',
            args: {'path': '/nope.png'},
          ),
          ToolResultEvt(
            ts: 2,
            toolCallId: 'tc-1',
            error: 'No such file: /nope.png',
          ),
        ],
        eos: true,
      ),
    );
    await _settle();

    final m = messages(s.epk);
    expect(m.map((r) => r.role), [MsgRole.tool]);
    expect(m.first.tool!.error, contains('No such file'));
    s.conn.dispose();
    s.sync.dispose();
  });

  test('tapping a card without bytes asks the Pi for that exact card', () async {
    final s = await setup();
    await s.sync.requestAttachment('att_tc-4', '/home/p/chart.png');
    await _settle();

    final get = s.ch.sent.whereType<FileGet>().toList();
    expect(get, hasLength(1));
    expect(get.single.path, '/home/p/chart.png');
    expect(get.single.attachmentId, 'att_tc-4');
    expect(get.single.toJson()['type'], 'file_get');
    s.conn.dispose();
    s.sync.dispose();
  });

  test('the answer to a file_get fills the card in place', () async {
    final s = await setup();
    s.ch.push(
      SessionHistory(
        inReplyTo: 'sync1',
        sessionStartedAt: 0,
        events: const [
          AttachmentEvt(
            ts: 1,
            id: 'att_tc-4',
            name: 'notes.md',
            path: '/home/p/notes.md',
            mime: 'text/markdown',
            size: 12,
          ),
        ],
        eos: true,
      ),
    );
    await _settle();
    expect((messages(s.epk).first.toChatMessage() as AttachmentMsg).hasContent, isFalse);

    s.ch.push(
      FileOffer(
        id: 'att_tc-4',
        name: 'notes.md',
        path: '/home/p/notes.md',
        mime: 'text/markdown',
        size: 12,
        data: base64Encode(utf8.encode('# hello\nworld')),
        inReplyTo: 'get_1',
      ),
    );
    await _settle();

    final m = messages(s.epk);
    expect(m, hasLength(1), reason: 'the card is filled, not duplicated');
    final domain = m.first.toChatMessage() as AttachmentMsg;
    expect(domain.hasContent, isTrue);
    expect(
      AttachmentStore.textPreview((await _store.get(domain.blobName!))!),
      '# hello\nworld',
    );
    s.conn.dispose();
    s.sync.dispose();
  });
}
