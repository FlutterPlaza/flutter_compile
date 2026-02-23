package com.flutterplaza.fluttercompile

object Constants {

    // ── Plugin identity ──────────────────────────────────────────────────
    const val PLUGIN_NAME = "Flutter Compile"
    const val NOTIFICATION_GROUP = "Flutter Compile"
    const val TOOL_WINDOW_ID = "Flutter Compile"

    // ── CLI ───────────────────────────────────────────────────────────────
    const val CLI_NAME = "flutter_compile"
    const val CLI_NAME_WIN = "flutter_compile.bat"
    const val CLI_DEFAULT_PATH = "flutter_compile"
    const val CLI_PACKAGE_NAME = "flutter_compile"

    // ── SDK manager modes ────────────────────────────────────────────────
    const val MODE_NATIVE = "native"
    const val MODE_FVM = "fvm"

    // ── Persistent state ─────────────────────────────────────────────────
    const val SETTINGS_STATE_NAME = "FlutterCompileSettings"
    const val SETTINGS_STORAGE_FILE = "FlutterCompilePlugin.xml"

    // ── RC config ────────────────────────────────────────────────────────
    const val RC_FILE = ".flutter_compilerc"
    const val GLOBAL_SDK_KEY = "global_sdk_version"

    // ── Version file ─────────────────────────────────────────────────────
    const val FLUTTER_VERSION_FILE = ".flutter-version"
    const val FVM_RC_FILE = ".fvmrc"

    // ── Native SDK backend ───────────────────────────────────────────────
    const val FLUTTER_GIT_URL = "https://github.com/flutter/flutter.git"
    const val SDK_VERSIONS_REL = "flutter_compile/versions"
    const val COMPILED_VERSION = "compiled"
    const val COMPILED_SDK_REL = "flutter_compile/flutter"

    // ── Paths ────────────────────────────────────────────────────────────
    const val PUB_CACHE_BIN_UNIX = ".pub-cache/bin"
    const val PUB_CACHE_BIN_WIN = "Pub/Cache/bin"
    const val DEPOT_TOOLS_REL = "flutter_compile/depot_tools"
    const val DEPOT_TOOLS_GIT_URL = "https://chromium.googlesource.com/chromium/tools/depot_tools.git"

    // ── System properties ────────────────────────────────────────────────
    const val SYS_USER_HOME = "user.home"
    const val SYS_OS_NAME = "os.name"
    const val OS_WINDOWS_MARKER = "win"

    // ── External commands ────────────────────────────────────────────────
    const val CMD_GIT = "git"
    const val CMD_FVM = "fvm"
    const val CMD_DART = "dart"
    const val CMD_DART_WIN = "dart.bat"
    const val CMD_WHERE = "where"
    const val CMD_WHICH = "which"
    const val DEFAULT_SHELL = "/bin/zsh"

    // ── Shell config ─────────────────────────────────────────────────────
    const val SHELL_RC_ZSH = ".zshrc"
    const val SHELL_RC_BASH = ".bashrc"
    const val SHELL_RC_PROFILE = ".profile"
    const val DEPOT_TOOLS_PATH_COMMENT_START = "# >>> Added by flutter_compile setup CLI (depot_tools) >>>"
    const val DEPOT_TOOLS_PATH_COMMENT_END = "# <<< Added by flutter_compile setup CLI (depot_tools) <<<"
    const val SDK_PATH_BLOCK_START = "# >>> Added by flutter_compile SDK manager >>>"
    const val SDK_PATH_BLOCK_END = "# <<< Added by flutter_compile SDK manager <<<"

    // ── Env file (dedicated PATH export file) ───────────────────────────
    const val ENV_FILE = ".flutter_compile_env"
    const val SOURCE_LINE = "\n[ -f ~/.flutter_compile_env ] && source ~/.flutter_compile_env\n"
    const val SOURCE_LINE_WINDOWS = "\nif (Test-Path \"\$HOME\\.flutter_compile_env\") { . \"\$HOME\\.flutter_compile_env\" }\n"

    // ── URLs ─────────────────────────────────────────────────────────────
    const val URL_FVM_INSTALL = "https://fvm.app/documentation/getting-started/installation"
    const val URL_PUB_PACKAGE = "https://pub.dev/packages/flutter_compile"
    const val URL_PYTHON_DOWNLOADS = "https://www.python.org/downloads/"
    const val URL_GIT_DOWNLOADS = "https://git-scm.com/downloads"

    // ── Popup menu IDs ───────────────────────────────────────────────────
    const val POPUP_SDK_TREE = "FlutterCompile.SdkTree"
    const val POPUP_DOCTOR_TREE = "FlutterCompile.DoctorTree"
    const val POPUP_BUILDS_TREE = "FlutterCompile.BuildsTree"

    // ── Tab names ────────────────────────────────────────────────────────
    const val TAB_SDKS = "SDKs"
    const val TAB_DOCTOR = "Doctor"
    const val TAB_ENGINE_BUILDS = "Engine Builds"

    // ── Tree root nodes ──────────────────────────────────────────────────
    const val ROOT_SDKS = "SDKs"
    const val ROOT_DOCTOR = "Doctor"
    const val ROOT_BUILDS = "Builds"

    // ── UI labels ────────────────────────────────────────────────────────
    const val LABEL_MODE = "Mode:"
    const val LABEL_SDK_MANAGER = "SDK manager:"
    const val LABEL_CLI_PATH = "CLI path:"
    const val LABEL_PLATFORM = "Platform:"
    const val LABEL_BUILD_MODE = "Mode:"

    // ── UI comments ──────────────────────────────────────────────────────
    const val COMMENT_SDK_MANAGER = "Native: manage SDKs directly (no external tools). FVM: delegate to the fvm CLI."
    const val COMMENT_CLI_PATH = "Path to the flutter_compile executable (used for doctor/engine features). Default: flutter_compile (uses PATH)."

    // ── Action names ─────────────────────────────────────────────────────
    const val ACTION_SET_AS_GLOBAL = "Set as Global"
    const val ACTION_PIN_TO_PROJECT = "Pin to Project"
    const val ACTION_OPEN_SDK_FOLDER = "Open SDK Folder"
    const val ACTION_REMOVE_SDK = "Remove SDK"
    const val ACTION_INSTALL_SDK = "Install SDK"
    const val ACTION_DELETE_BUILD = "Delete Build"
    const val ACTION_BUILD_ENGINE = "Build Engine"
    const val ACTION_INIT_ENGINE = "Initialize Engine"
    const val ACTION_REFRESH = "Refresh"
    const val ACTION_INSTALL_SETUP = "Install / Set Up"
    const val ACTION_INSTALL_FVM = "Install FVM"
    const val ACTION_INSTALL_INSTRUCTIONS = "Install Instructions"

    // ── Action descriptions ──────────────────────────────────────────────
    const val DESC_SET_AS_GLOBAL = "Set this SDK as the global default"
    const val DESC_PIN_TO_PROJECT = "Pin this SDK to the current project"
    const val DESC_OPEN_SDK_FOLDER = "Reveal SDK folder in file manager"
    const val DESC_REMOVE_SDK = "Remove this SDK installation"
    const val DESC_DELETE_BUILD = "Delete this engine build output"
    const val DESC_BUILD_ENGINE = "Build the Flutter engine"
    const val DESC_INIT_ENGINE = "Set up engine environment"
    const val DESC_REFRESH = "Refresh engine status"
    const val DESC_REFRESH_SDKS = "Refresh SDK list"
    const val DESC_REFRESH_DOCTOR = "Run doctor checks"
    const val DESC_INSTALL_SETUP = "Install or configure this item"

    // ── Dialog titles ────────────────────────────────────────────────────
    const val DIALOG_INSTALL_SDK = "Install Flutter SDK"
    const val DIALOG_REMOVE_SDK = "Remove SDK"
    const val DIALOG_CONFIRM_REMOVE = "Confirm Remove"
    const val DIALOG_PIN_SDK = "Pin SDK to Project"
    const val DIALOG_OPEN_SDK_FOLDER = "Open SDK Folder"
    const val DIALOG_DELETE_BUILD = "Delete Build"
    const val DIALOG_BUILD_ENGINE = "Build Engine"

    // ── Dialog messages ──────────────────────────────────────────────────
    const val MSG_ENTER_SDK_VERSION = "Enter Flutter SDK version or channel to install:"
    const val MSG_SELECT_SDK_REMOVE = "Select SDK to remove:"
    const val MSG_SELECT_SDK_PIN = "Select SDK to pin to this project:"
    const val MSG_SELECT_SDK_OPEN = "Select SDK folder to open:"
    const val MSG_NO_REMOVABLE_SDKS = "No removable SDKs installed."
    const val MSG_NO_SDKS_INSTALLED = "No SDKs installed."
    const val MSG_CANNOT_DETERMINE_PATH = "Cannot determine project path."

    // ── Progress titles ──────────────────────────────────────────────────
    const val PROGRESS_LOADING_SDKS = "Loading SDKs..."
    const val PROGRESS_LOADING_ENGINE = "Loading engine status..."
    const val PROGRESS_RUNNING_DOCTOR = "Running doctor checks..."
    const val PROGRESS_INSTALLING_CLI = "Installing flutter_compile CLI..."

    // ── Terminal names ───────────────────────────────────────────────────
    const val TERMINAL_FLUTTER_COMPILE = "flutter_compile"
    const val TERMINAL_ENGINE_BUILD = "Engine Build"

    // ── Notification titles ──────────────────────────────────────────────
    const val NOTIFY_FVM_NOT_FOUND = "FVM not found"
    const val NOTIFY_GIT_NOT_FOUND = "Git not found"
    const val NOTIFY_CLI_NOT_FOUND = "flutter_compile CLI not found"
    const val NOTIFY_INSTALLED = "Installed"
    const val NOTIFY_INSTALL_FAILED = "Installation failed"
    const val NOTIFY_DEPOT_TOOLS_INSTALLED = "depot_tools installed"
    const val NOTIFY_CONFIG_EXISTS = "Config exists"
    const val NOTIFY_CONFIG_CREATED = "Config created"
    const val NOTIFY_CONFIG_FAILED = "Failed to create config"
    const val NOTIFY_NO_AUTO_ACTION = "No automatic action"
    const val NOTIFY_TERMINAL_ERROR = "Terminal error"
    const val NOTIFY_DART_NOT_FOUND = "Cannot find dart executable"
    const val NOTIFY_CLI_INSTALLED = "flutter_compile installed"

    // ── Notification messages ────────────────────────────────────────────
    const val MSG_FVM_NOT_FOUND = "SDK manager is set to FVM mode but the fvm CLI is not installed or not on PATH."
    const val MSG_GIT_NOT_FOUND = "Git is required for native SDK management but is not installed or not on PATH."
    const val MSG_CLI_NOT_FOUND = "SDK management works without it. Install the CLI for doctor and engine features."
    const val MSG_INSTALL_MANUALLY = "Install manually: dart pub global activate flutter_compile"
    const val MSG_CLI_ACTIVATED = "CLI activated successfully."
    const val MSG_UNKNOWN_ERROR = "Unknown error"

    // ── Doctor category keys ─────────────────────────────────────────────
    const val CAT_TOOLS = "tools"
    const val CAT_ENGINE_TOOLS = "engine_tools"
    const val CAT_CONFIG = "config"
    const val CAT_ENVIRONMENTS = "environments"

    // ── Doctor category labels ───────────────────────────────────────────
    const val LABEL_REQUIRED_TOOLS = "Required Tools"
    const val LABEL_ENGINE_TOOLS = "Engine Tools"
    const val LABEL_CONFIGURATION = "Configuration"
    const val LABEL_ENVIRONMENTS = "Environments"

    // ── Doctor check names ───────────────────────────────────────────────
    const val CHECK_NINJA = "ninja"
    const val CHECK_GCLIENT = "gclient"
    const val CHECK_XCODE = "xcode"
    const val CHECK_PYTHON3 = "python3"
    const val CHECK_GIT = "git"

    // ── Doctor status values ─────────────────────────────────────────────
    const val STATUS_OK = "ok"
    const val STATUS_MISSING = "missing"
    const val STATUS_NOT_FOUND = "not_found"
    const val STATUS_INVALID = "invalid"
    const val STATUS_ERROR = "error"
    const val STATUS_NOT_CONFIGURED = "not_configured"
    const val STATUS_MISSING_REMOTES = "missing_remotes"
    const val STATUS_NOT_GIT_REPO = "not_git_repo"

    // ── Doctor action labels ─────────────────────────────────────────────
    const val DOCTOR_ACTION_NINJA = "Install ninja (Homebrew)"
    const val DOCTOR_ACTION_DEPOT_TOOLS = "Install depot_tools"
    const val DOCTOR_ACTION_XCODE = "Install Xcode Command Line Tools"
    const val DOCTOR_ACTION_PYTHON = "Download Python"
    const val DOCTOR_ACTION_GIT = "Download Git"
    const val DOCTOR_ACTION_RC_FILE = "Create default config"
    const val DOCTOR_ACTION_SET_UP = "Set up"
    const val DOCTOR_ACTION_INSTALL = "Install"

    // ── Doctor install progress titles ───────────────────────────────────
    const val PROGRESS_INSTALLING_NINJA = "Installing ninja..."
    const val PROGRESS_INSTALLING_XCODE_CLT = "Installing Xcode CLT..."
    const val PROGRESS_INSTALLING_DEPOT_TOOLS = "Installing depot_tools..."

    // ── Doctor status descriptions ───────────────────────────────────────
    const val DESC_NOT_INSTALLED = "not installed"
    const val DESC_NOT_CONFIGURED = "not configured"
    const val DESC_NOT_GIT_REPO = "not a git repo"

    // ── Doctor tree empty text ───────────────────────────────────────────
    const val EMPTY_DOCTOR_HINT = "Click refresh to run doctor checks."
    const val EMPTY_DOCTOR_CLI_MISSING = "flutter_compile CLI not found."
    const val EMPTY_DOCTOR_INSTALL_LINK = "Install now"

    // ── SDKs tree empty text ─────────────────────────────────────────────
    const val EMPTY_SDKS_HINT = "No SDKs installed. Click + to install."

    // ── Builds tree empty text ───────────────────────────────────────────
    const val EMPTY_BUILDS_HINT = "No engine configured."
    const val EMPTY_BUILDS_INIT_LINK = "Initialize engine"

    // ── Build info labels ────────────────────────────────────────────────
    const val BUILD_LABEL_ENGINE = "Engine"
    const val BUILD_LABEL_SOURCE = "Source"
    const val BUILD_LABEL_HOST_CPU = "Host CPU"
    const val BUILD_SOURCE_OK = "OK"
    const val BUILD_SOURCE_NOT_FOUND = "Not found"

    // ── Build dialog labels ──────────────────────────────────────────────
    const val BUILD_CHECKBOX_UNOPT = "Unoptimized (faster dev builds)"
    const val BUILD_CHECKBOX_CLEAN = "Clean before building"
    const val BUILD_CHECKBOX_FORCE_GN = "Force re-run GN"

    // ── Build platforms & modes ──────────────────────────────────────────
    val BUILD_PLATFORMS = arrayOf("host", "android", "ios", "macos", "linux", "web")
    val BUILD_MODES = arrayOf("debug", "profile", "release")

    // ── SDK cell markers ─────────────────────────────────────────────────
    const val MARKER_GLOBAL = "global"
    const val MARKER_PROJECT = "project"
    const val MARKER_CONTRIBUTOR = "contributor"

    // ── Doctor environment prefixes ──────────────────────────────────────
    const val ENV_PREFIX_FLUTTER = "Flutter"
    const val ENV_PREFIX_DEVTOOLS = "DevTools"
    const val ENV_PREFIX_ENGINE = "Engine"

    // ── CLI environment install names ────────────────────────────────────
    const val ENV_NAME_FLUTTER = "flutter"
    const val ENV_NAME_DEVTOOLS = "devtools"
    const val ENV_NAME_ENGINE = "engine"

    // ── Miscellaneous ────────────────────────────────────────────────────
    const val GIT_HEAD_FILE = ".git/HEAD"
    const val RC_FILE_DEFAULT_CONTENT = "{}\n"
    const val SHELL_ENV_KEY = "SHELL"
    const val ENV_PUB_CACHE = "PUB_CACHE"
    const val ENV_FLUTTER_COMPILE_SDK = "FLUTTER_COMPILE_SDK"
    const val ENV_LOCAL_APP_DATA = "LOCALAPPDATA"
    const val SHELL_ZSH = "zsh"
    const val TOOL_WINDOW_PANEL_KEY_NAME = "FlutterCompileToolWindowPanel"
    const val DOCTOR_SUMMARY_FORMAT = "  %d/%d OK"
}
