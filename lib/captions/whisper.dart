import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../model/captions.dart';

typedef _TranscribeC = Pointer<Utf8> Function(
  Pointer<Utf8> model,
  Pointer<Float> samples,
  Int32 count,
  Pointer<Utf8> language,
  Int32 threads,
  Pointer<NativeFunction<Void Function(Int32)>> progress,
);
typedef _TranscribeDart = Pointer<Utf8> Function(
  Pointer<Utf8>,
  Pointer<Float>,
  int,
  Pointer<Utf8>,
  int,
  Pointer<NativeFunction<Void Function(Int32)>>,
);

/// The speech recognizer (whisper.cpp, built into the app as
/// libvc_captions.so / vc_captions.dll).
class Whisper {
  Whisper._();

  static final instance = Whisper._();

  /// Where the library is: next to the app (Android, Windows), or as set
  /// by VC_CAPTIONS_LIB (tests on a PC).
  static String get libraryPath =>
      Platform.environment['VC_CAPTIONS_LIB'] ??
      (Platform.isWindows ? 'vc_captions.dll' : 'libvc_captions.so');

  DynamicLibrary? _lib;

  DynamicLibrary get _library => _lib ??= DynamicLibrary.open(libraryPath);

  /// True if the recognizer is part of this build.
  bool get available {
    try {
      _library;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Stops [transcribe] early (it then returns null).
  void cancel() {
    try {
      _library.lookupFunction<Void Function(), void Function()>('vc_cancel')();
    } catch (_) {}
  }

  /// Recognises the words in [samples] (16 kHz mono). Times in the result
  /// are from the start of [samples]. Returns null if cancelled.
  Future<({String language, List<SpokenWord> words})?> transcribe(
    String modelPath,
    Float32List samples, {
    String language = 'auto',
    int? threads,
    void Function(int percent)? onProgress,
  }) async {
    final lib = libraryPath;
    final cores = Platform.numberOfProcessors;
    // Phones: the fast cores only; PCs: half the cores, at most 8.
    final n =
        threads ??
        (Platform.isAndroid ? cores.clamp(1, 4) : (cores ~/ 2).clamp(2, 8));
    final listener = NativeCallable<Void Function(Int32)>.listener((int p) {
      onProgress?.call(p);
    });
    final progressAddress = listener.nativeFunction.address;
    try {
      final json = await _inBackground(
        lib,
        modelPath,
        samples,
        language,
        n,
        progressAddress,
      );
      final map = jsonDecode(json) as Map<String, Object?>;
      if (map['cancelled'] == true) return null;
      if (map['error'] != null) throw Exception(map['error']);
      return (
        language: map['language'] as String? ?? language,
        words: [
          for (final w in map['words'] as List)
            SpokenWord(
              ((w as Map)['s'] as num).toInt() * 1000,
              (w['e'] as num).toInt() * 1000,
              w['w'] as String,
            ),
        ],
      );
    } finally {
      listener.close();
    }
  }

  /// Runs the recognizer on another isolate. A separate function on
  /// purpose: the closure given to Isolate.run may only hold these plain
  /// values (a closure made inside [transcribe] would also carry [this] and
  /// the progress callback, which can't be sent to another isolate).
  static Future<String> _inBackground(
    String lib,
    String modelPath,
    Float32List samples,
    String language,
    int threads,
    int progressAddress,
  ) => Isolate.run(
    () => _run(lib, modelPath, samples, language, threads, progressAddress),
  );

  static String _run(
    String libPath,
    String modelPath,
    Float32List samples,
    String language,
    int threads,
    int progressAddress,
  ) {
    final lib = DynamicLibrary.open(libPath);
    final transcribe = lib.lookupFunction<_TranscribeC, _TranscribeDart>(
      'vc_transcribe',
    );
    final free = lib
        .lookupFunction<
          Void Function(Pointer<Utf8>),
          void Function(Pointer<Utf8>)
        >('vc_free');
    final buffer = calloc<Float>(samples.isEmpty ? 1 : samples.length);
    final model = modelPath.toNativeUtf8();
    final lang = language.toNativeUtf8();
    try {
      buffer.asTypedList(samples.length).setAll(0, samples);
      final result = transcribe(
        model,
        buffer,
        samples.length,
        lang,
        threads,
        Pointer.fromAddress(progressAddress),
      );
      final text = result.toDartString();
      free(result);
      return text;
    } finally {
      calloc.free(buffer);
      calloc.free(model);
      calloc.free(lang);
    }
  }
}

/// Reads a file of 32-bit little-endian floats (as written by
/// MediaEngine.speechAudio).
Future<Float32List> readSpeechSamples(String path) async {
  final bytes = await File(path).readAsBytes();
  final data = ByteData.sublistView(bytes);
  final out = Float32List(bytes.length ~/ 4);
  for (var i = 0; i < out.length; i++) {
    out[i] = data.getFloat32(i * 4, Endian.little);
  }
  return out;
}
