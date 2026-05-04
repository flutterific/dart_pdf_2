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

import 'dart:convert';
import 'dart:typed_data';

import '../document.dart';
import '../font/arabic.dart' as arabic;
import '../font/bidi_utils.dart' as bidi;
import '../font/font_metrics.dart';
import '../font/ttf_parser.dart';
import '../font/ttf_writer.dart';
import '../format/array.dart';
import '../format/dict.dart';
import '../format/name.dart';
import '../format/num.dart';
import '../format/stream.dart';
import '../format/string.dart';
import '../options.dart';
import 'font.dart';
import 'font_descriptor.dart';
import 'object.dart';
import 'object_stream.dart';
import 'unicode_cmap.dart';

class PdfTtfFont extends PdfFont {
  /// Constructs a [PdfTtfFont]
  PdfTtfFont(PdfDocument pdfDocument, ByteData bytes, {bool protect = false})
    : font = TtfParser(bytes),
      super.create(pdfDocument, subtype: '/TrueType') {
    file = PdfObjectStream(pdfDocument, isBinary: true);
    unicodeCMap = PdfUnicodeCmap(pdfDocument, protect);
    descriptor = PdfFontDescriptor(this, file);
    widthsObject = PdfObject<PdfArray>(pdfDocument, params: PdfArray());
  }

  /// Use simple /TrueType for WinAnsi text (printer-compatible),
  /// fall back to /Type0 CID for non-WinAnsi text (CJK etc.)
  @override
  String get subtype =>
      font.unicode && !_useSimpleTrueType ? '/Type0' : '/TrueType';

  late PdfUnicodeCmap unicodeCMap;

  late PdfFontDescriptor descriptor;

  late PdfObjectStream file;

  late PdfObject<PdfArray> widthsObject;

  final TtfParser font;

  /// Tracks char→GID mapping built during subsetting
  final Map<int, int> _charToGid = {};

  /// True = simple /TrueType + WinAnsi (printer-safe for Latin text).
  /// False = CID /Type0 + Identity-H (needed for CJK).
  /// Locked on the first putText call based on actual text content:
  /// if any non-WinAnsi character appears, CID is used from the start.
  bool _useSimpleTrueType = true;
  bool _encodingLocked = false;

  @override
  String get fontName => font.fontName;

  @override
  double get ascent => font.ascent.toDouble() / font.unitsPerEm;

  @override
  double get descent => font.descent.toDouble() / font.unitsPerEm;

  @override
  int get unitsPerEm => font.unitsPerEm;

  @override
  PdfFontMetrics glyphMetrics(int charCode) {
    final g = font.charToGlyphIndexMap[charCode];

    if (g == null) {
      return PdfFontMetrics.zero;
    }

    if (useBidi && bidi.isArabicDiacriticValue(charCode)) {
      final metric = font.glyphInfoMap[g] ?? PdfFontMetrics.zero;
      return metric.copyWith(advanceWidth: 0);
    }

    if (useArabic && arabic.isArabicDiacriticValue(charCode)) {
      final metric = font.glyphInfoMap[g] ?? PdfFontMetrics.zero;
      return metric.copyWith(advanceWidth: 0);
    }

    return font.glyphInfoMap[g] ?? PdfFontMetrics.zero;
  }

  void _buildTrueType(PdfDict params) {
    int charMin;
    int charMax;

    file.buf.putBytes(font.bytes.buffer.asUint8List());
    file.params['/Length1'] = PdfNum(font.bytes.lengthInBytes);

    params['/BaseFont'] = PdfName('/$fontName');
    params['/FontDescriptor'] = descriptor.ref();
    charMin = 32;
    charMax = 255;
    for (var i = charMin; i <= charMax; i++) {
      widthsObject.params.add(
        PdfNum((glyphMetrics(i).advanceWidth * 1000.0).toInt()),
      );
    }
    params['/FirstChar'] = PdfNum(charMin);
    params['/LastChar'] = PdfNum(charMax);
    params['/Widths'] = widthsObject.ref();
  }

  /// Build a simple /TrueType font with WinAnsi encoding.
  /// Universally supported by all printers.
  void _buildSimpleTrueType(PdfDict params) {
    final ttfWriter = TtfWriter(font);
    final data = ttfWriter.withChars(unicodeCMap.cmap, charToGid: _charToGid);
    file.buf.putBytes(data);
    file.params['/Length1'] = PdfNum(data.length);

    params['/BaseFont'] = PdfName('/$fontName');
    params['/FontDescriptor'] = descriptor.ref();

    // Widths for WinAnsi byte codes 0-255
    // Byte values 128-159 map to special Unicode code points (em dash, smart
    // quotes, etc.); 160-255 map to Latin-1 Supplement (accented chars).
    const charMin = 0;
    const charMax = 255;
    for (var byteVal = charMin; byteVal <= charMax; byteVal++) {
      final unicode = winAnsiToUnicode(byteVal);
      if (unicode > 0 && unicodeCMap.cmap.contains(unicode)) {
        widthsObject.params.add(PdfNum(
            (glyphMetrics(unicode).advanceWidth * 1000.0).toInt()));
      } else {
        widthsObject.params.add(const PdfNum(0));
      }
    }
    params['/FirstChar'] = const PdfNum(charMin);
    params['/LastChar'] = const PdfNum(charMax);
    params['/Widths'] = widthsObject.ref();
    params['/ToUnicode'] = unicodeCMap.ref();
  }

  /// Build a CID /Type0 font with Identity-H encoding.
  /// Required for CJK and other non-WinAnsi text.
  void _buildType0(PdfDict params) {
    int charMin;
    int charMax;

    // dedup: false keeps glyphsInfo[i] aligned with unicodeCMap.cmap[i].
    // putText writes CID = cmap.indexOf(rune), and Identity-H treats CID as
    // GID, so the embedded font must have the rune's glyph at that exact slot.
    final ttfWriter = TtfWriter(font);
    final data = ttfWriter.withChars(unicodeCMap.cmap, dedup: false);
    file.buf.putBytes(data);
    file.params['/Length1'] = PdfNum(data.length);

    final descendantFont = PdfDict.values({
      '/Type': const PdfName('/Font'),
      '/BaseFont': PdfName('/$fontName'),
      '/FontFile2': file.ref(),
      '/FontDescriptor': descriptor.ref(),
      '/W': PdfArray([
        const PdfNum(0),
        widthsObject.ref(),
      ]),
      '/CIDToGIDMap': const PdfName('/Identity'),
      '/DW': const PdfNum(1000),
      '/Subtype': const PdfName('/CIDFontType2'),
      '/CIDSystemInfo': PdfDict.values({
        '/Supplement': const PdfNum(0),
        '/Registry': PdfString.fromString('Adobe'),
        '/Ordering': PdfString.fromString('Identity-H'),
      })
    });

    params['/BaseFont'] = PdfName('/$fontName');
    params['/Encoding'] = const PdfName('/Identity-H');
    params['/DescendantFonts'] = PdfArray([descendantFont]);
    params['/ToUnicode'] = unicodeCMap.ref();

    charMin = 0;
    charMax = unicodeCMap.cmap.length - 1;
    for (var i = charMin; i <= charMax; i++) {
      widthsObject.params.add(PdfNum(
          (glyphMetrics(unicodeCMap.cmap[i]).advanceWidth * 1000.0).toInt()));
    }
  }

  @override
  void prepare() {
    super.prepare();

    if (!font.unicode) {
      _buildTrueType(params);
    } else if (_useSimpleTrueType) {
      _buildSimpleTrueType(params);
    } else {
      // CJK path: configure ToUnicode for 2-byte CID keys
      unicodeCMap.useWinAnsiKeys = false;
      _buildType0(params);
    }
  }

  @override
  void putText(PdfStream stream, String text) {
    if (!font.unicode) {
      super.putText(stream, text);
      return;
    }

    final runes = text.runes;

    // Track characters for subsetting
    for (final rune in runes) {
      if (!unicodeCMap.cmap.contains(rune)) {
        unicodeCMap.cmap.add(rune);
      }
    }

    // Lock encoding mode on first call: if ANY rune in this first batch
    // is non-WinAnsi, commit to CID for the entire font lifetime.
    if (!_encodingLocked) {
      _encodingLocked = true;
      for (final rune in runes) {
        if (unicodeToWinAnsi(rune) < 0) {
          _useSimpleTrueType = false;
          break;
        }
      }
    }

    stream.putByte(0x3c);
    if (_useSimpleTrueType) {
      // Single-byte WinAnsi encoding (Latin text)
      for (final rune in runes) {
        final byteVal = unicodeToWinAnsi(rune);
        final code = byteVal >= 0 ? byteVal : 0x3F; // '?' fallback
        stream.putBytes(
            latin1.encode(code.toRadixString(16).padLeft(2, '0')));
      }
    } else {
      // Two-byte CID encoding (CJK text)
      for (final rune in runes) {
        var char = unicodeCMap.cmap.indexOf(rune);
        if (char == -1) {
          char = unicodeCMap.cmap.length;
          unicodeCMap.cmap.add(rune);
        }
        stream.putBytes(
            latin1.encode(char.toRadixString(16).padLeft(4, '0')));
      }
    }
    stream.putByte(0x3e);
  }

  @override
  PdfFontMetrics stringMetrics(String s, {double letterSpacing = 0}) {
    if (s.isEmpty || !font.unicode) {
      return super.stringMetrics(s, letterSpacing: letterSpacing);
    }

    final runes = s.runes;
    final bytes = <int>[];
    runes.forEach(bytes.add);

    final metrics = bytes.map(glyphMetrics);
    return PdfFontMetrics.append(metrics, letterSpacing: letterSpacing);
  }

  @override
  bool isRuneSupported(int charCode) {
    return font.charToGlyphIndexMap.containsKey(charCode);
  }
}
