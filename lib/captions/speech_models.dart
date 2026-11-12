import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

/// How careful the speech recognition is (bigger models are more accurate
/// but slower and a bigger one-time download).
enum CaptionAccuracy {
  fast('Fast'),
  standard('Standard'),
  best('Best');

  const CaptionAccuracy(this.label);
  final String label;
}

/// One downloadable speech model (whisper.cpp "ggml" file).
class SpeechModel {
  const SpeechModel(this.file, this.bytes, this.sha256);

  final String file;
  final int bytes;
  final String sha256;

  String get url =>
      'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$file';

  /// "60 MB".
  String get sizeLabel => '${(bytes / 1e6).round()} MB';

  /// English-only models are more accurate for English; the others
  /// recognise about 100 languages.
  static SpeechModel of(CaptionAccuracy a, {required bool english}) =>
      switch ((a, english)) {
        (CaptionAccuracy.fast, true) => const SpeechModel(
          'ggml-tiny.en-q5_1.bin',
          32166155,
          'c77c5766f1cef09b6b7d47f21b546cbddd4157886b3b5d6d4f709e91e66c7c2b',
        ),
        (CaptionAccuracy.standard, true) => const SpeechModel(
          'ggml-base.en-q5_1.bin',
          59721011,
          '4baf70dd0d7c4247ba2b81fafd9c01005ac77c2f9ef064e00dcf195d0e2fdd2f',
        ),
        (CaptionAccuracy.best, true) => const SpeechModel(
          'ggml-small.en-q5_1.bin',
          190098681,
          'bfdff4894dcb76bbf647d56263ea2a96645423f1669176f4844a1bf8e478ad30',
        ),
        (CaptionAccuracy.fast, false) => const SpeechModel(
          'ggml-tiny-q5_1.bin',
          32152673,
          '818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7',
        ),
        (CaptionAccuracy.standard, false) => const SpeechModel(
          'ggml-base-q5_1.bin',
          59707625,
          '422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898',
        ),
        (CaptionAccuracy.best, false) => const SpeechModel(
          'ggml-small-q5_1.bin',
          190085487,
          'ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb',
        ),
      };
}

/// Keeps speech models on the device (downloaded once, then used offline).
class SpeechModelStore {
  SpeechModelStore({Future<Directory> Function()? folder})
    : _folder = folder ?? _defaultFolder;

  final Future<Directory> Function() _folder;

  static Future<Directory> _defaultFolder() async {
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}${Platform.pathSeparator}speech');
  }

  Future<File> _fileFor(SpeechModel m) async {
    final dir = await _folder();
    return File('${dir.path}${Platform.pathSeparator}${m.file}');
  }

  /// The model's file if it's already on the device.
  Future<String?> pathIfPresent(SpeechModel m) async {
    final f = await _fileFor(m);
    return await f.exists() && await f.length() == m.bytes ? f.path : null;
  }

  /// Downloads [m] (once), checking its fingerprint. [onProgress] gets
  /// 0–1. Returns the file's path.
  Future<String> ensure(
    SpeechModel m, {
    void Function(double fraction)? onProgress,
    bool Function()? cancelled,
  }) async {
    final have = await pathIfPresent(m);
    if (have != null) return have;
    final file = await _fileFor(m);
    await file.parent.create(recursive: true);
    final part = File('${file.path}.part');
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(m.url));
      final response = await request.close();
      if (response.statusCode != 200) {
        throw HttpException(
          'The speech model could not be downloaded (error '
          '${response.statusCode}).',
        );
      }
      final out = part.openWrite();
      final digest = _DigestSink();
      final hasher = sha256.startChunkedConversion(digest);
      var got = 0;
      try {
        await for (final chunk in response) {
          if (cancelled?.call() ?? false) throw const _Cancelled();
          out.add(chunk);
          hasher.add(chunk);
          got += chunk.length;
          onProgress?.call((got / m.bytes).clamp(0.0, 1.0));
        }
      } finally {
        await out.close();
      }
      hasher.close();
      if (got != m.bytes || digest.value.toString() != m.sha256) {
        await part.delete();
        throw const HttpException(
          'The downloaded speech model was damaged. Please try again.',
        );
      }
      await part.rename(file.path);
      return file.path;
    } on _Cancelled {
      if (await part.exists()) await part.delete();
      rethrow;
    } finally {
      client.close(force: true);
    }
  }
}

/// Thrown when a download or recognition is cancelled.
class _Cancelled implements Exception {
  const _Cancelled();
}

/// Whether [e] is a cancellation (not a real failure).
bool isCancellation(Object e) => e is _Cancelled || e is CaptionsCancelled;

/// Thrown when making captions is cancelled.
class CaptionsCancelled implements Exception {
  const CaptionsCancelled();
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
