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

  /// Always /TrueType — we use simple TrueType encoding for printer compat
  @override
  String get subtype => '/TrueType';

  late PdfUnicodeCmap unicodeCMap;

  late PdfFontDescriptor descriptor;

  late PdfObjectStream file;

  late PdfObject<PdfArray> widthsObject;

  final TtfParser font;

  /// Tracks char→GID mapping built during subsetting
  final Map<int, int> _charToGid = {};

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
  /// Matches the structure produced by reportlab which is universally
  /// supported by all printers.
  void _buildSimpleTrueType(PdfDict params) {
    final ttfWriter = TtfWriter(font);
    final data = ttfWriter.withChars(unicodeCMap.cmap, charToGid: _charToGid);
    file.buf.putBytes(data);
    file.params['/Length1'] = PdfNum(data.length);

    params['/BaseFont'] = PdfName('/$fontName');
    params['/FontDescriptor'] = descriptor.ref();

    // Widths for byte codes 0-127 using the charToGid mapping
    const charMin = 0;
    const charMax = 127;
    for (var byteVal = charMin; byteVal <= charMax; byteVal++) {
      // For WinAnsi, byte values 0-127 = Unicode 0-127
      if (unicodeCMap.cmap.contains(byteVal)) {
        widthsObject.params.add(PdfNum(
            (glyphMetrics(byteVal).advanceWidth * 1000.0).toInt()));
      } else {
        widthsObject.params.add(const PdfNum(0));
      }
    }
    params['/FirstChar'] = const PdfNum(charMin);
    params['/LastChar'] = const PdfNum(charMax);
    params['/Widths'] = widthsObject.ref();
    params['/ToUnicode'] = unicodeCMap.ref();
  }

  @override
  void prepare() {
    super.prepare();

    if (font.unicode) {
      _buildSimpleTrueType(params);
    } else {
      _buildTrueType(params);
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

    // Write single-byte WinAnsi values
    stream.putByte(0x3c);
    for (final rune in runes) {
      final byteVal = unicodeToWinAnsi(rune);
      final code = byteVal >= 0 ? byteVal : 0x3F; // '?' for unmappable
      stream.putBytes(
          latin1.encode(code.toRadixString(16).padLeft(2, '0')));
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
