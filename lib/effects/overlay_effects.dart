import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../model/clip.dart';

/// The kinds of effect the picker shows as tabs.
enum EffectGroup {
  fire('Fire'),
  sparks('Sparks'),
  smoke('Smoke'),
  light('Light leaks'),
  bokeh('Bokeh'),
  film('Film'),
  weather('Weather'),
  particles('Particles'),
  other('Other');

  const EffectGroup(this.label);
  final String label;

  static EffectGroup byName(String? n) =>
      values.firstWhere((g) => g.name == n, orElse: () => other);
}

/// One overlay effect: real filmed footage (fire, sparks, dust...) that is
/// downloaded the first time it's used and laid over the video as a
/// full-frame picture-in-picture clip with a blend mode (Screen for effects
/// filmed on black, Multiply for effects on white).
class OverlayEffect {
  const OverlayEffect({
    required this.id,
    required this.title,
    required this.group,
    required this.blend,
    required this.file,
    required this.bytes,
    required this.sha256,
    this.thumb,
  });

  final String id;
  final String title;
  final EffectGroup group;
  final PipBlend blend;

  /// File name in the effects release (see [OverlayLibrary.baseUrl]).
  final String file;
  final int bytes;
  final String sha256;

  /// Small picture in the app (assets/overlays/...), if there is one.
  final String? thumb;

  factory OverlayEffect.fromJson(Map<String, Object?> j) => OverlayEffect(
    id: j['id'] as String,
    title: j['title'] as String,
    group: EffectGroup.byName(j['group'] as String?),
    blend: PipBlend.values.firstWhere(
      (b) => b.name == j['blend'],
      orElse: () => PipBlend.screen,
    ),
    file: j['file'] as String,
    bytes: (j['bytes'] as num).toInt(),
    sha256: j['sha256'] as String,
    thumb: j['thumb'] as String?,
  );
}

/// The effects list (in the app) and the downloaded files (on the device).
class OverlayLibrary {
  OverlayLibrary._();
  static final instance = OverlayLibrary._();

  /// Where the effect files are kept online.
  static const baseUrl =
      'https://github.com/kuzayengineering/VideoEditor/releases/download/overlays-v1/';

  List<OverlayEffect>? _catalog;

  Future<List<OverlayEffect>> catalog() async {
    final have = _catalog;
    if (have != null) return have;
    final text = await rootBundle.loadString('assets/overlays/catalog.json');
    final list = (jsonDecode(text) as List)
        .map((e) => OverlayEffect.fromJson((e as Map).cast<String, Object?>()))
        .toList();
    return _catalog = list;
  }

  Future<Directory> _folder() async => Directory(
    '${(await getApplicationSupportDirectory()).path}'
    '${Platform.pathSeparator}effects',
  );

  Future<File> _fileFor(OverlayEffect e) async {
    final dir = await _folder();
    return File('${dir.path}${Platform.pathSeparator}${e.file}');
  }

  /// The effect's file if it's already on the device.
  Future<String?> pathIfPresent(OverlayEffect e) async {
    final f = await _fileFor(e);
    return await f.exists() && await f.length() == e.bytes ? f.path : null;
  }

  /// Downloads [e] (once), checking its fingerprint. Returns its path.
  Future<String> ensure(
    OverlayEffect e, {
    void Function(double fraction)? onProgress,
  }) async {
    final have = await pathIfPresent(e);
    if (have != null) return have;
    final file = await _fileFor(e);
    await file.parent.create(recursive: true);
    final part = File('${file.path}.part');
    final client = HttpClient();
    try {
      final HttpClientResponse response;
      try {
        final request = await client.getUrl(Uri.parse('$baseUrl${e.file}'));
        response = await request.close();
      } on SocketException {
        throw const HttpException(
          'Could not connect to download the effect. Check that the device '
          'is online (each effect is downloaded once).',
        );
      }
      if (response.statusCode != 200) {
        throw HttpException(
          'The effect could not be downloaded (error ${response.statusCode}).',
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
          onProgress?.call((got / e.bytes).clamp(0.0, 1.0));
        }
      } on SocketException {
        throw const HttpException(
          'The download was interrupted. Please try again.',
        );
      } finally {
        await out.close();
      }
      hasher.close();
      if (got != e.bytes || digest.value.toString() != e.sha256) {
        await part.delete();
        throw const HttpException(
          'The downloaded effect was damaged. Please try again.',
        );
      }
      await part.rename(file.path);
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
