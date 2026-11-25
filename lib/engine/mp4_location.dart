import 'dart:io';
import 'dart:typed_data';

/// Writes where a video was filmed into an MP4 file, the way phones do: a
/// "©xyz" entry (ISO 6709 text such as "+37.4219-122.0840/") in the
/// movie's user-data box, which galleries such as Google Photos read.
///
/// The video and sound data are never moved: the movie box is rewritten in
/// place when there is room (it is the last box, or followed by free
/// space); otherwise the old one is marked free and the new one goes at
/// the end of the file. Android's exporter does the same (Mp4Location.kt).
Future<void> setMp4Location(File file, String iso6709) async {
  final raf = await file.open(mode: FileMode.append);
  try {
    final length = await raf.length();
    // Top-level boxes.
    final boxes = <(String, int, int)>[]; // type, position, size
    var pos = 0;
    while (pos + 8 <= length) {
      await raf.setPosition(pos);
      final head = await raf.read(16);
      if (head.length < 8) break;
      final view = ByteData.sublistView(Uint8List.fromList(head));
      var size = view.getUint32(0);
      final type = String.fromCharCodes(head.sublist(4, 8));
      if (size == 1 && head.length >= 16) {
        size = view.getUint64(8);
      } else if (size == 0) {
        size = length - pos;
      }
      if (size < 8 || pos + size > length) break;
      boxes.add((type, pos, size));
      pos += size;
    }
    final i = boxes.indexWhere((b) => b.$1 == 'moov');
    if (i < 0) return;
    final (_, moovPos, moovSize) = boxes[i];
    await raf.setPosition(moovPos);
    final moov = Uint8List.fromList(await raf.read(moovSize));
    // (A 64-bit size header on the movie box: leave the file alone.)
    if (ByteData.sublistView(moov).getUint32(0) == 1) return;
    final updated = moovWithLocation(moov, iso6709);

    final next = i + 1 < boxes.length ? boxes[i + 1] : null;
    if (next == null) {
      // The last box: rewrite it, the file grows.
      await raf.truncate(moovPos);
      await raf.setPosition(moovPos);
      await raf.writeFrom(updated);
      return;
    }
    if (next.$1 == 'free') {
      final room = moovSize + next.$3 - updated.length;
      if (room == 0 || room >= 8) {
        await raf.setPosition(moovPos);
        await raf.writeFrom(updated);
        if (room >= 8) await raf.writeFrom(_box('free', Uint8List(room - 8)));
        return;
      }
    }
    // No room in place: mark the old movie box free, add the new one at the
    // end (nothing else moves, so every data offset stays right).
    await raf.setPosition(moovPos + 4);
    await raf.writeFrom('free'.codeUnits);
    await raf.setPosition(length);
    await raf.writeFrom(updated);
  } finally {
    await raf.close();
  }
}

/// [moov] (a whole "moov" box) with a "©xyz" location in its "udta" box
/// (replacing any earlier one; adding the "udta" box if there is none).
Uint8List moovWithLocation(Uint8List moov, String iso6709) {
  final text = Uint8List.fromList(iso6709.codeUnits);
  final xyzBody = BytesBuilder()
    ..add(_u16(text.length))
    ..add(_u16(0x15c7)) // language: English, as phones write it
    ..add(text);
  final xyz = _box('©xyz', xyzBody.toBytes());

  final children = _children(moov, 8, moov.length);
  final out = BytesBuilder();
  var hadUdta = false;
  for (final (type, start, end) in children) {
    if (type == 'udta') {
      hadUdta = true;
      final inner = BytesBuilder();
      for (final (t, s, e) in _children(moov, start + 8, end)) {
        if (t != '©xyz') inner.add(moov.sublist(s, e));
      }
      inner.add(xyz);
      out.add(_box('udta', inner.toBytes()));
    } else {
      out.add(moov.sublist(start, end));
    }
  }
  if (!hadUdta) out.add(_box('udta', xyz));
  return _box('moov', out.toBytes());
}

List<(String, int, int)> _children(Uint8List d, int start, int end) {
  final view = ByteData.sublistView(d);
  final out = <(String, int, int)>[];
  var pos = start;
  while (pos + 8 <= end) {
    final size = view.getUint32(pos);
    if (size < 8 || pos + size > end) break;
    out.add((
      String.fromCharCodes(d.sublist(pos + 4, pos + 8)),
      pos,
      pos + size,
    ));
    pos += size;
  }
  return out;
}

Uint8List _box(String type, Uint8List body) {
  final b = BytesBuilder()
    ..add(_u32(body.length + 8))
    ..add(type.codeUnits.map((c) => c & 0xff).toList())
    ..add(body);
  return b.toBytes();
}

Uint8List _u32(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v);
Uint8List _u16(int v) => Uint8List(2)..buffer.asByteData().setUint16(0, v);
