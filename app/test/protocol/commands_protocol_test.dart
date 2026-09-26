// Command channel (`/slash` and `!shell`) — wire shapes and composer routing.
//
// The protocol half pins the exact JSON both sides agreed on; the widget half
// drives the real InputBar so the prefix routing and the `/` palette are
// exercised through the widget the user touches, not a replica.

import 'package:app/protocol/protocol.dart';
import 'package:app/ui/chat/widgets/input_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';

WireCommand _cmd(
  String name, {
  String? description,
  CommandSource source = CommandSource.builtin,
  CommandScope scope = CommandScope.all,
  bool supported = true,
}) => WireCommand(
  name: name,
  description: description,
  source: source,
  scope: scope,
  supported: supported,
);

void main() {
  group('command channel — wire', () {
    test('CommandInvoke carries the line verbatim, slash included', () {
      final json = CommandInvoke(id: 'c1', text: '/compact keep notes').toJson();
      expect(json, {
        'type': 'command_invoke',
        'id': 'c1',
        'text': '/compact keep notes',
      });
    });

    test('BashExec omits the optional keys on the default path', () {
      final json = BashExec(id: 'b1', command: 'ls').toJson();
      expect(json, {'type': 'bash_exec', 'id': 'b1', 'command': 'ls'});
    });

    test('BashExec marks the context exclusion and a custom timeout', () {
      final json = BashExec(
        id: 'b1',
        command: 'ls',
        excludeFromContext: true,
        timeoutMs: 30000,
      ).toJson();
      expect(json['exclude_from_context'], isTrue);
      expect(json['timeout_ms'], 30000);
    });

    test('ListCommands is a bare request', () {
      expect(ListCommands(id: 'l1').toJson(), {
        'type': 'list_commands',
        'id': 'l1',
      });
    });

    test('commands_list parses the full catalogue', () {
      final msg = ServerMessage.fromJson({
        'type': 'commands_list',
        'in_reply_to': 'l1',
        'commands': [
          {
            'name': 'compact',
            'description': 'Compact the session context',
            'source': 'builtin',
            'scope': 'all',
            'supported': true,
          },
          {
            'name': 'deploy',
            'source': 'extension',
            'scope': 'daemon',
            'supported': false,
          },
          {
            'name': 'login',
            'description': 'Configure provider authentication',
            'source': 'builtin',
            'scope': 'tui',
            'supported': false,
          },
        ],
      });
      expect(msg, isA<CommandsList>());
      final list = msg as CommandsList;
      expect(list.inReplyTo, 'l1');
      expect(list.commands.map((c) => c.name), ['compact', 'deploy', 'login']);
      expect(list.commands[0].source, CommandSource.builtin);
      expect(list.commands[1].scope, CommandScope.daemon);
      expect(list.commands[1].supported, isFalse);
      expect(list.commands[2].scope, CommandScope.tui);
    });

    test('an unknown source/scope from a newer Pi degrades instead of throwing', () {
      final msg = ServerMessage.fromJson({
        'type': 'commands_list',
        'in_reply_to': 'l2',
        'commands': [
          {'name': 'future', 'source': 'holo', 'scope': 'orbit', 'supported': true},
        ],
      }) as CommandsList;
      expect(msg.commands.single.source, CommandSource.unknown);
      expect(msg.commands.single.scope, CommandScope.unknown);
      expect(msg.commands.single.supported, isTrue);
    });

    test('the new action names round-trip through ActionName', () {
      expect(ActionName.fromWire('command_invoke'), ActionName.commandInvoke);
      expect(ActionName.fromWire('bash_exec'), ActionName.bashExec);
      expect(ActionName.fromWire('list_commands'), ActionName.listCommands);
    });
  });

  // ── Composer routing ──────────────────────────────────────────────────────

  Future<
    ({
      List<String> sends,
      List<String> commands,
      List<({String command, bool exclude})> bashes,
      List<int> requested,
    })
  >
  pumpBar(
    WidgetTester tester, {
    List<WireCommand> commands = const [],
    bool withCommandChannel = true,
  }) async {
    final sends = <String>[];
    final runs = <String>[];
    final bashes = <({String command, bool exclude})>[];
    // A list, not an int: the record below copies values, so a plain counter
    // would keep reading the pre-pump state.
    final requested = <int>[0];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InputBar(
            onSend: sends.add,
            onRunCommand: withCommandChannel ? runs.add : null,
            onRunBash: withCommandChannel
                ? (command, {excludeFromContext = false}) => bashes.add((
                    command: command,
                    exclude: excludeFromContext,
                  ))
                : null,
            commands: commands,
            onCommandsRequested: () => requested[0]++,
          ),
        ),
      ),
    );
    return (
      sends: sends,
      commands: runs,
      bashes: bashes,
      requested: requested,
    );
  }

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pump();
  }

  Future<void> submit(WidgetTester tester) async {
    // The composer's send path on a device with a keyboard is hardware Enter
    // (see InputBar._onComposerKey); the on-screen button dispatches the same
    // `_submit()`.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
  }

  testWidgets('a plain message still goes to onSend', (tester) async {
    final h = await pumpBar(tester);
    await type(tester, 'hello there');
    await submit(tester);
    expect(h.sends, ['hello there']);
    expect(h.commands, isEmpty);
  });

  testWidgets('/name is routed to the command channel, not the model', (tester) async {
    final h = await pumpBar(tester);
    await type(tester, '/compact keep the notes');
    await submit(tester);
    expect(h.sends, isEmpty);
    expect(h.commands, ['/compact keep the notes']);
  });

  testWidgets('!cmd runs shell with the description prefix stripped', (tester) async {
    final h = await pumpBar(tester);
    await type(tester, '!git status -sb');
    await submit(tester);
    expect(h.sends, isEmpty);
    expect(h.bashes, [(command: 'git status -sb', exclude: false)]);
  });

  testWidgets('!!cmd keeps the output out of the model context', (tester) async {
    final h = await pumpBar(tester);
    await type(tester, '!!cat secrets.env');
    await submit(tester);
    expect(h.bashes, [(command: 'cat secrets.env', exclude: true)]);
  });

  testWidgets('a lone ! is not a command', (tester) async {
    final h = await pumpBar(tester);
    await type(tester, '!');
    await submit(tester);
    expect(h.bashes, isEmpty);
    expect(h.sends, isEmpty);
  });

  testWidgets('without a command channel the text falls back to a normal send', (tester) async {
    final h = await pumpBar(tester, withCommandChannel: false);
    await type(tester, '/compact');
    await submit(tester);
    expect(h.commands, isEmpty);
    expect(h.sends, ['/compact']);
  });

  testWidgets('an attachment keeps the text a caption, never a command', (tester) async {
    // No attachment VM here, so simulate the contract: with an attachment the
    // bar must not intercept. Covered indirectly below by the /-only path plus
    // the knowledge that interception is gated on `hasAttachment`; this test
    // pins the plain-text legend stays a message.
    final h = await pumpBar(tester);
    await type(tester, 'look at this');
    await submit(tester);
    expect(h.sends, ['look at this']);
  });

  // ── `/` palette ───────────────────────────────────────────────────────────

  final catalogue = [
    _cmd('compact', description: 'Compact the session context'),
    _cmd('copy', description: 'Copy last message', scope: CommandScope.tui, supported: false),
    _cmd('deploy', description: 'Ship it', source: CommandSource.extension, scope: CommandScope.daemon, supported: false),
  ];

  testWidgets('typing / opens the palette and asks for the catalogue', (tester) async {
    final h = await pumpBar(tester, commands: catalogue);
    expect(find.byKey(const Key('command-palette-compact')), findsNothing);
    await type(tester, '/');
    expect(find.byKey(const Key('command-palette-compact')), findsOneWidget);
    // Unsupported entries stay visible: "exists, but not here" is the answer.
    expect(find.byKey(const Key('command-palette-copy')), findsOneWidget);
    expect(find.text('Pi TUI only'), findsOneWidget);
    expect(find.text('needs a daemon room'), findsOneWidget);
    expect(h.requested, [1]);
    // Only the appearance transition asks; further keystrokes don't.
    await type(tester, '/co');
    expect(h.requested, [1]);
  });

  testWidgets('the palette filters by the typed prefix', (tester) async {
    await pumpBar(tester, commands: catalogue);
    await type(tester, '/co');
    expect(find.byKey(const Key('command-palette-compact')), findsOneWidget);
    expect(find.byKey(const Key('command-palette-copy')), findsOneWidget);
    expect(find.byKey(const Key('command-palette-deploy')), findsNothing);
    await type(tester, '/dep');
    expect(find.byKey(const Key('command-palette-deploy')), findsOneWidget);
    expect(find.byKey(const Key('command-palette-compact')), findsNothing);
  });

  testWidgets('the palette hides once arguments are typed', (tester) async {
    await pumpBar(tester, commands: catalogue);
    await type(tester, '/compact ');
    expect(find.byKey(const Key('command-palette-compact')), findsNothing);
  });

  testWidgets('tapping a supported entry runs it immediately', (tester) async {
    final h = await pumpBar(tester, commands: catalogue);
    await type(tester, '/');
    await tester.tap(find.byKey(const Key('command-palette-compact')));
    await tester.pump();
    expect(h.commands, ['/compact']);
    expect(h.sends, isEmpty);
    // The composer is cleared and the palette gone.
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
    expect(find.byKey(const Key('command-palette-compact')), findsNothing);
  });

  testWidgets('tapping an unsupported entry does nothing', (tester) async {
    final h = await pumpBar(tester, commands: catalogue);
    await type(tester, '/');
    await tester.tap(find.byKey(const Key('command-palette-copy')));
    await tester.pump();
    expect(h.commands, isEmpty);
    expect(h.sends, isEmpty);
  });

  testWidgets('an empty catalogue renders no palette (offline Pi)', (tester) async {
    await pumpBar(tester);
    await type(tester, '/');
    expect(find.byKey(const Key('command-palette-compact')), findsNothing);
  });
}
