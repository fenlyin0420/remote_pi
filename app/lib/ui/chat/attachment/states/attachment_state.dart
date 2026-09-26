import 'package:app/data/files/text_file_picker_service.dart';
import 'package:app/data/images/image_picker_service.dart';

/// Composer attachment state.
///
/// Models the one-attachment pick lifecycle (empty → picking → attached) and
/// carries [visionSupported] so the image entry points can grey out for a
/// text-only model. `visionSupported` is tri-state: `true`/`false` once the
/// model catalogue is known, `null` while unknown (don't gate yet).
///
/// Vision never gates a *file*: any model can read a text file.
sealed class AttachmentState {
  const AttachmentState({required this.visionSupported});

  /// Whether the active model accepts images. `null` = not yet known.
  final bool? visionSupported;

  /// Convenience: gate the image options only when we *know* it's false.
  bool get imageBlockedByVision => visionSupported == false;
}

/// Nothing attached; composer behaves as text/voice.
final class AttachmentEmpty extends AttachmentState {
  const AttachmentEmpty({super.visionSupported});

  @override
  bool operator ==(Object other) =>
      other is AttachmentEmpty && other.visionSupported == visionSupported;

  @override
  int get hashCode => visionSupported.hashCode;
}

/// A pick is in flight (camera/gallery/file sheet → read/compress).
final class AttachmentPicking extends AttachmentState {
  const AttachmentPicking({super.visionSupported});

  @override
  bool operator ==(Object other) =>
      other is AttachmentPicking && other.visionSupported == visionSupported;

  @override
  int get hashCode => visionSupported.hashCode;
}

/// What is attached: exactly one of an image or a text file.
sealed class AttachmentPayload {
  const AttachmentPayload();
}

final class AttachedImage extends AttachmentPayload {
  const AttachedImage(this.image);

  final PickedImage image;

  @override
  bool operator ==(Object other) =>
      other is AttachedImage && identical(other.image, image);

  @override
  int get hashCode => identityHashCode(image);
}

final class AttachedTextFile extends AttachmentPayload {
  const AttachedTextFile(this.file);

  final PickedTextFile file;

  @override
  bool operator ==(Object other) =>
      other is AttachedTextFile && identical(other.file, file);

  @override
  int get hashCode => file.hashCode;
}

/// One attachment is set and previewed in the composer.
final class AttachmentAttached extends AttachmentState {
  const AttachmentAttached({required this.payload, super.visionSupported});

  final AttachmentPayload payload;

  /// The attached image, or null when the payload is a file.
  PickedImage? get image =>
      payload is AttachedImage ? (payload as AttachedImage).image : null;

  /// The attached text file, or null when the payload is an image.
  PickedTextFile? get file =>
      payload is AttachedTextFile ? (payload as AttachedTextFile).file : null;

  @override
  bool operator ==(Object other) =>
      other is AttachmentAttached &&
      other.payload == payload &&
      other.visionSupported == visionSupported;

  @override
  int get hashCode => Object.hash(payload, visionSupported);
}

/// One-shot hints the composer asks the host page to surface (snackbar /
/// settings deep-link), mirroring the voice [VoiceHint] pattern.
enum AttachHint {
  /// Camera permission denied — guide to system Settings (#10).
  cameraPermissionDenied,

  /// The picked file is not text (binary content) — the only content rule.
  notTextFile,

  /// Pick/read/compress failed for some other reason.
  pickFailed,
}
