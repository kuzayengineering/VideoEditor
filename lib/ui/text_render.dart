import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../engine/media_engine.dart';
import '../model/project.dart';

/// Lays out a text overlay for a frame [frameHeight] pixels tall.
///
/// [visibleChars] hides the letters after that many (typewriter) without
/// moving the rest, so the text doesn't shift as it types. [stroke] draws
/// the letters as an outline with that paint instead of filling them.
TextPainter layoutText(
  TextSpec s,
  double frameHeight, {
  int? visibleChars,
  Paint? stroke,
}) {
  final fontSize = s.size * frameHeight * s.scale;
  final base = TextStyle(
    fontFamily: s.font,
    fontSize: fontSize,
    fontWeight: s.bold ? FontWeight.w700 : FontWeight.w400,
    fontVariations: [FontVariation('wght', s.bold ? 700 : 400)],
    fontStyle: s.italic ? FontStyle.italic : FontStyle.normal,
    height: 1.15,
  );
  TextStyle visible() => stroke != null
      ? base.copyWith(foreground: stroke)
      : base.copyWith(
          color: Color(s.colorValue),
          shadows: s.shadow
              ? [
                  Shadow(
                    blurRadius: fontSize * 0.12,
                    color: Colors.black.withValues(alpha: 0.55),
                    offset: Offset(0, fontSize * 0.05),
                  ),
                ]
              : null,
        );
  TextStyle hidden() => stroke != null
      ? base.copyWith(foreground: Paint()..color = Colors.transparent)
      : base.copyWith(color: Colors.transparent);
  final runes = s.text.runes.toList();
  final shown = (visibleChars ?? runes.length).clamp(0, runes.length);
  final span = TextSpan(
    children: [
      TextSpan(text: String.fromCharCodes(runes.take(shown)), style: visible()),
      if (shown < runes.length)
        TextSpan(
          text: String.fromCharCodes(runes.skip(shown)),
          style: hidden(),
        ),
    ],
  );
  return TextPainter(
    text: span,
    textAlign: switch (s.align) {
      TextAlignSpec.left => TextAlign.left,
      TextAlignSpec.center => TextAlign.center,
      TextAlignSpec.right => TextAlign.right,
    },
    textDirection: TextDirection.ltr,
  )..layout();
}

/// Size of the text block (box and outline included), before rotation.
Size textBlockSize(TextSpec s, double frameHeight) {
  final tp = layoutText(s, frameHeight);
  final fontSize = s.size * frameHeight * s.scale;
  final pad = _padding(s, fontSize);
  return Size(tp.width + pad * 2, tp.height + pad * 2);
}

double _padding(TextSpec s, double fontSize) =>
    (s.boxColorValue != null ? fontSize * 0.3 : 0) +
    s.outline * fontSize +
    (s.shadow ? fontSize * 0.15 : 0) +
    2;

/// Draws a text overlay centred on the canvas origin, for a frame
/// [frameHeight] pixels tall. Used both for the on-screen preview and for
/// the pictures that go into the export, so they match exactly.
void paintText(
  Canvas canvas,
  TextSpec s,
  double frameHeight, {
  int? visibleChars,
}) {
  final fontSize = s.size * frameHeight * s.scale;
  final tp = layoutText(s, frameHeight, visibleChars: visibleChars);
  canvas.save();
  canvas.rotate(s.rotation * math.pi / 180);
  final topLeft = Offset(-tp.width / 2, -tp.height / 2);
  final box = s.boxColorValue;
  if (box != null) {
    final pad = fontSize * 0.3;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          topLeft.dx - pad,
          topLeft.dy - pad * 0.6,
          tp.width + pad * 2,
          tp.height + pad * 1.2,
        ),
        Radius.circular(fontSize * 0.25),
      ),
      Paint()..color = Color(box),
    );
  }
  if (s.outline > 0) {
    // The outline is a thick stroke drawn first; the letters go on top.
    layoutText(
      s,
      frameHeight,
      visibleChars: visibleChars,
      stroke: Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = s.outline * fontSize * 2
        ..strokeJoin = StrokeJoin.round
        ..color = Color(s.outlineColorValue),
    ).paint(canvas, topLeft);
  }
  tp.paint(canvas, topLeft);
  canvas.restore();
}

Future<String> _renderPng(
  TextSpec s,
  double frameHeight,
  int w,
  int h,
  String path, {
  int? visibleChars,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.translate(w / 2, h / 2);
  paintText(canvas, s, frameHeight, visibleChars: visibleChars);
  final image = await recorder.endRecording().toImage(w, h);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  await File(path).writeAsBytes(bytes!.buffer.asUint8List(), flush: true);
  return path;
}

/// Draws every text overlay of [project] as transparent PNG pictures for a
/// frame of [frameWidth]×[frameHeight] pixels, into [dir].
Future<Map<int, TextImages>> renderTextImages(
  Project project,
  int frameWidth,
  int frameHeight,
  Directory dir,
) async {
  await dir.create(recursive: true);
  final out = <int, TextImages>{};
  for (final t in project.textTracks) {
    for (final c in t.clips) {
      final s = c.text;
      if (s == null || s.text.trim().isEmpty) continue;
      // Big enough for the rotated block.
      final block = textBlockSize(s, frameHeight.toDouble());
      final a = s.rotation * math.pi / 180;
      final w =
          (block.width * math.cos(a).abs() + block.height * math.sin(a).abs())
              .ceil() +
          4;
      final h =
          (block.width * math.sin(a).abs() + block.height * math.cos(a).abs())
              .ceil() +
          4;
      final evenW = w + w % 2, evenH = h + h % 2;
      final base = '${dir.path}/text_${c.id}';
      final full = await _renderPng(
        s,
        frameHeight.toDouble(),
        evenW,
        evenH,
        '$base.png',
      );
      final steps = <String>[];
      if (s.animIn == TextAnim.typewriter || s.animOut == TextAnim.typewriter) {
        final n = s.text.runes.length;
        for (var i = 0; i <= n; i++) {
          steps.add(
            await _renderPng(
              s,
              frameHeight.toDouble(),
              evenW,
              evenH,
              '${base}_tw${i.toString().padLeft(4, '0')}.png',
              visibleChars: i,
            ),
          );
        }
      }
      out[c.id] = TextImages(
        fullPath: full,
        width: evenW,
        height: evenH,
        typewriterPaths: steps,
      );
    }
  }
  return out;
}
