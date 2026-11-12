import 'package:flutter/material.dart';

import '../captions/caption_maker.dart';
import '../captions/speech_models.dart';
import '../captions/whisper.dart';
import '../engine/media_engine.dart';
import '../model/project.dart';
import 'editor_controller.dart';
import 'tool_panel.dart';

/// Ready-made looks for captions (each caption can still be edited).
enum CaptionStyle {
  classic('Classic'),
  yellow('Yellow'),
  box('Box'),
  bold('Bold');

  const CaptionStyle(this.label);
  final String label;

  TextSpec get spec => switch (this) {
    CaptionStyle.classic => const TextSpec(
      size: 0.06,
      outline: 0.08,
      y: 0.86,
      animIn: TextAnim.none,
      animOut: TextAnim.none,
    ),
    CaptionStyle.yellow => const TextSpec(
      size: 0.06,
      colorValue: 0xFFFFD54F,
      outline: 0.08,
      y: 0.86,
      animIn: TextAnim.none,
      animOut: TextAnim.none,
    ),
    CaptionStyle.box => const TextSpec(
      size: 0.055,
      shadow: false,
      boxColorValue: 0xB3000000,
      y: 0.86,
      animIn: TextAnim.none,
      animOut: TextAnim.none,
    ),
    CaptionStyle.bold => const TextSpec(
      font: 'Anton',
      size: 0.08,
      outline: 0.1,
      y: 0.8,
      animIn: TextAnim.pop,
      animInUs: 150000,
      animOut: TextAnim.none,
    ),
  };
}

// Remembered while the app is open.
CaptionAccuracy _accuracy = CaptionAccuracy.standard;
bool _english = true;
CaptionStyle _style = CaptionStyle.classic;

/// Auto captions: listens to the video's speech (on the device) and adds
/// timed, editable texts.
Future<void> showCaptionsSheet(
  BuildContext context,
  EditorController c,
  MediaEngine engine,
) {
  c.pause();
  return showToolPanel(
    context,
    title: 'Auto captions',
    builder: (context) => _CaptionsSheet(c: c, engine: engine),
  );
}

class _CaptionsSheet extends StatefulWidget {
  const _CaptionsSheet({required this.c, required this.engine});

  final EditorController c;
  final MediaEngine engine;

  @override
  State<_CaptionsSheet> createState() => _CaptionsSheetState();
}

class _CaptionsSheetState extends State<_CaptionsSheet> {
  late final CaptionMaker _maker = CaptionMaker(widget.engine);
  late final int? _selectedId = _speakingSelection();
  bool _onlySelected = false;
  bool _working = false;
  String? _status;
  double? _fraction;
  String? _result;
  String? _error;

  EditorController get c => widget.c;

  int? _speakingSelection() {
    final id = c.selectedClipId;
    if (id == null) return null;
    return CaptionMaker.sourcesOf(c.project, clipId: id).isEmpty ? null : id;
  }

  @override
  void dispose() {
    if (_working) _maker.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _working = true;
      _status = 'Getting ready…';
      _fraction = null;
      _result = null;
      _error = null;
    });
    final clipId = _onlySelected ? _selectedId : null;
    try {
      final lines = await _maker.make(
        c.project,
        clipId: clipId,
        accuracy: _accuracy,
        english: _english,
        onStatus: (m, f) {
          if (mounted) {
            setState(() {
              _status = m;
              _fraction = f;
            });
          }
        },
      );
      if (!mounted) return;
      final span = clipId == null ? null : c.project.placementOf(clipId);
      if (lines.isEmpty) {
        setState(() => _result = 'No speech was heard.');
      } else {
        c.apply(
          c.project.withCaptions(
            lines,
            _style.spec,
            fromUs: span?.startUs ?? 0,
            toUs: span?.endUs ?? c.project.durationUs,
          ),
        );
        setState(
          () => _result =
              'Added ${lines.length} caption${lines.length == 1 ? '' : 's'}. '
              'Tap one on the timeline or the video to change its words or '
              'look.',
        );
      }
    } catch (e) {
      if (!mounted) return;
      if (!isCancellation(e)) {
        setState(() => _error = '$e'.replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!Whisper.instance.available) {
      return const Text(
        'Auto captions are not part of this version of the app.',
      );
    }
    final sources = CaptionMaker.sourcesOf(
      c.project,
      clipId: _onlySelected ? _selectedId : null,
    );
    if (_working) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          Text(_status ?? '', style: theme.textTheme.titleSmall),
          const SizedBox(height: 12),
          LinearProgressIndicator(value: _fraction),
          const SizedBox(height: 8),
          Text(
            'Everything happens on this device; nothing is uploaded.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton(
              onPressed: _maker.cancel,
              child: const Text('Cancel'),
            ),
          ),
        ],
      );
    }
    final model = SpeechModel.of(_accuracy, english: _english);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_result != null)
          _Note(text: _result!, color: theme.colorScheme.primary),
        if (_error != null)
          _Note(text: _error!, color: theme.colorScheme.error),
        _label(context, 'Language'),
        Wrap(
          spacing: 8,
          children: [
            ChoiceChip(
              label: const Text('English'),
              selected: _english,
              onSelected: (_) => setState(() => _english = true),
            ),
            ChoiceChip(
              label: const Text('Other languages'),
              selected: !_english,
              onSelected: (_) => setState(() => _english = false),
            ),
          ],
        ),
        _label(context, 'Accuracy'),
        Wrap(
          spacing: 8,
          children: [
            for (final a in CaptionAccuracy.values)
              ChoiceChip(
                label: Text(
                  '${a.label} · ${SpeechModel.of(a, english: _english).sizeLabel}',
                ),
                selected: _accuracy == a,
                onSelected: (_) => setState(() => _accuracy = a),
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            'The speech model (${model.sizeLabel}) is downloaded the first '
            'time, then works offline. Bigger is more accurate but slower.',
            style: theme.textTheme.bodySmall,
          ),
        ),
        if (_selectedId != null) ...[
          _label(context, 'Listen to'),
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: const Text('Whole video'),
                selected: !_onlySelected,
                onSelected: (_) => setState(() => _onlySelected = false),
              ),
              ChoiceChip(
                label: const Text('Selected clip'),
                selected: _onlySelected,
                onSelected: (_) => setState(() => _onlySelected = true),
              ),
            ],
          ),
        ],
        _label(context, 'Look'),
        Wrap(
          spacing: 8,
          children: [
            for (final s in CaptionStyle.values)
              ChoiceChip(
                label: Text(s.label),
                selected: _style == s,
                onSelected: (_) => setState(() => _style = s),
              ),
          ],
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: sources.isEmpty ? null : _start,
            icon: const Icon(Icons.closed_caption_outlined),
            label: Text(
              c.project.textTracks.any((t) => t.captions)
                  ? 'Make captions again'
                  : 'Make captions',
            ),
          ),
        ),
        if (sources.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'There is no sound to listen to (add a video with sound or a '
              'voice-over).',
              style: theme.textTheme.bodySmall,
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Video clips and voice-overs are listened to (not music). '
              'Making them again replaces the earlier captions.',
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  Widget _label(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 6),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );
}

class _Note extends StatelessWidget {
  const _Note({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    margin: const EdgeInsets.only(top: 4, bottom: 4),
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      border: Border.all(color: color),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(text, style: TextStyle(color: color)),
  );
}
