import 'package:app/domain/session_state.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The user bubble for a message that carried an uploaded text file.
///
/// Deliberately *not* an image-style preview: the content lives on the Pi (it
/// was never sent to the device), so the bubble shows what the user needs to
/// recognise the upload — its name, and where it landed once the Pi reported
/// back. The caption (if any) reads exactly as on a text message.
class FileBubble extends StatelessWidget {
  const FileBubble({
    super.key,
    required this.file,
    this.caption = '',
    this.isFailed = false,
  });

  final MessageFile file;
  final String caption;
  final bool isFailed;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final caption = this.caption.trim();
    final path = file.path;
    return Container(
      decoration: BoxDecoration(
        color: colors.userBubble,
        borderRadius: BorderRadius.circular(12),
        border: isFailed
            ? Border.all(color: colors.error, width: 1)
            : null,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(
                    LucideIcons.fileText,
                    size: 16,
                    color: colors.accent,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        file.name,
                        key: const Key('file-bubble-name'),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: kMonoFamily,
                          fontSize: 13,
                          color: colors.text,
                        ),
                      ),
                      if (path != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            path,
                            key: const Key('file-bubble-path'),
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: kMonoFamily,
                              fontSize: 10,
                              color: colors.muted,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (caption.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(13, 0, 13, 10),
              child: Text(
                caption,
                style: context.typo.sansBody.copyWith(color: colors.text),
              ),
            ),
        ],
      ),
    );
  }
}
