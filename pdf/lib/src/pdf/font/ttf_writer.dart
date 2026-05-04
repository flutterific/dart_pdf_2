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

import 'dart:math' as math;
import 'dart:typed_data';

import 'ttf_parser.dart';

/// Generate a TTF font copy with the minimal number of glyph to embed
/// into the PDF document
///
/// https://opentype.js.org/
/// https://github.com/HinTak/Font-Validator
class TtfWriter {
  /// Create a TrueType Writer object
  TtfWriter(this.ttf);

  /// Original TrueType file
  final TtfParser ttf;

  int _calcTableChecksum(ByteData table) {
    assert(table.lengthInBytes % 4 == 0);
    var sum = 0;
    for (var i = 0; i < table.lengthInBytes - 3; i += 4) {
      sum = (sum + table.getUint32(i)) & 0xffffffff;
    }
    return sum;
  }

  void _updateCompoundGlyph(TtfGlyphInfo glyph, Map<int, int?> compoundMap) {
    const arg1And2AreWords = 1;
    const weHaveAScale = 8;
    const moreComponents = 32;
    const weHaveAnXAndYScale = 64;
    const weHaveATwoByTwo = 128;

    var offset = 10;
    final bytes = glyph.data.buffer.asByteData(
      glyph.data.offsetInBytes,
      glyph.data.lengthInBytes,
    );
    var flags = moreComponents;

    while (flags & moreComponents != 0) {
      if (offset + 4 > bytes.lengthInBytes) {
        break;
      }
      flags = bytes.getUint16(offset);
      final glyphIndex = bytes.getUint16(offset + 2);
      final newIndex = compoundMap[glyphIndex];
      if (newIndex != null) {
        bytes.setUint16(offset + 2, newIndex);
      }
      offset += (flags & arg1And2AreWords != 0) ? 8 : 6;
      if (flags & weHaveAScale != 0) {
        offset += 2;
      } else if (flags & weHaveAnXAndYScale != 0) {
        offset += 4;
      } else if (flags & weHaveATwoByTwo != 0) {
        offset += 8;
      }
    }
  }

  int _wordAlign(int offset, [int align = 4]) {
    return offset + ((align - (offset % align)) % align);
  }

  /// Write this list of glyphs.
  /// [charToGid] is populated with the mapping from char code to new GID.
  ///
  /// When [dedup] is true (default) glyphs shared by multiple chars are
  /// emitted once and `charToGid` / cmap entries route every char to that
  /// single slot. When false, each char in [chars] gets its own glyph slot,
  /// keeping `glyphsInfo[i]` aligned with `chars[i]`. Required for the CID
  /// /Type0 path where Identity-H makes the position-in-cmap the GID.
  Uint8List withChars(
    List<int> chars, {
    Map<int, int>? charToGid,
    bool dedup = true,
  }) {
    final tables = <String, Uint8List>{};
    final tablesLength = <String, int>{};

    // Create the glyphs table
    final glyphsMap = <int, TtfGlyphInfo>{};
    final charMap = <int, int>{};
    final overflow = <int>{};
    final compounds = <int, int>{};

    for (final char in chars) {
      if (char == 32) {
        final glyph = TtfGlyphInfo(
          ttf.charToGlyphIndexMap[char]!,
          Uint8List(0),
          const <int>[],
        );
        glyphsMap[glyph.index] = glyph;
        charMap[char] = glyph.index;
        continue;
      }

      final glyphIndex = ttf.charToGlyphIndexMap[char] ?? 0;
      if (glyphIndex >= ttf.glyphOffsets.length) {
        assert(() {
          print('Glyph $glyphIndex not in the font ${ttf.fontName}');
          return true;
        }());
        continue;
      }

      void addGlyph(glyphIndex) {
        final glyph = ttf.readGlyph(glyphIndex).copy();
        for (final g in glyph.compounds) {
          compounds[g] = -1;
          overflow.add(g);
          addGlyph(g);
        }
        glyphsMap[glyph.index] = glyph;
      }

      charMap[char] = glyphIndex;
      addGlyph(glyphIndex);
    }

    // Build compact glyph list: glyphs in chars order, then compounds.
    // origToNewGid tracks where each original GID landed in glyphsInfo, so
    // cmap subtable entries, charToGid, and compound references all resolve
    // to a real slot — never the loop index, which drifts on dedup or skip.
    final glyphsInfo = <TtfGlyphInfo>[];
    final origToNewGid = <int, int>{};

    for (final char in chars) {
      final glyphsIndex = charMap[char];
      if (glyphsIndex == null) {
        continue;
      }
      if (dedup && origToNewGid.containsKey(glyphsIndex)) {
        continue;
      }
      final glyph = glyphsMap[glyphsIndex];
      if (glyph == null) {
        continue;
      }
      origToNewGid.putIfAbsent(glyphsIndex, () => glyphsInfo.length);
      glyphsInfo.add(glyph);
    }

    // Add compound child glyphs that no char referenced directly.
    for (final entry in glyphsMap.entries) {
      if (origToNewGid.containsKey(entry.key)) {
        continue;
      }
      origToNewGid[entry.key] = glyphsInfo.length;
      glyphsInfo.add(entry.value);
    }

    // Build charToGid mapping: char code → new GID in compact list
    if (charToGid != null) {
      for (final char in chars) {
        final origGid = charMap[char];
        if (origGid == null) {
          continue;
        }
        final newGid = origToNewGid[origGid];
        if (newGid == null) {
          continue;
        }
        charToGid[char] = newGid;
      }
    }

    // Compound references point at the first occurrence of each origGid.
    for (final compound in compounds.keys) {
      final newGid = origToNewGid[compound];
      assert(newGid != null, 'Unable to find the glyph');
      compounds[compound] = newGid ?? 0;
    }

    // update compound indices
    for (final glyph in glyphsInfo) {
      if (glyph.compounds.isNotEmpty) {
        _updateCompoundGlyph(glyph, compounds);
      }
    }

    var glyphsTableLength = 0;
    for (final glyph in glyphsInfo) {
      glyphsTableLength = _wordAlign(
        glyphsTableLength + glyph.data.lengthInBytes,
      );
    }
    var offset = 0;
    final glyphsTable = Uint8List(_wordAlign(glyphsTableLength));
    tables[TtfParser.glyf_table] = glyphsTable;
    tablesLength[TtfParser.glyf_table] = glyphsTableLength;

    // Loca
    if (ttf.indexToLocFormat == 0) {
      tables[TtfParser.loca_table] = Uint8List(
        _wordAlign((glyphsInfo.length + 1) * 2),
      ); // uint16
      tablesLength[TtfParser.loca_table] = (glyphsInfo.length + 1) * 2;
    } else {
      tables[TtfParser.loca_table] = Uint8List(
        _wordAlign((glyphsInfo.length + 1) * 4),
      ); // uint32
      tablesLength[TtfParser.loca_table] = (glyphsInfo.length + 1) * 4;
    }

    {
      final loca = tables[TtfParser.loca_table]!.buffer.asByteData();
      var index = 0;
      for (final glyph in glyphsInfo) {
        if (ttf.indexToLocFormat == 0) {
          loca.setUint16(index, offset ~/ 2);
          index += 2;
        } else {
          loca.setUint32(index, offset);
          index += 4;
        }
        glyphsTable.setAll(offset, glyph.data);
        offset = _wordAlign(offset + glyph.data.lengthInBytes);
      }
      if (ttf.indexToLocFormat == 0) {
        loca.setUint16(index, offset ~/ 2);
      } else {
        loca.setUint32(index, offset);
      }
    }

    // Copy tables from the original file (including hinting tables)
    for (final tn in {
      TtfParser.head_table,
      TtfParser.maxp_table,
      TtfParser.hhea_table,
      TtfParser.os_2_table,
      'cvt ',
      'fpgm',
      'prep',
    }) {
      final start = ttf.tableOffsets[tn];
      if (start == null) {
        continue;
      }
      final len = ttf.tableSize[tn]!;
      final data = Uint8List.fromList(
        ttf.bytes.buffer.asUint8List(start, _wordAlign(len)),
      );
      tables[tn] = data;
      tablesLength[tn] = len;
    }

    tables[TtfParser.head_table]!.buffer.asByteData().setUint32(
      8,
      0,
    ); // checkSumAdjustment
    tables[TtfParser.maxp_table]!.buffer.asByteData().setUint16(
      4,
      glyphsInfo.length,
    );
    tables[TtfParser.hhea_table]!.buffer.asByteData().setUint16(
      34,
      glyphsInfo.length,
    ); // numOfLongHorMetrics

    {
      // post Table
      final start = ttf.tableOffsets[TtfParser.post_table]!;
      const len = 32;
      final data = Uint8List.fromList(
        ttf.bytes.buffer.asUint8List(start, _wordAlign(len)),
      );
      data.buffer.asByteData().setUint32(0, 0x00030000); // Version 3.0 no names
      tables[TtfParser.post_table] = data;
      tablesLength[TtfParser.post_table] = len;
    }

    {
      // HMTX table
      final len = 4 * glyphsInfo.length;
      final hmtx = Uint8List(_wordAlign(len));
      final hmtxOffset = ttf.tableOffsets[TtfParser.hmtx_table]!;
      final hmtxData = hmtx.buffer.asByteData();
      final numOfLongHorMetrics = ttf.numOfLongHorMetrics;
      final defaultAdvanceWidth = ttf.bytes.getUint16(
        hmtxOffset + (numOfLongHorMetrics - 1) * 4,
      );
      var index = 0;
      for (final glyph in glyphsInfo) {
        final advanceWidth = glyph.index < numOfLongHorMetrics
            ? ttf.bytes.getUint16(hmtxOffset + glyph.index * 4)
            : defaultAdvanceWidth;
        final leftBearing = glyph.index < numOfLongHorMetrics
            ? ttf.bytes.getInt16(hmtxOffset + glyph.index * 4 + 2)
            : ttf.bytes.getInt16(
                hmtxOffset +
                    numOfLongHorMetrics * 4 +
                    (glyph.index - numOfLongHorMetrics) * 2,
              );
        hmtxData.setUint16(index, advanceWidth);
        hmtxData.setInt16(index + 2, leftBearing);
        index += 4;
      }
      tables[TtfParser.hmtx_table] = hmtx;
      tablesLength[TtfParser.hmtx_table] = len;
    }

    {
      // CMAP table - platform 3/encoding 1 (Windows Unicode BMP), format 12
      // Maps Unicode code points to compact GIDs. The PDF viewer maps
      // WinAnsi byte values to Unicode, then looks up in this (3,1) cmap.
      // This handles all characters including em dash (U+2014).
      final cmapEntries = <List<int>>[];
      for (var i = 1; i < chars.length; i++) {
        if (chars[i] <= 0) {
          continue;
        }
        final origGid = charMap[chars[i]];
        if (origGid == null) {
          continue;
        }
        final newGid = origToNewGid[origGid];
        if (newGid == null) {
          continue;
        }
        cmapEntries.add([chars[i], newGid]); // Unicode → compact GID
      }
      cmapEntries.sort((a, b) => a[0].compareTo(b[0]));

      // Merge consecutive Unicode runs with consecutive GIDs
      final groups = <List<int>>[];
      for (final entry in cmapEntries) {
        if (groups.isNotEmpty &&
            entry[0] == groups.last[1] + 1 &&
            entry[1] == groups.last[2] + entry[0] - groups.last[0]) {
          groups.last[1] = entry[0];
        } else {
          groups.add([entry[0], entry[0], entry[1]]);
        }
      }

      final numGroups = groups.length;
      final subtableLen = 16 + numGroups * 12;
      final len = 4 + 8 + subtableLen; // header(4) + encoding record(8) + subtable
      final cmap = Uint8List(_wordAlign(len));
      final cmapData = cmap.buffer.asByteData();
      // Header
      cmapData.setUint16(0, 0); // version
      cmapData.setUint16(2, 1); // numTables
      // Encoding record: platform 3 (Windows), encoding 1 (Unicode BMP)
      cmapData.setUint16(4, 3); // platformID
      cmapData.setUint16(6, 1); // encodingID
      cmapData.setUint32(8, 12); // offset to subtable
      // Format 12 subtable
      cmapData.setUint16(12, 12); // format
      cmapData.setUint32(16, subtableLen); // length
      cmapData.setUint32(20, 0); // language
      cmapData.setUint32(24, numGroups); // numGroups
      for (var i = 0; i < numGroups; i++) {
        final off = 28 + i * 12;
        cmapData.setUint32(off, groups[i][0]); // startCharCode
        cmapData.setUint32(off + 4, groups[i][1]); // endCharCode
        cmapData.setUint32(off + 8, groups[i][2]); // startGlyphID
      }

      tables[TtfParser.cmap_table] = cmap;
      tablesLength[TtfParser.cmap_table] = len;
    }

    {
      // name table - copy from original to preserve font name
      final start = ttf.tableOffsets[TtfParser.name_table];
      if (start != null) {
        final len = ttf.tableSize[TtfParser.name_table]!;
        final data = Uint8List.fromList(
            ttf.bytes.buffer.asUint8List(start, _wordAlign(len)));
        tables[TtfParser.name_table] = data;
        tablesLength[TtfParser.name_table] = len;
      } else {
        const len = 18;
        final nameBuf = Uint8List(_wordAlign(len));
        final nameData = nameBuf.buffer.asByteData();
        nameData.setUint16(0, 0);
        nameData.setUint16(2, 0);
        nameData.setUint16(4, 6);
        tables[TtfParser.name_table] = nameBuf;
        tablesLength[TtfParser.name_table] = len;
      }
    }

    {
      final bytes = BytesBuilder();

      final numTables = tables.length;

      // Create the file header
      final start = ByteData(12 + numTables * 16);
      start.setUint32(0, 0x00010000);
      start.setUint16(4, numTables);
      var maxPow2 = 1;
      while (maxPow2 * 2 <= numTables) {
        maxPow2 *= 2;
      }
      start.setUint16(6, maxPow2 * 16);
      start.setUint16(8, (math.log(maxPow2) / math.log(2)).round());
      start.setUint16(10, numTables * 16 - maxPow2 * 16);

      // Create the table directory
      var count = 0;
      var offset = 12 + numTables * 16;
      var headOffset = 0;

      final tableKeys = tables.keys.toList()..sort();

      for (final name in tableKeys) {
        final data = tables[name]!;
        final runes = name.runes.toList();
        start.setUint8(12 + count * 16, runes[0]);
        start.setUint8(12 + count * 16 + 1, runes[1]);
        start.setUint8(12 + count * 16 + 2, runes[2]);
        start.setUint8(12 + count * 16 + 3, runes[3]);
        start.setUint32(
          12 + count * 16 + 4,
          _calcTableChecksum(data.buffer.asByteData()),
        ); // checkSum
        start.setUint32(12 + count * 16 + 8, offset); // offset
        start.setUint32(12 + count * 16 + 12, tablesLength[name]!); // length

        if (name == 'head') {
          headOffset = offset;
        }
        offset += data.lengthInBytes;
        count++;
      }
      bytes.add(start.buffer.asUint8List());

      for (final name in tableKeys) {
        final data = tables[name]!;
        bytes.add(data.buffer.asUint8List());
      }

      final output = bytes.toBytes();

      final crc = 0xB1B0AFBA - _calcTableChecksum(output.buffer.asByteData());
      output.buffer.asByteData().setUint32(
        headOffset + 8,
        crc & 0xffffffff,
      ); // checkSumAdjustment

      return output;
    }
  }
}
