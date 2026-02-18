import 'dart:io';

import 'package:flutter_compile/src/version.dart';

class TuiState {
  int currentTab = 0;
  int cursorIndex = 0;
  List<Map<String, dynamic>> sdkList = [];
  List<Map<String, dynamic>> doctorChecks = [];
  Map<String, dynamic> status = {};
  Map<String, String> config = {};
  bool loading = false;
  String? statusMessage;
  String inputBuffer = '';
  bool inputMode = false;
}

class TuiRenderer {
  static String render(TuiState state) {
    final buf = StringBuffer();
    final width = _terminalWidth();

    // Clear screen, cursor home
    buf.write('\x1B[2J\x1B[H');

    _renderHeader(buf, width);
    _renderTabs(buf, state, width);
    buf.writeln();
    _renderContent(buf, state, width);
    _renderFooter(buf, state, width);

    return buf.toString();
  }

  static int _terminalWidth() {
    try {
      return stdout.terminalColumns;
    } catch (_) {
      return 80;
    }
  }

  static void _renderHeader(StringBuffer buf, int width) {
    buf.writeln(' Flutter Compile v$packageVersion');
    buf.writeln(' ${'─' * (width - 2).clamp(1, 200)}');
  }

  static void _renderTabs(StringBuffer buf, TuiState state, int width) {
    const tabs = ['SDKs', 'Environments', 'Builds', 'Doctor'];
    final parts = <String>[];
    for (var i = 0; i < tabs.length; i++) {
      if (i == state.currentTab) {
        parts.add(' \x1B[7m [${i + 1}] ${tabs[i]} \x1B[0m');
      } else {
        parts.add(' [${i + 1}] ${tabs[i]}');
      }
    }
    buf.writeln(parts.join('  '));
  }

  static void _renderContent(
    StringBuffer buf,
    TuiState state,
    int width,
  ) {
    if (state.loading) {
      buf.writeln(' Loading...');
      return;
    }

    switch (state.currentTab) {
      case 0:
        _renderSdksTab(buf, state);
      case 1:
        _renderEnvironmentsTab(buf, state);
      case 2:
        _renderBuildsTab(buf, state);
      case 3:
        _renderDoctorTab(buf, state);
    }
  }

  static void _renderSdksTab(StringBuffer buf, TuiState state) {
    if (state.sdkList.isEmpty) {
      buf.writeln(' No Flutter SDKs installed.');
      buf.writeln(' Press [i] to install one.');
      return;
    }

    for (var i = 0; i < state.sdkList.length; i++) {
      final sdk = state.sdkList[i];
      final version = sdk['version'] as String;
      final isGlobal = sdk['global'] == true;
      final isProject = sdk['project'] == true;
      final markers = <String>[];
      if (isGlobal) markers.add('global');
      if (isProject) markers.add('project');
      final suffix = markers.isEmpty ? '' : '  (${markers.join(', ')})';

      final prefix = i == state.cursorIndex ? ' \x1B[7m>' : '  ';
      final reset = i == state.cursorIndex ? '\x1B[0m' : '';
      buf.writeln('$prefix $version$suffix $reset');
    }
  }

  static void _renderEnvironmentsTab(StringBuffer buf, TuiState state) {
    final envChecks = state.doctorChecks
        .where((c) => c['category'] == 'environments')
        .toList();

    if (envChecks.isEmpty) {
      buf.writeln(' No contributor environments configured.');
      return;
    }

    for (final check in envChecks) {
      final name = check['name'] as String;
      final status = check['status'] as String;
      final icon = status == 'ok'
          ? '+'
          : status == 'not_configured'
              ? '-'
              : 'X';
      buf.writeln(' [$icon] $name: $status');
    }
  }

  static void _renderBuildsTab(StringBuffer buf, TuiState state) {
    if (state.status['configured'] != true) {
      buf.writeln(' Engine not configured.');
      return;
    }

    final builds = state.status['builds'] as List? ?? [];
    if (builds.isEmpty) {
      buf.writeln(' No builds available.');
      return;
    }

    for (final b in builds) {
      final name = (b as Map)['name'] as String;
      final size = b['size'] as String;
      buf.writeln('  $name    $size');
    }
  }

  static void _renderDoctorTab(StringBuffer buf, TuiState state) {
    if (state.doctorChecks.isEmpty) {
      buf.writeln(' No checks available. Press [r] to refresh.');
      return;
    }

    for (final check in state.doctorChecks) {
      final name = check['name'] as String;
      final status = check['status'] as String;
      final category = check['category'] as String;
      final icon = status == 'ok'
          ? '+'
          : status == 'not_found' || status == 'not_configured'
              ? '-'
              : 'X';

      String displayName;
      if (category == 'engine_tools' && name == 'gclient') {
        displayName = 'depot_tools (gclient)';
      } else if (category == 'engine_tools' && name == 'xcode') {
        displayName = 'Xcode';
      } else {
        displayName = name;
      }

      buf.writeln(' [$icon] $displayName: $status');
    }
  }

  static void _renderFooter(StringBuffer buf, TuiState state, int width) {
    buf.writeln();

    if (state.inputMode) {
      buf.writeln(' Install SDK version: ${state.inputBuffer}_');
      return;
    }

    if (state.statusMessage != null) {
      buf.writeln(' ${state.statusMessage}');
      buf.writeln();
    }

    if (state.currentTab == 0) {
      buf.write(
        ' [Enter] Set global  [i] Install  [r] Refresh  [q] Quit',
      );
    } else if (state.currentTab == 3) {
      buf.write(' [r] Refresh  [q] Quit');
    } else {
      buf.write(' [r] Refresh  [q] Quit');
    }
  }
}
