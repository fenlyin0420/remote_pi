// Plan/30 — AttachmentViewModel: pick / remove / take + vision gating,
// against fake picker + actions repositories.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:app/data/actions/actions_repository.dart';
import 'package:app/data/files/text_file_picker_service.dart';
import 'package:app/data/images/image_picker_service.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/chat/attachment/states/attachment_state.dart';
import 'package:app/ui/chat/attachment/viewmodels/attachment_viewmodel.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakePicker implements IImagePickerService {
  PickedImage? next = PickedImage(
    bytes: Uint8List.fromList([1, 2, 3]),
    mime: 'image/jpeg',
  );
  bool denyCamera = false;
  bool fail = false;

  @override
  Future<PickedImage?> pickFromCamera() async {
    if (denyCamera) throw const ImagePermissionDeniedException();
    if (fail) throw Exception('boom');
    return next;
  }

  @override
  Future<PickedImage?> pickFromGallery() async {
    if (fail) throw Exception('boom');
    return next;
  }
}

class _FakeFilePicker implements ITextFilePickerService {
  PickedTextFile? next = const PickedTextFile(
    name: 'notes.md',
    text: '# hi',
    byteLength: 4,
  );
  bool notText = false;

  @override
  Future<PickedTextFile?> pickTextFile() async {
    if (notText) throw const NotTextFileException('photo.jpg');
    return next;
  }
}

class _FakeActions implements IActionsRepository {
  ModelsCatalogue catalogue = const ModelsCatalogue(models: [], current: null);
  ActiveRoomMeta meta = const ActiveRoomMeta();
  final _metaCtrl = StreamController<ActiveRoomMeta>.broadcast();
  bool offline = false;

  void pushMeta(ActiveRoomMeta m) {
    meta = m;
    _metaCtrl.add(m);
  }

  @override
  Future<ModelsCatalogue> listModels({bool forceRefresh = false}) async {
    if (offline) throw const ActionFailure('offline');
    return catalogue;
  }

  @override
  ActiveRoomMeta get activeRoomMeta => meta;

  @override
  Stream<ActiveRoomMeta> get activeRoomMetaStream => _metaCtrl.stream;

  @override
  void dispose() => _metaCtrl.close();

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

WireModel _model({required bool vision, String name = 'M'}) => WireModel(
  id: 'id-$name',
  name: name,
  provider: 'p',
  reasoning: false,
  contextWindow: 1,
  vision: vision,
);

void main() {
  test('pickFromGallery attaches an image; removeImage clears it', () async {
    final vm = AttachmentViewModel(_FakePicker(), _FakeFilePicker(), _FakeActions());
    await vm.pickFromGallery();
    expect(vm.state, isA<AttachmentAttached>());
    expect(vm.hasImage, isTrue);

    vm.removeAttachment();
    expect(vm.state, isA<AttachmentEmpty>());
    expect(vm.hasImage, isFalse);
    vm.dispose();
  });

  test('takeImageForSend returns base64 MessageImage and resets', () async {
    final picker = _FakePicker()
      ..next = PickedImage(
        bytes: Uint8List.fromList([10, 20, 30]),
        mime: 'image/jpeg',
      );
    final vm = AttachmentViewModel(picker, _FakeFilePicker(), _FakeActions());
    await vm.pickFromGallery();

    final msg = vm.takeImageForSend();
    expect(msg, isNotNull);
    expect(msg!.mime, 'image/jpeg');
    expect(base64Decode(msg.data), [10, 20, 30]);
    expect(vm.state, isA<AttachmentEmpty>());
    expect(vm.takeImageForSend(), isNull); // nothing left
    vm.dispose();
  });

  test('denied camera permission emits a hint and stays empty', () async {
    final picker = _FakePicker()..denyCamera = true;
    final vm = AttachmentViewModel(picker, _FakeFilePicker(), _FakeActions());
    final hints = <AttachHint>[];
    final sub = vm.hints.listen(hints.add);

    await vm.pickFromCamera();
    await Future<void>.delayed(Duration.zero);

    expect(vm.state, isA<AttachmentEmpty>());
    expect(hints, [AttachHint.cameraPermissionDenied]);
    await sub.cancel();
    vm.dispose();
  });

  test('vision=false from catalogue blocks the attach affordance', () async {
    final actions = _FakeActions()
      ..catalogue = ModelsCatalogue(
        models: [_model(vision: false)],
        current: _model(vision: false),
      );
    final vm = AttachmentViewModel(_FakePicker(), _FakeFilePicker(), actions);
    await Future<void>.delayed(Duration.zero); // let init resolve vision

    expect(vm.state.visionSupported, isFalse);
    expect(vm.imageBlockedByVision, isTrue);
    vm.dispose();
  });

  test('vision=true does not block', () async {
    final actions = _FakeActions()
      ..catalogue = ModelsCatalogue(
        models: [_model(vision: true)],
        current: _model(vision: true),
      );
    final vm = AttachmentViewModel(_FakePicker(), _FakeFilePicker(), actions);
    await Future<void>.delayed(Duration.zero);

    expect(vm.state.visionSupported, isTrue);
    expect(vm.imageBlockedByVision, isFalse);
    vm.dispose();
  });

  test('offline catalogue leaves vision unknown (does not block)', () async {
    final actions = _FakeActions()..offline = true;
    final vm = AttachmentViewModel(_FakePicker(), _FakeFilePicker(), actions);
    await Future<void>.delayed(Duration.zero);

    expect(vm.state.visionSupported, isNull);
    expect(vm.imageBlockedByVision, isFalse);
    vm.dispose();
  });

  test('a model change re-resolves vision', () async {
    final actions = _FakeActions()
      ..catalogue = ModelsCatalogue(
        models: [_model(vision: true)],
        current: _model(vision: true),
      );
    final vm = AttachmentViewModel(_FakePicker(), _FakeFilePicker(), actions);
    await Future<void>.delayed(Duration.zero);
    expect(vm.state.visionSupported, isTrue);

    // Pi switched to a text-only model.
    actions.catalogue = ModelsCatalogue(
      models: [_model(vision: false, name: 'TextOnly')],
      current: _model(vision: false, name: 'TextOnly'),
    );
    actions.pushMeta(const ActiveRoomMeta(model: 'TextOnly'));
    await Future<void>.delayed(Duration.zero);

    expect(vm.state.visionSupported, isFalse);
    vm.dispose();
  });

  test('pickTextFile attaches a file; the file never counts as an image', () async {
    final vm = AttachmentViewModel(_FakePicker(), _FakeFilePicker(), _FakeActions());
    await vm.pickTextFile();
    expect(vm.state, isA<AttachmentAttached>());
    expect(vm.hasAttachment, isTrue);
    expect(vm.hasImage, isFalse);
    expect((vm.state as AttachmentAttached).file?.name, 'notes.md');
    vm.dispose();
  });

  test('takeFileForSend returns the outgoing file with its text and resets', () async {
    final vm = AttachmentViewModel(_FakePicker(), _FakeFilePicker(), _FakeActions());
    await vm.pickTextFile();

    final file = vm.takeFileForSend();
    expect(file, isNotNull);
    expect(file!.name, 'notes.md');
    expect(file.text, '# hi');
    expect(vm.state, isA<AttachmentEmpty>());
    expect(vm.takeFileForSend(), isNull); // nothing left
    vm.dispose();
  });

  test('a binary pick is refused with a notTextFile hint and stays empty', () async {
    final vm = AttachmentViewModel(
      _FakePicker(),
      _FakeFilePicker()..notText = true,
      _FakeActions(),
    );
    final hints = <AttachHint>[];
    final sub = vm.hints.listen(hints.add);

    await vm.pickTextFile();
    await Future<void>.delayed(Duration.zero);

    expect(vm.state, isA<AttachmentEmpty>());
    expect(hints, [AttachHint.notTextFile]);
    await sub.cancel();
    vm.dispose();
  });

  test('a text-only model still allows files (vision gates images only)', () async {
    final actions = _FakeActions()
      ..catalogue = ModelsCatalogue(
        models: [_model(vision: false)],
        current: _model(vision: false),
      );
    final vm = AttachmentViewModel(_FakePicker(), _FakeFilePicker(), actions);
    await Future<void>.delayed(Duration.zero);

    expect(vm.imageBlockedByVision, isTrue);
    await vm.pickTextFile();
    expect(vm.state, isA<AttachmentAttached>());
    expect((vm.state as AttachmentAttached).file?.name, 'notes.md');
    vm.dispose();
  });
}
