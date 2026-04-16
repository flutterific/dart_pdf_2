/*
 * Copyright (C) 2017, David PHAM-VAN <dev.nfet.net@gmail.com>
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import '../document.dart';
import 'object_stream.dart';

/// WinAnsi (CP-1252) byte values 128-159 that differ from Unicode.
/// Bytes 0-127 and 160-255 map to the same Unicode code point.
const winAnsiSpecialBytes = <int, int>{
  128: 0x20AC, 130: 0x201A, 131: 0x0192, 132: 0x201E,
  133: 0x2026, 134: 0x2020, 135: 0x2021, 136: 0x02C6,
  137: 0x2030, 138: 0x0160, 139: 0x2039, 140: 0x0152,
  142: 0x017D, 145: 0x2018, 146: 0x2019, 147: 0x201C,
  148: 0x201D, 149: 0x2022, 150: 0x2013, 151: 0x2014,
  152: 0x02DC, 153: 0x2122, 154: 0x0161, 155: 0x203A,
  156: 0x0153, 158: 0x017E, 159: 0x0178,
};

/// Reverse lookup: Unicode → WinAnsi byte value, built from the same table.
final _unicodeToWinAnsiMap = {
  for (final e in winAnsiSpecialBytes.entries) e.value: e.key
};

/// Maps Unicode code points to WinAnsi (CP-1252) byte values.
/// Returns -1 if the character is not representable in WinAnsi.
int unicodeToWinAnsi(int unicode) {
  if (unicode < 128) return unicode;
  if (_unicodeToWinAnsiMap.containsKey(unicode)) {
    return _unicodeToWinAnsiMap[unicode]!;
  }
  if (unicode >= 160 && unicode <= 255) return unicode;
  return -1;
}

/// Maps WinAnsi byte value back to Unicode code point.
int winAnsiToUnicode(int byteVal) {
  if (byteVal < 128 || byteVal >= 160) return byteVal;
  return winAnsiSpecialBytes[byteVal] ?? byteVal;
}

/// Unicode character map object
class PdfUnicodeCmap extends PdfObjectStream {
  /// Create a Unicode character map object
  PdfUnicodeCmap(PdfDocument pdfDocument, this.protect) : super(pdfDocument);

  /// List of characters (index 0 = .notdef, index N = Nth unique Unicode char)
  final cmap = <int>[0];

  /// Protects the text from being "seen" by the PDF reader.
  final bool protect;

  /// When true, keys are WinAnsi byte values (1-byte, for simple TrueType).
  /// When false, keys are CID indices (2-byte, for CID Type0/CJK).
  bool useWinAnsiKeys = true;

  @override
  void prepare() {
    final entries = <List<int>>[];
    final padLen = useWinAnsiKeys ? 2 : 4;
    final codeSpaceEnd = useWinAnsiKeys ? 'FF' : 'FFFF';

    if (useWinAnsiKeys) {
      // WinAnsi: map byte values → Unicode
      for (var i = 1; i < cmap.length; i++) {
        final unicode = protect ? 0x20 : cmap[i];
        final byteVal = unicodeToWinAnsi(unicode);
        if (byteVal >= 0) {
          entries.add([byteVal, unicode]);
        }
      }
    } else {
      // CID: map cmap index → Unicode
      if (protect) {
        cmap.fillRange(1, cmap.length, 0x20);
      }
      for (var key = 0; key < cmap.length; key++) {
        entries.add([key, cmap[key]]);
      }
    }

    buf.putString('/CIDInit/ProcSet\nfindresource begin\n'
        '12 dict begin\n'
        'begincmap\n'
        '/CIDSystemInfo<<\n'
        '/Registry (Adobe)\n'
        '/Ordering (UCS)\n'
        '/Supplement 0\n'
        '>> def\n'
        '/CMapName/Adobe-Identity-UCS def\n'
        '/CMapType 2 def\n'
        '1 begincodespacerange\n'
        '<${'0' * padLen}> <$codeSpaceEnd>\n'
        'endcodespacerange\n');

    // beginbfchar supports max 100 entries per section
    var remaining = entries.length;
    var offset = 0;
    while (remaining > 0) {
      final count = remaining > 100 ? 100 : remaining;
      buf.putString('$count beginbfchar\n');
      for (var j = 0; j < count; j++) {
        final key = entries[offset + j][0];
        final value = entries[offset + j][1];
        final keyHex =
            key.toRadixString(16).toUpperCase().padLeft(padLen, '0');
        final valHex =
            value.toRadixString(16).toUpperCase().padLeft(4, '0');
        buf.putString('<$keyHex> <$valHex>\n');
      }
      buf.putString('endbfchar\n');
      offset += count;
      remaining -= count;
    }

    buf.putString('endcmap\n'
        'CMapName currentdict /CMap defineresource pop\n'
        'end\n'
        'end');
    super.prepare();
  }
}
