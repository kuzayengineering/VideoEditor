import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

/// Google's MediaPipe "selfie multiclass" model (Apache 2.0), which finds
/// hair, skin and clothes in a picture. 16 MB, so it's downloaded the first
/// time Recolour is used (checked against its fingerprint); after that it
/// runs on the device with no connection, and no video ever leaves it.
class PartsModel {
  PartsModel._();
  static final instance = PartsModel._();

  static const url =
      'https://storage.googleapis.com/mediapipe-models/image_segmenter/'
      'selfie_multiclass_256x256/float32/1/selfie_multiclass_256x256.tflite';
  static const bytes = 16371837;
  static const sha256Hex =
      'c6748b1253a99067ef71f7e26ca71096cd449baefa8f101900ea23016507e0e0';

  String? _path;

  /// The model's file once it is on the device (see [check]).
  String? get path => _path;

  Future<File> _file() async => File(
    '${(await getApplicationSupportDirectory()).path}'
    '${Platform.pathSeparator}models'
    '${Platform.pathSeparator}selfie_multiclass_256x256.tflite',
  );

  /// Looks for an earlier download. Returns true if it's there.
  Future<bool> check() async {
    final f = await _file();
    if (await f.exists() && await f.length() == bytes) {
      _path = f.path;
      return true;
    }
    return false;
  }

  /// Downloads the model (once). [onProgress] gets 0–1.
  Future<String> ensure({void Function(double fraction)? onProgress}) async {
    if (await check()) return _path!;
    final file = await _file();
    await file.parent.create(recursive: true);
    final part = File('${file.path}.part');
    final client = HttpClient();
    try {
      final HttpClientResponse response;
      try {
        response = await (await client.getUrl(Uri.parse(url))).close();
      } on SocketException {
        throw const HttpException(
          'Could not connect to download the recolour model. Check that the '
          'device is online (it is only needed for this one-time download).',
        );
      }
      if (response.statusCode != 200) {
        throw HttpException(
          'The recolour model could not be downloaded '
          '(error ${response.statusCode}).',
        );
      }
      final out = part.openWrite();
      final digest = _DigestSink();
      final hasher = sha256.startChunkedConversion(digest);
      var got = 0;
      try {
        await for (final chunk in response) {
          out.add(chunk);
          hasher.add(chunk);
          got += chunk.length;
          onProgress?.call((got / bytes).clamp(0.0, 1.0));
        }
      } on SocketException {
        throw const HttpException(
          'The download was interrupted. Please try again.',
        );
      } finally {
        await out.close();
      }
      hasher.close();
      if (got != bytes || digest.value.toString() != sha256Hex) {
        throw const HttpException(
          'The downloaded model was damaged. Please try again.',
        );
      }
      await part.rename(file.path);
      _path = file.path;
      return file.path;
    } finally {
      if (await part.exists()) await part.delete();
      client.close(force: true);
    }
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
