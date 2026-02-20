import 'package:test/test.dart';

import 'package:flutter_compile/src/version.dart';

void main() {
  test('version is up to date', () {
    expect(packageVersion, '0.10.1');
  });
}
