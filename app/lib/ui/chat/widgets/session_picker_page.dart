import 'dart:async';

import 'package:app/data/actions/actions_repository.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/chat/viewmodels/chat_viewmodel.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Session picker (plan/59) — the stored sessions of this room's cwd,
/// reachable from the session-info panel's `Sessions` entry. Tapping a
/// row confirms, then `switchSession`: the room continues that session
/// and the Pi's broadcast `session_history` re-renders the chat with it.
///
/// The current session is flagged, not tappable — switching to it is a
/// no-op on the Pi, so we skip the confirm + round-trip.
class SessionPickerPage extends StatefulWidget {
  final ChatViewModel chat;
  final String roomName;
  const SessionPickerPage({super.key, required this.chat, required this.roomName});

  @override
  State<SessionPickerPage> createState() => _SessionPickerPageState();
}

class _SessionPickerPageState extends State<SessionPickerPage> {
  Future<List<WireSession>>? _load;

  @override
  void initState() {
    super.initState();
    _load = widget.chat.listSessions();
  }

  Future<void> _reload() async {
    setState(() => _load = widget.chat.listSessions());
  }

  Future<void> _confirmAndSwitch(WireSession session) async {
    final label = session.name?.isNotEmpty == true
        ? session.name!
        : _truncated(session.firstMessage, 48);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dCtx) {
        final dColors = dCtx.colors;
        return AlertDialog(
          backgroundColor: dColors.bg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: dColors.border),
          ),
          title: Text(
            'Continue session',
            style: TextStyle(fontFamily: kMonoFamily, fontSize: 15, color: dColors.text),
          ),
          content: Text(
            '「$label」\n\nThe room continues that session; its current '
            'conversation is replaced (the old one stays in this list and '
            'can be picked again).',
            style: TextStyle(fontFamily: kMonoFamily, fontSize: 12.5,
                color: dColors.text, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dCtx).pop(false),
              child: Text('Cancel',
                  style: TextStyle(fontFamily: kMonoFamily, color: dColors.muted)),
            ),
            TextButton(
              onPressed: () => Navigator.of(dCtx).pop(true),
              child: Text('Continue',
                  style: TextStyle(fontFamily: kMonoFamily, color: dColors.accent)),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;

    // Close the picker IMMEDIATELY. The switch tears down and rebuilds the
    // Pi side (and the relay with it), so the `action_ok` reply is usually
    // lost in the teardown — waiting for it here would hang the page for
    // the full 15 s timeout. The room's new history then arrives as a
    // broadcast, and the explicit re-syncs below are the backstop.
    final chat = widget.chat;
    final messenger = ScaffoldMessenger.of(context);
    final colors = context.colors;
    Navigator.of(context).pop();

    // Fire the switch in the background. Errors that land BEFORE the Pi
    // starts the switch (session_not_found, offline) still arrive on the
    // live channel — toast those. The post-switch 'timeout' is the normal
    // outcome of the teardown, so stay quiet on it.
    unawaited(chat.switchSession(session.id).then(
      (_) {},
      onError: (Object e) {
        if (e is ActionFailure &&
            !e.message.contains('timeout') &&
            !e.message.contains('offline')) {
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                'Switch failed: ${e.message}',
                style: const TextStyle(fontFamily: kMonoFamily, fontSize: 12),
              ),
              backgroundColor: colors.error,
            ),
          );
        }
      },
    ));

    // Backstop syncs: the Pi's own `session_history` replay can be lost in
    // the relay teardown. The first fires after the switch has settled
    // (interactive) or the RPC round-trip (daemon); the second covers a
    // slow rebind. While the channel is down they simply stay pending.
    unawaited(_delayedResync(chat, const Duration(milliseconds: 1500)));
    unawaited(_delayedResync(chat, const Duration(seconds: 6)));
  }

  Future<void> _delayedResync(ChatViewModel chat, Duration delay) async {
    await Future<void>.delayed(delay);
    await chat.resyncRoom();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Scaffold(
      backgroundColor: colors.bg,
      appBar: AppBar(
        backgroundColor: colors.bg,
        title: Text(
          widget.roomName.isEmpty ? 'Sessions' : 'Sessions · ${widget.roomName}',
          style: TextStyle(fontFamily: kMonoFamily, fontSize: 14, color: colors.text),
        ),
        actions: [
          IconButton(
            icon: const Icon(LucideIcons.refreshCw, size: 18),
            tooltip: 'Refresh',
            onPressed: _reload,
          ),
        ],
      ),
      body: FutureBuilder<List<WireSession>>(
        future: _load,
        builder: (context, snap) {
          final data = snap.data;
          if (data == null) {
            if (snap.hasError) {
              return _state(
                context,
                icon: LucideIcons.alertTriangle,
                message: 'Could not list sessions.',
                sub: _friendlyError(snap.error!),
              );
            }
            return _state(
              context,
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2, color: colors.muted2),
              ),
            );
          }
          final sessions = data;
          if (sessions.isEmpty) {
            return _state(
              context,
              icon: LucideIcons.inbox,
              message: 'No stored sessions',
              sub: 'This room has no session files yet.',
            );
          }
          return RefreshIndicator(
            onRefresh: _reload,
            child: ListView.separated(
              itemCount: sessions.length,
              separatorBuilder: (_, _) => Divider(
                height: 1,
                color: colors.border,
                indent: 16,
                endIndent: 16,
              ),
              itemBuilder: (context, i) {
                final s = sessions[i];
                final title = s.name?.isNotEmpty == true
                    ? s.name!
                    : (s.firstMessage.isNotEmpty ? s.firstMessage : '(unnamed session)');
                return ListTile(
                  onTap: s.isCurrent ? null : () => _confirmAndSwitch(s),
                  leading: Icon(
                    s.isCurrent ? LucideIcons.circleCheck : LucideIcons.messageSquare,
                    size: 18,
                    color: s.isCurrent ? colors.accent : colors.muted2,
                  ),
                  title: Text(
                    _truncated(title, 44),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: kMonoFamily,
                      fontSize: 13,
                      color: colors.text,
                    ),
                  ),
                  subtitle: Text(
                    '${_day(s.modified)} · ${s.messageCount} msgs'
                    '${s.isCurrent ? ' · current' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontFamily: kMonoFamily, fontSize: 11, color: colors.muted),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }

  /// Spinner / empty / error bodies, all centred with the app's muted
  /// placeholder styling.
  Widget _state(
    BuildContext context, {
    Widget? child,
    IconData? icon,
    String? message,
    String? sub,
  }) {
    final colors = context.colors;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Opacity(opacity: 0.5, child: Icon(icon, size: 40, color: colors.muted)),
            const SizedBox(height: 12),
          ] else if (child != null) ...[child],
          if (message != null)
            Text(
              message,
              style: TextStyle(fontFamily: kMonoFamily, fontSize: 13, color: colors.text),
            ),
          if (sub != null) ...[
            const SizedBox(height: 6),
            Text(
              sub,
              textAlign: TextAlign.center,
              style: TextStyle(fontFamily: kMonoFamily, fontSize: 11, color: colors.muted),
            ),
          ],
        ],
      ),
    );
  }

  /// The 15 s action timeout means the Pi never answered — older builds
  /// have no picker, so say so instead of a bare "timeout".
  String _friendlyError(Object e) {
    final m = e.toString();
    if (m.contains('timeout')) {
      return 'The Pi did not answer — older builds have no session picker.';
    }
    if (m.contains('offline')) return 'The room is offline.';
    return m;
  }

  static String _day(String iso) {
    final day = iso.contains('T') ? iso.split('T').first : iso;
    return day.isNotEmpty ? day : '';
  }

  static String _truncated(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max - 1)}…';
}
