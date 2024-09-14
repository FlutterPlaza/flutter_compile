extension ConsoleColor on String {
  String get red => '\x1B[31m$this\x1B[0m';
  String get green => '\x1B[32m$this\x1B[0m';
  String get yellow => '\x1B[33m$this\x1B[0m';
  String get blue => '\x1B[34m$this\x1B[0m';
  String get magenta => '\x1B[35m$this\x1B[0m';
  String get cyan => '\x1B[36m$this\x1B[0m';
  String get white => '\x1B[37m$this\x1B[0m';
}
