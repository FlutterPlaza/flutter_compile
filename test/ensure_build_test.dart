import 'package:test/test.dart';

import '../lib/src/version.dart';

void main() {
  test('version is up to date', () {
    expect(packageVersion, '0.4.0');
  });
}
