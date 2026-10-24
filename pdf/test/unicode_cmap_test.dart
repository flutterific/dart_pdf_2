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

import 'package:pdf/pdf.dart';
import 'package:pdf/src/pdf/obj/unicode_cmap.dart';
import 'package:test/test.dart';

void main() {
  test('ToUnicode writes UTF-16BE destinations', () {
    final cmap = PdfUnicodeCmap(PdfDocument(), false)
      ..cmap.addAll([
        0x41, // A
        0x1D5EF, // 𝗯, mathematical sans-serif bold small b
        0x20BB7, // 𠮷, CJK Extension B
        0x100043, // SF Symbols private-use icon
      ]);
    cmap.prepare();
    final out = latin1.decode(cmap.buf.output());

    expect(out, contains('<0001> <0041>'));
    expect(out, contains('<0002> <D835DDEF>'));
    expect(out, contains('<0003> <D842DFB7>'));
    expect(out, contains('<0004> <0020>'));
  });
}
