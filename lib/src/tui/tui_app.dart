import 'dart:async';
import 'dart:io';

import 'package:flutter_compile/src/commands/config_command.dart';
import 'package:flutter_compile/src/commands/doctor_command.dart';
import 'package:flutter_compile/src/commands/sdk_commands/_sdk_list.dart';
import 'package:flutter_compile/src/commands/status_command.dart';
import 'package:flutter_compile/src/shared/constants.dart';
import 'package:flutter_compile/src/shared/functions.dart';
import 'package:flutter_compile/src/tui/tui_keys.dart';
import 'package:flutter_compile/src/tui/tui_renderer.dart';
import 'package:mason_logger/mason_logger.dart';

class TuiApp {
  TuiApp({required Logger logger});
  final _state = TuiState();
  bool _shouldQuit = false;

  Future<int> run() async {
    stdin.echoMode = false;
    stdin.lineMode = false;
    stdout.write('\x1B[?25l'); // Hide cursor
    try {
      await _loadAllData();
      _render();
      await for (final bytes in stdin) {
        final key = parseKey(bytes);
        await _handleKey(key);
        _render();
        if (_shouldQuit) break;
      }
    } finally {
      stdin.echoMode = true;
      stdin.lineMode = true;
      stdout.write('\x1B[?25h\x1B[2J\x1B[H'); // Show cursor, clear
    }
    return ExitCode.success.code;
  }

  Future<void> _loadAllData() async {
    _state.loading = true;
    _render();

    _state.sdkList = await gatherSdkList();
    _state.doctorChecks = await gatherDoctorChecks();
    _state.status = await gatherStatus();
    _state.config = await gatherConfig();
    _state.loading = false;
  }

  void _render() {
    stdout.write(TuiRenderer.render(_state));
  }

  Future<void> _handleKey(TuiKey key) async {
    // Input mode for SDK install
    if (_state.inputMode) {
      await _handleInputKey(key);
      return;
    }

    switch (key) {
      case TuiKey.key1:
        _state.currentTab = 0;
        _state.cursorIndex = 0;
      case TuiKey.key2:
        _state.currentTab = 1;
        _state.cursorIndex = 0;
      case TuiKey.key3:
        _state.currentTab = 2;
        _state.cursorIndex = 0;
      case TuiKey.key4:
        _state.currentTab = 3;
        _state.cursorIndex = 0;
      case TuiKey.up:
        if (_state.cursorIndex > 0) _state.cursorIndex--;
      case TuiKey.down:
        final maxIndex = _currentListLength() - 1;
        if (_state.cursorIndex < maxIndex) _state.cursorIndex++;
      case TuiKey.left:
        if (_state.currentTab > 0) {
          _state.currentTab--;
          _state.cursorIndex = 0;
        }
      case TuiKey.right:
        if (_state.currentTab < 3) {
          _state.currentTab++;
          _state.cursorIndex = 0;
        }
      case TuiKey.tab:
        _state.currentTab = (_state.currentTab + 1) % 4;
        _state.cursorIndex = 0;
      case TuiKey.enter:
        await _handleEnter();
      case TuiKey.keyI:
        if (_state.currentTab == 0) {
          _state.inputMode = true;
          _state.inputBuffer = '';
        }
      case TuiKey.keyR:
        await _refresh();
      case TuiKey.keyQ:
        _shouldQuit = true;
      case TuiKey.ctrlC || TuiKey.escape:
        _shouldQuit = true;
      default:
        break;
    }
  }

  Future<void> _handleInputKey(TuiKey key) async {
    switch (key) {
      case TuiKey.escape || TuiKey.ctrlC:
        _state.inputMode = false;
        _state.inputBuffer = '';
      case TuiKey.enter:
        final version = _state.inputBuffer.trim();
        _state.inputMode = false;
        _state.inputBuffer = '';
        if (version.isNotEmpty) {
          await _installSdk(version);
        }
      default:
        // For input mode, we need to handle raw character input
        // This is handled specially — the key enum doesn't cover all chars
        break;
    }
  }

  int _currentListLength() {
    switch (_state.currentTab) {
      case 0:
        return _state.sdkList.length;
      case 1:
        return _state.doctorChecks
            .where((c) => c['category'] == 'environments')
            .length;
      case 3:
        return _state.doctorChecks.length;
      default:
        return 0;
    }
  }

  Future<void> _handleEnter() async {
    if (_state.currentTab == 0 && _state.sdkList.isNotEmpty) {
      final sdk = _state.sdkList[_state.cursorIndex];
      final version = sdk['version'] as String;
      if (sdk['contributor'] == true) return;

      await _setGlobalSdk(version);
    }
  }

  Future<void> _setGlobalSdk(String version) async {
    if (!F.isSdkInstalled(version)) {
      _state.statusMessage = 'SDK "$version" is not installed.';
      return;
    }

    final home = F.homeDir();
    final rcConfigFile = File('$home/.flutter_compilerc');
    await F.writeKeyValueToRcConfig(
      rcConfigFile,
      Constants.globalSdkVersionKey,
      version,
    );

    final sdkPath = F.sdkVersionPath(version);
    final pubCachePath = F.sdkPubCachePath(sdkPath);

    final configPath = F.getShellConfigPath();
    final configFile = File(configPath);
    if (await configFile.exists()) {
      var contents = await configFile.readAsString();

      final sdkManagerPattern = RegExp(
        r'\n# >>> Added by flutter_compile SDK manager >>>'
        r'[\s\S]*?'
        r'# <<< Added by flutter_compile SDK manager <<<\n',
      );
      contents = contents.replaceAll(sdkManagerPattern, '');

      final pathExport = Constants.platformSdkPATHExport
          .replaceAll('{{path}}', sdkPath)
          .replaceAll('{{pub_cache_path}}', pubCachePath);
      contents += pathExport;
      await configFile.writeAsString(contents);
    }

    _state.statusMessage = 'Global SDK set to "$version".';
    _state.sdkList = await gatherSdkList();
  }

  Future<void> _installSdk(String version) async {
    _state.statusMessage = 'Installing SDK "$version"...';
    _render();

    try {
      final sdkPath = F.sdkVersionPath(version);
      await F.cloneRepository(Constants.flutterGitUrl, sdkPath);

      // Checkout the specific version
      await Process.run('git', ['checkout', version],
          workingDirectory: sdkPath);

      _state.statusMessage = 'SDK "$version" installed.';
      _state.sdkList = await gatherSdkList();
    } catch (e) {
      _state.statusMessage = 'Failed to install SDK: $e';
    }
  }

  Future<void> _refresh() async {
    _state.statusMessage = 'Refreshing...';
    _render();
    await _loadAllData();
    _state.statusMessage = null;
  }
}
