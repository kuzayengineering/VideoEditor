import 'package:flutter/material.dart';

import '../model/project.dart';
import 'editor_controller.dart';
import 'tool_panel.dart';

const _palette = <int>[
  0xFFFFFFFF,
  0xFF000000,
  0xFFFFD54F,
  0xFFFFB300,
  0xFFFF7043,
  0xFFE53935,
  0xFFEC407A,
  0xFFAB47BC,
  0xFF5C6BC0,
  0xFF29B6F6,
  0xFF26A69A,
  0xFF66BB6A,
  0xFFD4AF37, // gold
];

/// The text editor: what it says, font, colours, outline, box and
/// animations. Changes show live in the preview and become one undo step.
Future<void> showTextSheet(
  BuildContext context,
  EditorController c,
  int clipId, {
  int initialTab = 0,
}) async {
  // Shown below the video, so changes can be seen as they're made.
  await showToolPanel(
    context,
    title: 'Text',
    scrollable: false,
    builder: (context) =>
        _TextSheet(c: c, clipId: clipId, initialTab: initialTab),
  );
  c.endLiveEdit();
}

class _TextSheet extends StatefulWidget {
  const _TextSheet({
    required this.c,
    required this.clipId,
    required this.initialTab,
  });

  final EditorController c;
  final int clipId;
  final int initialTab;

  @override
  State<_TextSheet> createState() => _TextSheetState();
}

class _TextSheetState extends State<_TextSheet> {
  late final TextEditingController _field;

  EditorController get c => widget.c;
  TextSpec? get spec => c.project.placementOf(widget.clipId)?.clip.text;

  @override
  void initState() {
    super.initState();
    _field = TextEditingController(text: spec?.text ?? '');
  }

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _edit(TextSpec Function(TextSpec s) change) {
    c.liveEdit(
      (base) => base.updateClip(widget.clipId, (x) {
        final next = change(x.text!);
        return x.copyWith(text: next, name: next.text);
      }),
    );
  }

  Widget _colors(
    int? selected,
    void Function(int) onPick, {
    bool allowNone = false,
    VoidCallback? onNone,
  }) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          if (allowNone)
            _Swatch(
              selected: selected == null,
              onTap: onNone!,
              child: const Icon(Icons.block, size: 20),
            ),
          for (final col in _palette)
            _Swatch(
              selected: selected == col,
              onTap: () => onPick(col),
              color: Color(col),
            ),
        ],
      ),
    );
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(top: 14, bottom: 6),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DefaultTabController(
      length: 4,
      initialIndex: widget.initialTab,
      child: ListenableBuilder(
        listenable: c,
        builder: (context, _) {
          final s = spec;
          if (s == null) return const SizedBox.shrink();
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  controller: _field,
                  autofocus: s.text == const TextSpec().text,
                  minLines: 1,
                  maxLines: 3,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Text',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => _edit((x) => x.copyWith(text: v)),
                ),
              ),
              const TabBar(
                tabs: [
                  Tab(text: 'Style'),
                  Tab(text: 'Outline'),
                  Tab(text: 'Box'),
                  Tab(text: 'Animation'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    // ---- Style
                    ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        _label('Font'),
                        SizedBox(
                          height: 48,
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            children: [
                              for (final f in textFonts)
                                Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: ChoiceChip(
                                    selected: s.font == f,
                                    onSelected: (_) =>
                                        _edit((x) => x.copyWith(font: f)),
                                    label: Text(
                                      f,
                                      style: TextStyle(
                                        fontFamily: f,
                                        fontSize: 16,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        _label('Size'),
                        Slider(
                          min: 0.03,
                          max: 0.25,
                          value: s.size.clamp(0.03, 0.25),
                          onChanged: (v) => _edit((x) => x.copyWith(size: v)),
                        ),
                        _label('Color'),
                        _colors(
                          s.colorValue,
                          (v) => _edit((x) => x.copyWith(colorValue: v)),
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          children: [
                            FilterChip(
                              label: const Text('Bold'),
                              selected: s.bold,
                              onSelected: (v) =>
                                  _edit((x) => x.copyWith(bold: v)),
                            ),
                            FilterChip(
                              label: const Text('Italic'),
                              selected: s.italic,
                              onSelected: (v) =>
                                  _edit((x) => x.copyWith(italic: v)),
                            ),
                            FilterChip(
                              label: const Text('Shadow'),
                              selected: s.shadow,
                              onSelected: (v) =>
                                  _edit((x) => x.copyWith(shadow: v)),
                            ),
                            for (final a in TextAlignSpec.values)
                              ChoiceChip(
                                label: Icon(switch (a) {
                                  TextAlignSpec.left => Icons.format_align_left,
                                  TextAlignSpec.center =>
                                    Icons.format_align_center,
                                  TextAlignSpec.right =>
                                    Icons.format_align_right,
                                }, size: 18),
                                selected: s.align == a,
                                onSelected: (_) =>
                                    _edit((x) => x.copyWith(align: a)),
                              ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Tip: drag the text on the video to move it; pinch '
                          'to resize or twist it.',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                    // ---- Outline
                    ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        _label('Thickness'),
                        Slider(
                          max: 0.15,
                          value: s.outline.clamp(0.0, 0.15),
                          onChanged: (v) =>
                              _edit((x) => x.copyWith(outline: v)),
                        ),
                        _label('Color'),
                        _colors(
                          s.outlineColorValue,
                          (v) => _edit(
                            (x) => x.copyWith(
                              outlineColorValue: v,
                              outline: x.outline > 0 ? x.outline : 0.06,
                            ),
                          ),
                        ),
                      ],
                    ),
                    // ---- Box
                    ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        _label('Background box'),
                        _colors(
                          s.boxColorValue == null
                              ? null
                              : (s.boxColorValue! | 0xFF000000),
                          (v) => _edit(
                            (x) => x.copyWith(
                              boxColorValue:
                                  (v & 0xFFFFFF) |
                                  ((x.boxColorValue ?? 0xB3000000) &
                                      0xFF000000),
                            ),
                          ),
                          allowNone: true,
                          onNone: () =>
                              _edit((x) => x.copyWith(clearBox: true)),
                        ),
                        if (s.boxColorValue != null) ...[
                          _label('See-through'),
                          Slider(
                            min: 0.1,
                            value: ((s.boxColorValue! >> 24) & 0xFF) / 255,
                            onChanged: (v) => _edit(
                              (x) => x.copyWith(
                                boxColorValue:
                                    ((v * 255).round() << 24) |
                                    (x.boxColorValue! & 0xFFFFFF),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    // ---- Animation
                    ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        _AnimPicker(
                          title: 'Appear',
                          value: s.animIn,
                          durationUs: s.animInUs,
                          onAnim: (a) => _edit((x) => x.copyWith(animIn: a)),
                          onDuration: (d) =>
                              _edit((x) => x.copyWith(animInUs: d)),
                        ),
                        const SizedBox(height: 12),
                        _AnimPicker(
                          title: 'Disappear',
                          value: s.animOut,
                          durationUs: s.animOutUs,
                          onAnim: (a) => _edit((x) => x.copyWith(animOut: a)),
                          onDuration: (d) =>
                              _edit((x) => x.copyWith(animOutUs: d)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _AnimPicker extends StatelessWidget {
  const _AnimPicker({
    required this.title,
    required this.value,
    required this.durationUs,
    required this.onAnim,
    required this.onDuration,
  });

  final String title;
  final TextAnim value;
  final int durationUs;
  final void Function(TextAnim) onAnim;
  final void Function(int) onDuration;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final a in TextAnim.values)
              ChoiceChip(
                label: Text(a.label),
                selected: a == value,
                onSelected: (_) => onAnim(a),
              ),
          ],
        ),
        if (value != TextAnim.none)
          Row(
            children: [
              const Text('Speed'),
              Expanded(
                child: Slider(
                  min: 200000,
                  max: 3000000,
                  divisions: 28,
                  value: durationUs.clamp(200000, 3000000).toDouble(),
                  onChanged: (v) => onDuration(v.round()),
                ),
              ),
              SizedBox(
                width: 48,
                child: Text('${(durationUs / 1000000).toStringAsFixed(1)} s'),
              ),
            ],
          ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.selected,
    required this.onTap,
    this.color,
    this.child,
  });

  final bool selected;
  final VoidCallback onTap;
  final Color? color;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            border: Border.all(
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : Colors.white24,
              width: selected ? 3 : 1,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}
