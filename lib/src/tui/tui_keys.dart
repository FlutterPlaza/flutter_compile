enum TuiKey {
  up,
  down,
  left,
  right,
  enter,
  escape,
  tab,
  key1,
  key2,
  key3,
  key4,
  keyI,
  keyR,
  keyD,
  keyQ,
  ctrlC,
  unknown,
}

TuiKey parseKey(List<int> bytes) {
  if (bytes.isEmpty) return TuiKey.unknown;

  // Single byte keys
  if (bytes.length == 1) {
    return switch (bytes[0]) {
      3 => TuiKey.ctrlC,
      9 => TuiKey.tab,
      10 || 13 => TuiKey.enter,
      27 => TuiKey.escape,
      49 => TuiKey.key1,
      50 => TuiKey.key2,
      51 => TuiKey.key3,
      52 => TuiKey.key4,
      100 || 68 => TuiKey.keyD, // d or D
      105 || 73 => TuiKey.keyI, // i or I
      113 || 81 => TuiKey.keyQ, // q or Q
      114 || 82 => TuiKey.keyR, // r or R
      _ => TuiKey.unknown,
    };
  }

  // ANSI escape sequences (ESC [ ...)
  if (bytes.length == 3 && bytes[0] == 27 && bytes[1] == 91) {
    return switch (bytes[2]) {
      65 => TuiKey.up,
      66 => TuiKey.down,
      67 => TuiKey.right,
      68 => TuiKey.left,
      _ => TuiKey.unknown,
    };
  }

  return TuiKey.unknown;
}
