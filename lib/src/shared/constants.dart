class Constants {
  // Flutter Compile Constants
  static const flutterCompileInstallPath = '$baseCliPath/flutter';
  static const flutterCompileBin = '$flutterCompileInstallPath/bin';
  static const flutterCompileSwitchedToNormal =
      'Switched to normal Flutter installation.';
  static const flutterCompileSwitchedToCompiled =
      'Switched to compiled Flutter installation.';
  static const flutterCompilePATHExport = r'''

# >>> Added by flutter_compile setup CLI >>>
export PATH={{path}}:$PATH
export PATH={{path}}/cache/dart-sdk/bin:$PATH
# <<< Added by flutter_compile setup CLI <<<

''';

// DevTools Constants
  static const devToolsInstallPath = '$baseCliPath/devtools';
  static const devToolsPATHExport = r'''

# >>> Added by flutter_compile setup CLI >>>
export PATH={{path}}/tool/bin:$PATH
# <<< Added by flutter_compile setup CLI <<<

''';

  static const List<String> infoSections = [
    'Windows Users\n'
        'Open "Edit environment variables for your account" from Control Panel\n'
        'Locate the Path variable and click Edit\n'
        'Click the New button and paste in <DEVTOOLS_DIR>/tool/bin, replacing <DEVTOOLS_DIR> with the local path to your DevTools repo.\n'
        'Explore the commands and helpers that devtools_tool provides by running devtools_tool -h.\n',
    'Optional: enable and activate DCM (Dart Code Metrics) - see the DCM section below\n',
    'Set up your IDE\n'
        'We recommend using VS Code for your DevTools development environment because this gives you access to some advanced development and configuration features. When you open DevTools in VS Code, open the devtools/packages directory in your VS Code workspace. This will give you access to a set of launch configurations for running and debugging DevTools:\n'
        'VS Code launch configurations\n',
    'Workflow for making changes\n'
        'Change your local Flutter SDK to the latest flutter candidate branch: devtools_tool update-flutter-sdk --from-path\n'
        'Note: Until #7939 is fixed, run devtools_tool update-flutter-sdk --use-cache instead.\n'
        'Create a branch from your cloned DevTools repo: git checkout -b myBranch\n'
        'Ensure your branch, dependencies, and generated code are up-to-date: devtools_tool sync\n'
        'Implement your changes, and commit to your branch: git commit -m “description”\n'
        'If your improvement is user-facing, document it in the same PR.\n'
        'Push to your branch to GitHub: git push origin myBranch\n'
        'Navigate to the Pull Requests tab in the main DevTools repo. You should see a popup to create a pull request from the branch in your cloned repo to the DevTools master branch. Create a pull request.\n'
        'Running the Dart Code Metrics Github workflow: any PRs that change Dart code require the Dart Code Metrics workflow to be run before being submitted. To trigger the workflow, add the label run-dcm-workflow to your PR. If you don\'t have permission to add the label, your reviewer can add it for you.\n'
        'Any DCM errors will be caught by the workflow. Fix them and push up your changes. To trigger the DCM workflow to run again, you will need to remove and then re-add the run-dcm-workflow label.\n',
    'Keeping your fork in-sync\n'
        'If at any time you need to re-sync your branch, run:\n'
        'devtools_tool sync\n'
        'This will pull the latest code from the upstream DevTools, upgrade dependencies, and perform code generation.\n'
        'If you want to upgrade dependencies and re-generate code (like mocks), but do not want to merge upstream/master, instead run\n'
        'devtools_tool generate-code --upgrade\n',
    'To update DCM to the same version as on GitHub bots with apt-get or brew:\n'
        'Locate, copy and run apt-get command searching by searching for install dcm in build.yaml\n'
        'Locate version on bots by searching for install dcm in build.yaml and run brew install cqlabs/dcm/dcm@<version on bots without -1>\n'
        'You can check you current local version with dcm --version.\n'
        'If version of DCM on bots is outdated, consider to submit a PR to refresh the version on bots.\n',
    'Running and debugging DevTools\n'
        'There are a few different environments that you may need to run DevTools in. After running DevTools in one of the environments below, connect to a test application to debug DevTools runtime tooling (the majority of DevTools tools). See the Connect DevTools to a test application section below.\n'
        'Frontend only (most common)\n'
        'Most of the time, you will not need to run DevTools with the DevTools server to test your changes. You can run DevTools in debug mode as either a Flutter web or Flutter desktop app.\n'
        'Note: though DevTools is shipped as a Flutter Web app, we recommend developing as a Flutter Desktop app whenever possible for a more efficient development workflow. Please see the running on Flutter desktop section below for instructions.\n'
        'To run DevTools as a Flutter web app from VS Code, run with the devtools (packages) configuration and the "Chrome" device\n'
        'To run with experiments enabled, run from VS Code with the devtools + experiments (packages) configuration\n'
        'To run DevTools as a Flutter web app from the command line, run flutter run -d chrome\n'
        'To run with experiments enabled, add the flag --dart-define=enable_experiments=true\n',
    'Frontend + DevTools server\n'
        'To develop with a workflow that exercises the DevTools server <==> DevTools client connection, you will need to perform the following set up steps (first time only).\n'
        'Clone the Dart SDK fron GitHub.\n'
        'The LOCAL_DART_SDK environment variable needs to point to this path: export LOCAL_DART_SDK=/path/to/dart/sdk\n'
        'If you are also developing server side code (e.g. the devtools_shared package), you will need to add a dependency override to sdk/pkg/dds/pubspec.yaml.\n'
        'dependency_overrides:\n'
        '  devtools_shared:\n'
        '    path: relative/path/to/devtools/packages/devtools_shared\n'
        'Then you can run DevTools with the server by running the following from the top-level devtools directory:\n'
        'devtools_tool serve\n',
    'DevTools + VS Code integration (IDE-embedded DevTools experience)\n'
        'To test the integration with VS Code, you can set up the Dart VS Code extension to run DevTools and the server from your local source code. Follow the Frontend + DevTools server setup instructions above, and make sure you have version v3.47 or newer of the Dart extension for VS Code.\n'
        'Open your VS Code settings (Run the Preferences: Open User Settings (JSON) command from the command palette (F1)) and add the following to your settings:\n'
        '"dart.customDevTools": {\n'
        '  "path": "/path/to/devtools",\n'
        '  "env": {\n'
        '    "LOCAL_DART_SDK": "/path/to/sdk"\n'
        '    // Path to the version that Flutter DevTools is pinned to.\n'
        '    "FLUTTER_ROOT": "/path/to/devtools/tool/flutter-sdk"\n'
        '  }\n'
        '},\n'
        'This instructs VS Code to run the devtools_tool serve command instead of running dart devtools. You must set the LOCAL_DART_SDK and FLUTTER_ROOT env variables correctly for the script to work.\n'
        'Next, restart VS Code (or run the Developer: Reload Window command from the command palette (F1)) and DevTools will be run from your local source code. After making any code changes to DevTools or the server, you will need to re-run the Developer: Reload Window command to rebuild and restart the server.\n',
    'Testing for DevTools\n'
        'Please see TESTING.md for guidance on running and writing tests.\n',
    'Appendix\n'
        'Connect DevTools to a test application\n'
        'For working on most DevTools tools, a connection to a running Dart or Flutter app is required. Run any Dart of Flutter app of your choice to connect it to DevTools. Consider running the Flutter gallery app, as it has plenty of interesting code to debug.\n'
        'Run your Dart or Flutter app\n'
        'Note: some DevTools features may be unavailable depending on the test app platform (Flutter native, Flutter web, Dart CLI, etc.) or run mode (debug, profile) you choose.\n'
        'Copy the URI printed to the command line (you will use this uri to connect to DevTools)\n'
        '"A Dart VM Service on iPhone 14 Pro Max is available at: <copy-this-uri>"\n'
        'Paste this URI into the connect dialog in DevTools and click "Connect"\n',
    'Running DevTools on Flutter Desktop\n'
        'For a faster development cycle with hot reload, you can run DevTools on Flutter desktop. Some DevTools features only work on the web, like the embedded Perfetto trace viewer, DevTools extensions, or DevTools analytics, but the limitations on the desktop app are few.\n'
        'To run DevTools with the desktop embedder, you can run with either of the following from devtools/packages/devtools_app:\n'
        'flutter run -d macos\n'
        'flutter run -d linux\n'
        'If this fails, you may need to run flutter create . from devtools/packages/devtools_app to generate the updated files for your platform. If you want to run DevTools on Flutter desktop for Windows, you will need to generate the files for this platform using the same command, and then run using flutter run -d windows.\n',
    'Enable and activate DCM (Dart Code Metrics)\n'
        'Enabling and activating DCM is optional. When you open a PR, the CI bots will show you any DCM warnings introduced by your change which should be fixed before submitting.\n'
        'Contributors who work at Google: you can use the Google-purchased license key to activate DCM. See go/dash-devexp-dcm-keys.\n'
        'All other contributors: please follow instructions at https://dcm.dev/pricing/. You can either use the free tier of DCM, or purchase a team license. Note that the free tier doesn\'t support all the rules of the paid tier, so you will also need to consult the output of the Dart Code Metrics workflow on Github when you open your PR.\n'
        'To enable DCM:\n'
        'Install the executable for your target platform. You can refer to this guide.\n'
        'Get the license key and activate DCM. To do so, run dcm activate --license-key=YOUR_KEY from the console.\n'
        'Install the extension for your IDE. If you use VS Code, you can get it from the marketplace. If you use IntelliJ IDEA or Android Studio, you can find the plugin here.\n'
        'Reload the IDE.\n',
    'For complete guide, visit: https://github.com/flutter/devtools/blob/master/CONTRIBUTING.md#set-up-your-devtools-environment\n'
  ];
  // Shared Constants
  static const baseCliPath = '/flutter_compile';
  static const restartShell =
      '\nPlease restart your terminal or source your shell configuration to apply changes. Run\n\nsource ~/{{shell}}\n';

  static const gitHubUserNameRegex =
      r'^[a-zA-Z0-9](?:[a-zA-Z0-9\-]{2,}[a-zA-Z0-9])?$';
}

enum RunCommandKey {
  flutterCompile('flutter_path'), // key for the path to the flutter compile
  devTools('devtools_path'), // key for the path to the devtools

  ;

  final String key;
  const RunCommandKey(this.key);
}

enum FlutterMode {
  normal,
  compiled,
}
