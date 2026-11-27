import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor/ui/windows_updates.dart';

void main() {
  test('versions compare number by number', () {
    expect(compareVersions('0.3.10', '0.3.9'), greaterThan(0));
    expect(compareVersions('0.4.0', '0.3.99'), greaterThan(0));
    expect(compareVersions('0.3.9', '0.3.9'), 0);
    expect(compareVersions('0.3.8', '0.3.9'), lessThan(0));
  });
}
