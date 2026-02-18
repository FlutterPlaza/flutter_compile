import 'package:flutter_compile/src/tui/tui_renderer.dart';
import 'package:test/test.dart';

void main() {
  group('TuiRenderer', () {
    test('render with empty state contains Flutter Compile', () {
      final state = TuiState();
      final output = TuiRenderer.render(state);
      expect(output, contains('Flutter Compile'));
    });

    test('render with SDKs tab selected contains SDKs', () {
      final state = TuiState()..currentTab = 0;
      final output = TuiRenderer.render(state);
      expect(output, contains('SDKs'));
    });

    test('render with SDK data contains version strings', () {
      final state = TuiState()
        ..currentTab = 0
        ..sdkList = [
          {
            'version': '3.19.0',
            'path': '/tmp/versions/3.19.0',
            'global': true,
            'project': false,
          },
          {
            'version': 'stable',
            'path': '/tmp/versions/stable',
            'global': false,
            'project': true,
          },
        ];
      final output = TuiRenderer.render(state);
      expect(output, contains('3.19.0'));
      expect(output, contains('stable'));
      expect(output, contains('global'));
      expect(output, contains('project'));
    });

    test('render with Doctor tab selected contains Doctor', () {
      final state = TuiState()..currentTab = 3;
      final output = TuiRenderer.render(state);
      expect(output, contains('Doctor'));
    });

    test('render shows loading state', () {
      final state = TuiState()..loading = true;
      final output = TuiRenderer.render(state);
      expect(output, contains('Loading'));
    });

    test('render with empty SDK list shows install hint', () {
      final state = TuiState()..currentTab = 0;
      final output = TuiRenderer.render(state);
      expect(output, contains('No Flutter SDKs installed'));
    });

    test('render shows Environments tab content', () {
      final state = TuiState()
        ..currentTab = 1
        ..doctorChecks = [
          {
            'name': 'Flutter contributor environment',
            'category': 'environments',
            'status': 'ok',
          },
        ];
      final output = TuiRenderer.render(state);
      expect(output, contains('Flutter contributor environment'));
    });

    test('render shows status message when set', () {
      final state = TuiState()..statusMessage = 'SDK installed successfully';
      final output = TuiRenderer.render(state);
      expect(output, contains('SDK installed successfully'));
    });

    test('render input mode shows input prompt', () {
      final state = TuiState()
        ..currentTab = 0
        ..inputMode = true
        ..inputBuffer = '3.19';
      final output = TuiRenderer.render(state);
      expect(output, contains('Install SDK version'));
      expect(output, contains('3.19'));
    });
  });
}
