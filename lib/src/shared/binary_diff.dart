// Standalone BSDIFF50 binary diff/patch implementation.
//
// Extracted from flutter_tools' binary_diff.dart. Contains only the pure
// algorithmic functions with no framework dependencies.

import 'dart:io' as io;
import 'dart:typed_data';

/// Magic bytes identifying a BSDIFF50 format patch.
const List<int> _kMagic = <int>[
  0x42, 0x53, 0x44, 0x49, 0x46, 0x46, 0x35, 0x30, // "BSDIFF50"
];

/// Size of the BSDIFF50 header in bytes.
const int _kHeaderSize = 32;

/// Generates a BSDIFF50-format diff from [oldBytes] to [newBytes].
///
/// The returned patch, when applied to [oldBytes] via [bspatch], will
/// reproduce [newBytes] exactly.
Uint8List bsdiff(Uint8List oldBytes, Uint8List newBytes) {
  final int oldSize = oldBytes.length;
  final int newSize = newBytes.length;

  // Build suffix array of old file.
  final Int32List suffixArray = _buildSuffixArray(oldBytes);

  // Scan new file against old file using the suffix array.
  final List<int> controlAdd = <int>[];
  final List<int> controlCopy = <int>[];
  final List<int> controlSeek = <int>[];
  final List<int> diffBlock = <int>[];
  final List<int> extraBlock = <int>[];

  int scan = 0;
  int len = 0;
  int pos = 0;
  int lastScan = 0;
  int lastPos = 0;
  int lastOffset = 0;

  while (scan < newSize) {
    int oldScore = 0;
    int matchLen = 0;

    scan += len;
    int prevScan = scan;
    while (scan < newSize) {
      final _MatchResult match = _matchLen(suffixArray, oldBytes, oldSize, newBytes, newSize, scan);
      matchLen = match.length;
      pos = match.position;

      while (prevScan < scan) {
        if (prevScan + lastOffset < oldSize &&
            oldBytes[prevScan + lastOffset] == newBytes[prevScan]) {
          oldScore++;
        }
        prevScan++;
      }

      if ((matchLen == oldScore && matchLen != 0) || (matchLen > oldScore + 8)) {
        break;
      }

      if (scan + lastOffset < oldSize &&
          oldBytes[scan + lastOffset] == newBytes[scan]) {
        oldScore--;
      }

      scan++;
    }

    len = matchLen;

    if (len != oldScore || scan == newSize) {
      // Count forward matches from lastScan.
      int s = 0;
      int sf = 0;
      int lenF = 0;
      for (int i = 0; i < scan - lastScan && i < oldSize - lastPos; i++) {
        if (oldBytes[lastPos + i] == newBytes[lastScan + i]) {
          s++;
        }
        if (s * 2 - i > sf * 2 - lenF) {
          sf = s;
          lenF = i + 1;
        }
      }

      // Count backward matches from scan.
      int lenB = 0;
      if (scan < newSize) {
        s = 0;
        int sb = 0;
        for (int i = 1; i < scan - lastScan && i < pos; i++) {
          if (oldBytes[pos - i] == newBytes[scan - i]) {
            s++;
          }
          if (s * 2 - i > sb * 2 - lenB) {
            sb = s;
            lenB = i;
          }
        }
      }

      // Handle overlap.
      if (lenF + lenB > scan - lastScan) {
        final int overlap = lenF + lenB - (scan - lastScan);
        s = 0;
        int ss = 0;
        int splitLen = 0;
        for (int i = 0; i < overlap; i++) {
          if (newBytes[lastScan + lenF - overlap + i] ==
              oldBytes[lastPos + lenF - overlap + i]) {
            s++;
          }
          if (newBytes[scan - lenB + i] == oldBytes[pos - lenB + i]) {
            s--;
          }
          if (s > ss) {
            ss = s;
            splitLen = i + 1;
          }
        }
        lenF += splitLen - overlap;
        lenB -= splitLen;
      }

      // Build diff bytes for the "add" region.
      for (int i = 0; i < lenF; i++) {
        diffBlock.add((newBytes[lastScan + i] - oldBytes[lastPos + i]) & 0xFF);
      }

      // Build extra bytes for the "copy" region.
      for (int i = 0; i < (scan - lenB) - (lastScan + lenF); i++) {
        extraBlock.add(newBytes[lastScan + lenF + i]);
      }

      // Record control tuple.
      controlAdd.add(lenF);
      controlCopy.add((scan - lenB) - (lastScan + lenF));
      controlSeek.add((pos - lenB) - (lastPos + lenF));

      lastScan = scan - lenB;
      lastPos = pos - lenB;
      lastOffset = pos - scan;
    }
  }

  // Encode the patch.
  return _encodePatch(controlAdd, controlCopy, controlSeek, diffBlock, extraBlock, newSize);
}

/// Applies a BSDIFF50-format [patch] to [oldBytes] to produce the new file.
///
/// Throws [FormatException] if the patch data is invalid or corrupted.
Uint8List bspatch(Uint8List oldBytes, Uint8List patch) {
  if (patch.length < _kHeaderSize) {
    throw const FormatException('Patch too small to contain BSDIFF50 header');
  }

  // Validate magic bytes.
  for (int i = 0; i < 8; i++) {
    if (patch[i] != _kMagic[i]) {
      throw const FormatException('Invalid BSDIFF50 magic bytes');
    }
  }

  final ByteData header = patch.buffer.asByteData(patch.offsetInBytes);
  final int newSize = header.getInt64(8, Endian.little);
  final int controlCompressedSize = header.getInt64(16, Endian.little);
  final int diffCompressedSize = header.getInt64(24, Endian.little);

  if (newSize < 0) {
    throw FormatException('Invalid new file size in patch header: $newSize');
  }
  if (controlCompressedSize < 0 || diffCompressedSize < 0) {
    throw const FormatException('Invalid block sizes in patch header');
  }

  final int controlStart = _kHeaderSize;
  final int diffStart = controlStart + controlCompressedSize;
  final int extraStart = diffStart + diffCompressedSize;

  if (diffStart > patch.length || extraStart > patch.length) {
    throw const FormatException('Patch file is truncated');
  }

  // Decompress each block.
  final Uint8List controlData = _zlibDecompress(
    Uint8List.sublistView(patch, controlStart, diffStart),
  );
  final Uint8List diffData = _zlibDecompress(
    Uint8List.sublistView(patch, diffStart, extraStart),
  );
  final Uint8List extraData = _zlibDecompress(
    Uint8List.sublistView(patch, extraStart),
  );

  // Parse control tuples.
  if (controlData.length % 24 != 0) {
    throw FormatException(
      'Control block size (${controlData.length}) is not a multiple of 24',
    );
  }

  final ByteData controlBd = controlData.buffer.asByteData(controlData.offsetInBytes);
  final int numTuples = controlData.length ~/ 24;

  // Apply the patch.
  final Uint8List newBytes = Uint8List(newSize);
  int newPos = 0;
  int oldPos = 0;
  int diffPos = 0;
  int extraPos = 0;

  for (int i = 0; i < numTuples; i++) {
    final int addLen = controlBd.getInt64(i * 24, Endian.little);
    final int copyLen = controlBd.getInt64(i * 24 + 8, Endian.little);
    final int seekOffset = controlBd.getInt64(i * 24 + 16, Endian.little);

    if (addLen < 0 || copyLen < 0) {
      throw FormatException('Invalid control tuple at index $i');
    }
    if (newPos + addLen > newSize) {
      throw FormatException('Add region overflows new file at tuple $i');
    }
    if (diffPos + addLen > diffData.length) {
      throw FormatException('Diff data underflow at tuple $i');
    }

    // Apply diff bytes: newBytes = oldBytes + diffData.
    for (int j = 0; j < addLen; j++) {
      final int oldByte = (oldPos + j >= 0 && oldPos + j < oldBytes.length)
          ? oldBytes[oldPos + j]
          : 0;
      newBytes[newPos + j] = (oldByte + diffData[diffPos + j]) & 0xFF;
    }
    newPos += addLen;
    diffPos += addLen;
    oldPos += addLen;

    // Copy extra bytes directly.
    if (newPos + copyLen > newSize) {
      throw FormatException('Copy region overflows new file at tuple $i');
    }
    if (extraPos + copyLen > extraData.length) {
      throw FormatException('Extra data underflow at tuple $i');
    }
    for (int j = 0; j < copyLen; j++) {
      newBytes[newPos + j] = extraData[extraPos + j];
    }
    newPos += copyLen;
    extraPos += copyLen;

    // Seek in old file.
    oldPos += seekOffset;
  }

  return newBytes;
}

/// Encodes the bsdiff output into BSDIFF50 format with zlib compression.
Uint8List _encodePatch(
  List<int> controlAdd,
  List<int> controlCopy,
  List<int> controlSeek,
  List<int> diffBlock,
  List<int> extraBlock,
  int newSize,
) {
  // Build control block: each tuple is 3x int64 = 24 bytes.
  final int numTuples = controlAdd.length;
  final Uint8List controlBytes = Uint8List(numTuples * 24);
  final ByteData controlBd = controlBytes.buffer.asByteData();
  for (int i = 0; i < numTuples; i++) {
    controlBd.setInt64(i * 24, controlAdd[i], Endian.little);
    controlBd.setInt64(i * 24 + 8, controlCopy[i], Endian.little);
    controlBd.setInt64(i * 24 + 16, controlSeek[i], Endian.little);
  }

  // Compress each block.
  final Uint8List compressedControl = _zlibCompress(controlBytes);
  final Uint8List compressedDiff = _zlibCompress(Uint8List.fromList(diffBlock));
  final Uint8List compressedExtra = _zlibCompress(Uint8List.fromList(extraBlock));

  // Build the final patch.
  final int totalSize = _kHeaderSize +
      compressedControl.length +
      compressedDiff.length +
      compressedExtra.length;
  final Uint8List patch = Uint8List(totalSize);
  final ByteData headerBd = patch.buffer.asByteData();

  // Write header.
  for (int i = 0; i < 8; i++) {
    patch[i] = _kMagic[i];
  }
  headerBd.setInt64(8, newSize, Endian.little);
  headerBd.setInt64(16, compressedControl.length, Endian.little);
  headerBd.setInt64(24, compressedDiff.length, Endian.little);

  // Write compressed blocks.
  int offset = _kHeaderSize;
  patch.setRange(offset, offset + compressedControl.length, compressedControl);
  offset += compressedControl.length;
  patch.setRange(offset, offset + compressedDiff.length, compressedDiff);
  offset += compressedDiff.length;
  patch.setRange(offset, offset + compressedExtra.length, compressedExtra);

  return patch;
}

/// Compresses [data] using zlib (GZip).
Uint8List _zlibCompress(Uint8List data) {
  final List<int> compressed = io.gzip.encode(data);
  return Uint8List.fromList(compressed);
}

/// Decompresses zlib (GZip) [data].
Uint8List _zlibDecompress(Uint8List data) {
  if (data.isEmpty) {
    return Uint8List(0);
  }
  try {
    final List<int> decompressed = io.gzip.decode(data);
    return Uint8List.fromList(decompressed);
  } on Exception {
    throw const FormatException('Failed to decompress patch block');
  }
}

/// Result of a suffix array match search.
class _MatchResult {
  const _MatchResult(this.length, this.position);
  final int length;
  final int position;
}

/// Finds the longest match of newBytes[newStart..] in oldBytes using [sa].
_MatchResult _matchLen(
  Int32List sa,
  Uint8List oldBytes,
  int oldSize,
  Uint8List newBytes,
  int newSize,
  int newStart,
) {
  if (oldSize == 0) {
    return const _MatchResult(0, 0);
  }

  int lo = 0;
  int hi = oldSize - 1;
  int bestLen = 0;
  int bestPos = 0;

  while (lo <= hi) {
    final int mid = lo + ((hi - lo) >> 1);
    final int saIdx = sa[mid];

    // Compare newBytes[newStart..] with oldBytes[saIdx..].
    int matchLength = 0;
    int i = saIdx;
    int j = newStart;
    while (i < oldSize && j < newSize) {
      if (oldBytes[i] != newBytes[j]) {
        break;
      }
      matchLength++;
      i++;
      j++;
    }

    if (matchLength > bestLen) {
      bestLen = matchLength;
      bestPos = saIdx;
    }

    // Determine search direction.
    if (i < oldSize && j < newSize) {
      if (oldBytes[i] < newBytes[j]) {
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    } else if (i == oldSize) {
      // Old suffix exhausted; old is "less than" new.
      lo = mid + 1;
    } else {
      // New suffix exhausted; we matched fully, but try to find a longer one.
      // The match is exactly newSize - newStart, which is maximal.
      break;
    }
  }

  return _MatchResult(bestLen, bestPos);
}

// ============================================================================
// SA-IS (Suffix Array by Induced Sorting) Algorithm
// O(n) time and space suffix array construction for byte sequences.
// ============================================================================

/// Builds a suffix array from [data] using the SA-IS algorithm.
Int32List _buildSuffixArray(Uint8List data) {
  final int n = data.length;
  if (n == 0) {
    return Int32List(0);
  }
  if (n == 1) {
    return Int32List.fromList(<int>[0]);
  }

  // Convert to int array with sentinel (value 0, which is less than any byte
  // value since we shift bytes to 1..256).
  final Int32List text = Int32List(n + 1);
  for (int i = 0; i < n; i++) {
    text[i] = data[i] + 1; // Shift to 1..256
  }
  text[n] = 0; // Sentinel

  final Int32List sa = Int32List(n + 1);
  _sais(text, sa, n + 1, 257);

  // Remove the sentinel entry (always at sa[0]) and return.
  return Int32List.fromList(sa.sublist(1));
}

/// Core SA-IS implementation. Sorts suffixes of [text] (length [n]) over
/// alphabet [0..alphabetSize-1] into [sa].
void _sais(Int32List text, Int32List sa, int n, int alphabetSize) {
  // Step 1: Classify each suffix as S-type or L-type.
  final Uint8List types = Uint8List(n); // 0 = L-type, 1 = S-type
  types[n - 1] = 1; // Sentinel is S-type
  for (int i = n - 2; i >= 0; i--) {
    if (text[i] < text[i + 1]) {
      types[i] = 1;
    } else if (text[i] > text[i + 1]) {
      types[i] = 0;
    } else {
      types[i] = types[i + 1];
    }
  }

  // Step 2: Find bucket boundaries.
  final Int32List bucketSizes = Int32List(alphabetSize);
  for (int i = 0; i < n; i++) {
    bucketSizes[text[i]]++;
  }
  final Int32List bucketStarts = Int32List(alphabetSize);
  final Int32List bucketEnds = Int32List(alphabetSize);
  int sum = 0;
  for (int i = 0; i < alphabetSize; i++) {
    bucketStarts[i] = sum;
    sum += bucketSizes[i];
    bucketEnds[i] = sum - 1;
  }

  // Step 3: Find all LMS (Left-Most S-type) suffixes.
  final List<int> lmsPositions = <int>[];
  for (int i = 1; i < n; i++) {
    if (types[i] == 1 && types[i - 1] == 0) {
      lmsPositions.add(i);
    }
  }

  // Step 4: Induced-sort the LMS suffixes to get their relative order.
  // Place LMS suffixes at the end of their buckets.
  sa.fillRange(0, n, -1);
  final Int32List tailPtrs = Int32List.fromList(bucketEnds);
  for (int i = lmsPositions.length - 1; i >= 0; i--) {
    final int pos = lmsPositions[i];
    sa[tailPtrs[text[pos]]--] = pos;
  }

  // Induce L-type suffixes from the front.
  final Int32List headPtrs = Int32List.fromList(bucketStarts);
  for (int i = 0; i < n; i++) {
    if (sa[i] > 0 && types[sa[i] - 1] == 0) {
      sa[headPtrs[text[sa[i] - 1]]++] = sa[i] - 1;
    }
  }

  // Induce S-type suffixes from the end.
  tailPtrs.setAll(0, bucketEnds);
  for (int i = n - 1; i >= 0; i--) {
    if (sa[i] > 0 && types[sa[i] - 1] == 1) {
      sa[tailPtrs[text[sa[i] - 1]]--] = sa[i] - 1;
    }
  }

  // Step 5: Compact sorted LMS suffixes and recursively sort if needed.
  // Check if all LMS substrings are unique.
  if (lmsPositions.length <= 1) {
    return; // Already sorted (0 or 1 LMS suffixes).
  }

  // Assign names to LMS substrings based on sorted order.
  final Int32List lmsNames = Int32List(n);
  lmsNames.fillRange(0, n, -1);

  int name = 0;
  int prevLms = -1;
  for (int i = 0; i < n; i++) {
    final int pos = sa[i];
    if (pos > 0 && types[pos] == 1 && types[pos - 1] == 0) {
      // This is an LMS suffix. Compare with previous LMS substring.
      if (prevLms >= 0 && !_lmsSubstringsEqual(text, types, prevLms, pos, n)) {
        name++;
      }
      lmsNames[pos] = name;
      prevLms = pos;
    }
  }
  // The sentinel at position n-1 is also LMS (for SA-IS purposes).
  // It should have been handled if present in the loop.

  if (name + 1 < lmsPositions.length) {
    // Not all LMS substrings are unique -- need to recurse.
    final Int32List reducedText = Int32List(lmsPositions.length);
    for (int i = 0; i < lmsPositions.length; i++) {
      reducedText[i] = lmsNames[lmsPositions[i]];
    }

    final Int32List reducedSA = Int32List(lmsPositions.length);
    _sais(reducedText, reducedSA, lmsPositions.length, name + 1);

    // Reconstruct LMS order from recursive result.
    // Place LMS suffixes in the correct order.
    sa.fillRange(0, n, -1);
    tailPtrs.setAll(0, bucketEnds);
    for (int i = lmsPositions.length - 1; i >= 0; i--) {
      final int pos = lmsPositions[reducedSA[i]];
      sa[tailPtrs[text[pos]]--] = pos;
    }
  } else {
    // All LMS substrings are unique -- the current order is correct.
    // Re-place LMS suffixes in sorted order.
    sa.fillRange(0, n, -1);
    tailPtrs.setAll(0, bucketEnds);
    for (int i = lmsPositions.length - 1; i >= 0; i--) {
      final int pos = lmsPositions[i];
      // Find the rank of this LMS suffix.
      sa[tailPtrs[text[pos]]--] = pos;
    }

    // Actually we need the correct order. Re-derive from names.
    sa.fillRange(0, n, -1);
    tailPtrs.setAll(0, bucketEnds);
    // Build sorted order from lmsNames.
    final List<int> sortedLms = List<int>.from(lmsPositions)
      ..sort((int a, int b) => lmsNames[a] - lmsNames[b]);
    for (int i = sortedLms.length - 1; i >= 0; i--) {
      final int pos = sortedLms[i];
      sa[tailPtrs[text[pos]]--] = pos;
    }
  }

  // Step 6: Final induced sort.
  headPtrs.setAll(0, bucketStarts);
  for (int i = 0; i < n; i++) {
    if (sa[i] > 0 && types[sa[i] - 1] == 0) {
      sa[headPtrs[text[sa[i] - 1]]++] = sa[i] - 1;
    }
  }

  tailPtrs.setAll(0, bucketEnds);
  for (int i = n - 1; i >= 0; i--) {
    if (sa[i] > 0 && types[sa[i] - 1] == 1) {
      sa[tailPtrs[text[sa[i] - 1]]--] = sa[i] - 1;
    }
  }
}

/// Compares two LMS substrings starting at [pos1] and [pos2].
bool _lmsSubstringsEqual(Int32List text, Uint8List types, int pos1, int pos2, int n) {
  for (int i = 0; ; i++) {
    final int p1 = pos1 + i;
    final int p2 = pos2 + i;

    if (p1 >= n || p2 >= n) {
      return false;
    }

    if (text[p1] != text[p2] || types[p1] != types[p2]) {
      return false;
    }

    // Past the first character, check if we've reached the end of either
    // LMS substring (next LMS position or end of string).
    if (i > 0) {
      final bool isLms1 = types[p1] == 1 && (p1 == 0 || types[p1 - 1] == 0);
      final bool isLms2 = types[p2] == 1 && (p2 == 0 || types[p2 - 1] == 0);
      if (isLms1 || isLms2) {
        return isLms1 && isLms2;
      }
    }
  }
}
