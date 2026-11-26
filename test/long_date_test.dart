import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor/model/project.dart';

void main() {
  test('dates are written out in full', () {
    expect(longDate(DateTime(2024, 12, 10)), 'December 10, 2024');
    expect(longDate(DateTime(2025, 1, 3)), 'January 3, 2025');
  });
}
