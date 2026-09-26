import 'dart:async';
import 'dart:convert';

import 'package:app/data/actions/actions_repository.dart';
import 'package:app/data/files/text_file_picker_service.dart';
import 'package:app/data/images/image_picker_service.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/attachment/states/attachment_state.dart';
import 'package:app/ui/core/viewmodel/viewmodel.dart';

/// Plan/30 — drives the composer's single attachment (one image or one text
/// file).
///
/// Owns the picked-attachment preview state and tracks whether the active
/// model accepts images (`vision`). Vision is resolved from the model
/// catalogue the app already fetches for the quick-actions picker (plan 28):
/// cached in [IActionsRepository], re-resolved whenever the active model
/// changes. It gates the camera/gallery entries only — a text file is fine on
/// any model.
class AttachmentViewModel extends ViewModel<AttachmentState> {
  AttachmentViewModel(this._picker, this._filePicker, this._actions)
    : super(const AttachmentEmpty()) {
    _metaSub = _actions.activeRoomMetaStream.listen((_) => _refreshVision());
    // ignore: discarded_futures
    _refreshVision();
  }

  final IImagePickerService _picker;
  final ITextFilePickerService _filePicker;
  final IActionsRepository _actions;

  StreamSubscription<ActiveRoomMeta>? _metaSub;
  bool _resolvingVision = false;

  final StreamController<AttachHint> _hints =
      StreamController<AttachHint>.broadcast();

  /// One-shot hints (permission denied / pick failed / not a text file) for
  /// the host page.
  Stream<AttachHint> get hints => _hints.stream;

  /// True while any attachment (image or file) is set.
  bool get hasAttachment => state is AttachmentAttached;

  /// True while an *image* is set (drives the thumbnail preview + the
  /// image-specific send rules such as the empty-caption send).
  bool get hasImage {
    final s = state;
    return s is AttachmentAttached && s.image != null;
  }

  /// True when the active model cannot take images — the host greys out the
  /// camera/gallery entries and leaves files alone.
  bool get imageBlockedByVision => state.imageBlockedByVision;

  // ---------------------------------------------------------------------------
  // Picking
  // ---------------------------------------------------------------------------

  Future<void> pickFromCamera() => _pick(() async {
    final image = await _picker.pickFromCamera();
    return image == null ? null : AttachedImage(image);
  });

  Future<void> pickFromGallery() => _pick(() async {
    final image = await _picker.pickFromGallery();
    return image == null ? null : AttachedImage(image);
  });

  /// Pick any file, then keep it only if its content is text.
  Future<void> pickTextFile() => _pick(() async {
    final file = await _filePicker.pickTextFile();
    return file == null ? null : AttachedTextFile(file);
  });

  /// Shared lifecycle for every source: picking → attached, or back to empty
  /// with a one-shot hint. A null payload means the user cancelled.
  Future<void> _pick(Future<AttachmentPayload?> Function() pick) async {
    if (state is AttachmentPicking) return;
    final vision = state.visionSupported;
    emit(AttachmentPicking(visionSupported: vision));
    try {
      final payload = await pick();
      emit(
        payload == null
            ? AttachmentEmpty(visionSupported: vision) // cancelled
            : AttachmentAttached(payload: payload, visionSupported: vision),
      );
    } on ImagePermissionDeniedException {
      emit(AttachmentEmpty(visionSupported: vision));
      if (!_hints.isClosed) _hints.add(AttachHint.cameraPermissionDenied);
    } on NotTextFileException {
      emit(AttachmentEmpty(visionSupported: vision));
      if (!_hints.isClosed) _hints.add(AttachHint.notTextFile);
    } catch (_) {
      emit(AttachmentEmpty(visionSupported: vision));
      if (!_hints.isClosed) _hints.add(AttachHint.pickFailed);
    }
  }

  /// Discard the attached item (the "X" on the preview, #4).
  void removeAttachment() {
    if (state is! AttachmentAttached) return;
    emit(AttachmentEmpty(visionSupported: state.visionSupported));
  }

  /// Hand the attached image to the send path as a base64 [MessageImage] and
  /// reset to empty. Returns null when no image is attached.
  MessageImage? takeImageForSend() {
    final s = state;
    if (s is! AttachmentAttached) return null;
    final image = s.image;
    if (image == null) return null;
    emit(AttachmentEmpty(visionSupported: s.visionSupported));
    return MessageImage(data: base64Encode(image.bytes), mime: image.mime);
  }

  /// Hand the attached text file to the send path (its content travels inline
  /// once) and reset to empty. Returns null when no file is attached.
  OutgoingFile? takeFileForSend() {
    final s = state;
    if (s is! AttachmentAttached) return null;
    final file = s.file;
    if (file == null) return null;
    emit(AttachmentEmpty(visionSupported: s.visionSupported));
    return OutgoingFile(name: file.name, text: file.text);
  }

  // ---------------------------------------------------------------------------
  // Vision tracking (#9)
  // ---------------------------------------------------------------------------

  Future<void> _refreshVision() async {
    if (_resolvingVision) return;
    _resolvingVision = true;
    try {
      // Cached per (peer, room) by the repo; only the round-trip after a real
      // model change actually hits the Pi.
      final catalogue = await _actions.listModels();
      _setVision(_resolveVision(catalogue));
    } catch (_) {
      // Offline / no catalogue yet → leave vision unknown (don't gate).
    } finally {
      _resolvingVision = false;
    }
  }

  bool? _resolveVision(ModelsCatalogue catalogue) {
    final current = catalogue.current;
    if (current != null) return current.vision;
    // No explicit current — match the active room's model name.
    final name = _actions.activeRoomMeta.model;
    if (name != null) {
      for (final m in catalogue.models) {
        if (m.name == name) return m.vision;
      }
    }
    return null;
  }

  void _setVision(bool? vision) {
    if (vision == state.visionSupported) return;
    emit(switch (state) {
      AttachmentEmpty() => AttachmentEmpty(visionSupported: vision),
      AttachmentPicking() => AttachmentPicking(visionSupported: vision),
      AttachmentAttached(:final payload) => AttachmentAttached(
        payload: payload,
        visionSupported: vision,
      ),
    });
  }

  @override
  void dispose() {
    _metaSub?.cancel();
    _hints.close();
    super.dispose();
  }
}
