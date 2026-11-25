import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

/// A model file downloaded once (checked against its fingerprint) and then
/// used on the device with no connection: no video ever leaves it. All are
/// Google's MediaPipe models (Apache 2.0).
class DownloadableModel {
  DownloadableModel._(
    this.label,
    this.usedFor,
    this.url,
    this.bytes,
    this.sha256Hex,
    this.fileName,
  );

  final String label;
  final String usedFor;
  final String url;
  final int bytes;
  final String sha256Hex;
  final String fileName;

  /// Hair, skin and clothes (Recolour; also skin for Outfit).
  static final parts = DownloadableModel._(
    'People\'s hair, skin and clothes',
    'Recolor, Outfit',
    'https://storage.googleapis.com/mediapipe-models/image_segmenter/'
        'selfie_multiclass_256x256/float32/1/selfie_multiclass_256x256.tflite',
    16371837,
    'c6748b1253a99067ef71f7e26ca71096cd449baefa8f101900ea23016507e0e0',
    'selfie_multiclass_256x256.tflite',
  );

  /// Faces with irises (Eye colour).
  static final face = DownloadableModel._(
    'Faces and eyes',
    'Eye color',
    'https://storage.googleapis.com/mediapipe-models/face_landmarker/'
        'face_landmarker/float16/1/face_landmarker.task',
    3758596,
    '64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff',
    'face_landmarker.task',
  );

  /// Body joints (Outfit).
  static final pose = DownloadableModel._(
    'Body joints',
    'Outfit',
    'https://storage.googleapis.com/mediapipe-models/pose_landmarker/'
        'pose_landmarker_full/float16/1/pose_landmarker_full.task',
    9398198,
    '5134a3aad27a58b93da0088d431f366da362b44e3ccfbe3462b3827a839011b1',
    'pose_landmarker_full.task',
  );

  static List<DownloadableModel> get all => [parts, face, pose];

  String? _path;

  /// The model's file once it is on the device (see [check]).
  String? get path => _path;

  String get sizeLabel => '${(bytes / 1e6).toStringAsFixed(1)} MB';

  Future<File> _file() async => File(
    '${(await getApplicationSupportDirectory()).path}'
    '${Platform.pathSeparator}models'
    '${Platform.pathSeparator}$fileName',
  );

  /// Looks for an earlier download. Returns true if it's there.
  Future<bool> check() async {
    final f = await _file();
    if (await f.exists() && await f.length() == bytes) {
      _path = f.path;
      return true;
    }
    _path = null;
    return false;
  }

  /// Removes the download (it can be downloaded again when needed).
  Future<void> delete() async {
    final f = await _file();
    if (await f.exists()) await f.delete();
    _path = null;
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
          'Could not connect to download the model. Check that the device '
          'is online (it is only needed for this one-time download).',
        );
      }
      if (response.statusCode != 200) {
        throw HttpException(
          'The model could not be downloaded (error ${response.statusCode}).',
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

/// The hair, skin and clothes model (kept under its earlier name).
abstract final class PartsModel {
  static DownloadableModel get instance => DownloadableModel.parts;
}

class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
