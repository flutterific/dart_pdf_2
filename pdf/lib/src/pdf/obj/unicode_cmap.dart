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

/// Maps Unicode code points to WinAnsi (CP-1252) byte values.
/// Returns -1 if the character is not representable in WinAnsi.
int unicodeToWinAnsi(int unicode) {
  if (unicode < 128) return unicode;
  const map = <int, int>{
    0x20AC: 128, 0x201A: 130, 0x0192: 131, 0x201E: 132,
    0x2026: 133, 0x2020: 134, 0x2021: 135, 0x02C6: 136,
    0x2030: 137, 0x0160: 138, 0x2039: 139, 0x0152: 140,
    0x017D: 142, 0x2018: 145, 0x2019: 146, 0x201C: 147,
    0x201D: 148, 0x2022: 149, 0x2013: 150, 0x2014: 151,
    0x02DC: 152, 0x2122: 153, 0x0161: 154, 0x203A: 155,
    0x0153: 156, 0x017E: 158, 0x0178: 159,
  };
  if (map.containsKey(unicode)) return map[unicode]!;
  if (unicode >= 160 && unicode <= 255) return unicode;
  return -1;
}

/// Unicode character map object
class PdfUnicodeCmap extends PdfObjectStream {
  /// Create a Unicode character map object
  PdfUnicodeCmap(PdfDocument pdfDocument, this.protect) : super(pdfDocument);

  /// List of characters (index 0 = .notdef, index N = Nth unique Unicode char)
  final cmap = <int>[0];

  /// Protects the text from being "seen" by the PDF reader.
  final bool protect;

  @override
  void prepare() {
    // Map WinAnsi byte values → Unicode for text extraction
    final entries = <List<int>>[];
    for (var i = 1; i < cmap.length; i++) {
      final unicode = protect ? 0x20 : cmap[i];
      final byteVal = unicodeToWinAnsi(unicode);
      if (byteVal >= 0) {
        entries.add([byteVal, unicode]);
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
        '<00> <FF>\n'
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
        final keyHex = key.toRadixString(16).toUpperCase().padLeft(2, '0');
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
