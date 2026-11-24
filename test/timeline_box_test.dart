import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor/ui/timeline_view.dart';

void main() {
  test('short clips are drawn at least square, about their middle', () {
    expect(clipBoxSpan(100, 300, 60), (100.0, 300.0)); // wide: as is
    expect(clipBoxSpan(100, 110, 60), (75.0, 135.0)); // short: 60 wide
    expect(clipBoxSpan(100, 100, 40), (80.0, 120.0)); // zero: 40 wide
  });
}
