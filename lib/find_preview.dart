import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:gpt_markdown/plusparse/scanner.dart' as syntax;

import 'document_find.dart';

/// Mirrors the lazy preview's segment order, including its omission of
/// definition-only rows. Keep the original UTF-16 coordinates across CRLF.
class PreviewFindMap {
  final blocks =
      <({int start, int end, String visibleSource, TextRange? codeBody})>[];
  final rawOffsets = <int>[];

  PreviewFindMap(String source) {
    final normalized = StringBuffer();
    for (var i = 0; i < source.length; i++) {
      rawOffsets.add(i);
      final unit = source.codeUnitAt(i);
      if (unit == 13) {
        normalized.write('\n');
        if (i + 1 < source.length && source.codeUnitAt(i + 1) == 10) i++;
      } else {
        normalized.writeCharCode(unit);
      }
    }
    rawOffsets.add(source.length);
    final text = normalized.toString();
    final defs = MarkdownDefinitions.collect(text);
    var offset = 0;
    final splittingText = _displayMathBoundaries(text);
    for (final segment in splitStreamSegments(splittingText.trim())) {
      final start = splittingText.indexOf(segment, offset);
      if (start < 0) continue;
      offset = start + segment.length;
      final raw = text.substring(start, offset);
      final left = raw.trimLeft();
      if (((left.startsWith('[') && raw.contains(']:')) ||
              left.startsWith('<')) &&
          Plusparse.parse(
            raw,
            definitions: defs,
            useDollarSignsForLatex: true,
          ).children.isEmpty) {
        continue;
      }
      final codeBody = _fencedBody(raw);
      blocks.add((
        start: start,
        end: offset,
        visibleSource: codeBody == null ? _visibleSource(raw, defs) : raw,
        codeBody: codeBody,
      ));
    }
  }

  // The sliver normalizes display math before splitting. Reuse its fence
  // and code-span rules, retaining lengths so offsets still refer to source.
  static String _displayMathBoundaries(String text) {
    if (!text.contains(r'$$')) return text;
    final units = text.codeUnits.toList();
    syntax.FenceOpen? fence;
    var depth = 0;
    var paragraphEnd = -1;
    var i = 0;
    while (i < text.length) {
      if (i == 0 || text[i - 1] == '\n') {
        final newline = text.indexOf('\n', i);
        final end = newline < 0 ? text.length : newline;
        final line = text.substring(i, end);
        final content = syntax.unquoted(line);
        if (syntax.quoteDepth(line) < depth) fence = null;
        final opening = syntax.fenceOpen(content);
        if (fence != null || opening != null) {
          if (fence != null) {
            if (syntax.isFenceClose(content, fence)) fence = null;
          } else {
            fence = opening;
            depth = syntax.quoteDepth(line);
          }
          i = end + 1;
          continue;
        }
      }
      if (text[i] == '\\') {
        i += 2;
        continue;
      }
      if (text.codeUnitAt(i) == 96) {
        if (paragraphEnd < i) paragraphEnd = syntax.paragraphEnd(text, i);
        final code = syntax.codeSpanAt(text, i, end: paragraphEnd);
        i = code == null
            ? i + syntax.backtickRunAt(text, i)
            : code.close + code.run;
        continue;
      }
      if (!text.startsWith(r'$$', i)) {
        i++;
        continue;
      }
      var close = text.indexOf(r'$$', i + 2);
      while (close > 0 && text[close - 1] == '\\') {
        close = text.indexOf(r'$$', close + 1);
      }
      if (close >= 0 &&
          !text
              .substring(i + 2, close)
              .split('\n')
              .skip(1)
              .any((line) => syntax.fenceOpen(syntax.unquoted(line)) != null)) {
        units.setAll(i, r'\['.codeUnits);
        units.setAll(close, r'\]'.codeUnits);
        i = close + 2;
      } else {
        i += 2;
      }
    }
    return String.fromCharCodes(units);
  }

  // CodeField renders the literal body in one paragraph. Its toolbar can
  // also render synthetic text (e.g. "Code"). Do not align that with code.
  // null means normal inline mapping; an invalid range means row-only.
  static TextRange? _fencedBody(String text) {
    if (!text.contains('~~~') && !text.contains('```')) return null;
    syntax.FenceOpen? fence;
    var bodyStart = 0;
    var offset = 0;
    for (final line in text.split('\n')) {
      final end = offset + line.length;
      if (fence == null) {
        final opening = syntax.fenceOpen(syntax.unquoted(line));
        if (opening != null) {
          // Mixed/nested blocks may strip indentation and quote prefixes.
          if (offset != 0 ||
              line != line.trimLeft() ||
              syntax.quoteDepth(line) != 0) {
            return TextRange.empty;
          }
          fence = opening;
          bodyStart = math.min(end + 1, text.length);
        }
      } else if (syntax.indentWidth(line) <= 3 &&
          syntax.isFenceClose(line, fence)) {
        if (end != text.length) return TextRange.empty;
        return TextRange(
          start: bodyStart,
          end: math.max(bodyStart, offset - 1),
        );
      }
      offset = end + 1;
    }
    return fence == null ? null : TextRange(start: bodyStart, end: text.length);
  }

  // Never align a repeated label/prose word with an invisible URL, title,
  // image description, or reference ID. Leave code spans/fences literal.
  static String _visibleSource(String text, MarkdownDefinitions defs) {
    final units = text.codeUnits.toList();
    // ATX heading/blockquote prefixes and list markers have no glyphs.
    // Fences have their own literal mapping in _row.
    final prefixes = RegExp(
      r'^[ \t]*(?:(?:>[ \t]*)+|#{1,6}[ \t]+|[-*+][ \t]+(?:\[[ xX]\][ \t]+)?)',
    );
    var lineOffset = 0;
    for (final line in text.split('\n')) {
      final prefix = prefixes.firstMatch(line);
      if (prefix != null) {
        units.fillRange(lineOffset, lineOffset + prefix.end, 0);
      }
      lineOffset += line.length + 1;
    }
    late final ends = _pairedEnds(text);
    var parsedThrough = 0;
    final dollars = syntax.DollarMathCloser(text);
    final missingClosers = <String>{};
    var i = 0;
    void mask(int start, int end) {
      units.fillRange(start, end, 0);
    }

    while (i < text.length) {
      if (units[i] == 0) {
        i++;
        continue;
      }
      final c = text[i];
      // Equation renderers draw mathematical glyphs; the TeX source has
      // no literal text geometry. Keep later identical prose unambiguous.
      String? mathEnd;
      if (text.startsWith(r'\(', i)) mathEnd = r'\)';
      if (text.startsWith(r'\[', i)) mathEnd = r'\]';
      if (text.startsWith(r'$$', i)) mathEnd = r'$$';
      if (mathEnd != null) {
        final end = missingClosers.contains(mathEnd)
            ? -1
            : text.indexOf(mathEnd, i + 2);
        if (end < 0) missingClosers.add(mathEnd);
        if (end >= 0 &&
            (c == r'$' || syntax.isMathBody(text.substring(i + 2, end)))) {
          mask(i, end + 2);
          i = end + 2;
          continue;
        }
      } else if (c == r'$') {
        final end = dollars.find(i);
        if (end >= 0) {
          mask(i, end + 1);
          i = end + 1;
          continue;
        }
      }
      if (c == '\\' &&
          i + 1 < text.length &&
          syntax.isAsciiPunctuation(text.codeUnitAt(i + 1))) {
        mask(i, i + 1);
        i += 2;
        continue;
      }
      if (c == '\x60') {
        final span = syntax.codeSpanAt(text, i);
        if (span == null) {
          i += syntax.backtickRunAt(text, i);
        } else {
          mask(i, i + span.run);
          mask(span.close, span.close + span.run);
          i = span.close + span.run;
        }
        continue;
      }
      final image = text.startsWith('![', i);
      if (image || c == '[') {
        final label = image ? i + 1 : i;
        final labelEnd = ends[label];
        if (labelEnd != null) {
          var end = labelEnd;
          if (end < text.length && (text[end] == '(' || text[end] == '[')) {
            end = ends[end] ?? end;
          }
          if (end == labelEnd && defs.isEmpty) {
            i++;
            continue;
          }
          // Don't reparse overlapping link candidates. Rendering nested
          // constructs without source spans cannot establish their ownership.
          if (i < parsedThrough) return '';
          parsedThrough = end;
          // Ask the same parser whether this is a real link. Unresolved
          // references and unmatched delimiters remain visible literally.
          final parsed = Plusparse.parse(
            text.substring(i, end),
            definitions: defs,
          );
          final paragraph = parsed.children.firstOrNull;
          final node =
              paragraph is MdParagraph && paragraph.children.length == 1
                  ? paragraph.children.single
                  : null;
          if (node is MdLink || node is MdImage) {
            mask(i, node is MdImage ? end : label + 1);
            mask(labelEnd - 1, end);
            if (node is MdImage) {
              i = end;
              continue;
            }
          }
        }
      }
      if (c == '<' && text.startsWith('<!--', i)) {
        final close = text.indexOf('-->', i + 4);
        final end = close == -1 ? text.length : close + 3;
        mask(i, end);
        i = end;
        continue;
      }
      i++;
    }
    return String.fromCharCodes(units);
  }

  static Map<int, int> _pairedEnds(String text) {
    final ends = <int, int>{};
    final brackets = <int>[], parentheses = <int>[];
    for (var i = 0; i < text.length; i++) {
      switch (text.codeUnitAt(i)) {
        case 0x5c: // Backslash escapes the next delimiter.
          i++;
        case 0x5b: // [
          brackets.add(i);
        case 0x5d: // ]
          if (brackets.isNotEmpty) ends[brackets.removeLast()] = i + 1;
        case 0x28: // (
          parentheses.add(i);
        case 0x29: // )
          if (parentheses.isNotEmpty) ends[parentheses.removeLast()] = i + 1;
      }
    }
    return ends;
  }

  // Map a source boundary to this rendered run without rescanning a long
  // unbroken line for every occurrence of a common character.
  int localOffset(int raw, int base, int length) {
    var low = 0;
    var high = length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (rawOffsets[base + mid] < raw) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  int rowFor(int sourceOffset) {
    var low = 0;
    var high = blocks.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (rawOffsets[blocks[mid].end] <= sourceOffset) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return math.min(low, blocks.length - 1);
  }
}

class PreviewFindPainter extends CustomPainter {
  PreviewFindPainter(
      this.viewportKey, this.scroll, this.find, this.map, this.colors)
      : super(repaint: scroll);
  final GlobalKey viewportKey;
  final ScrollController scroll;
  final DocumentFind find;
  final PreviewFindMap map;
  final ColorScheme colors;

  RenderSliverList? _list(RenderObject root) {
    if (root is RenderSliverList) return root;
    RenderSliverList? result;
    root.visitChildren((child) {
      result ??= _list(child);
    });
    return result;
  }

  // Both navigation and painting consume the *same* glyph boxes. The layout
  // engine supplies these after shaping, wrapping and font fallback.
  Rect? _row(RenderBox row, int index, RenderBox viewport, Canvas? canvas) {
    final block = map.blocks[index];
    final first = find.firstEndingAfter(map.rawOffsets[block.start]);
    if (first == find.hits.length ||
        find.hits[first].start >= map.rawOffsets[block.end]) {
      return null;
    }
    final source = block.visibleSource;
    Rect? active;
    void highlight(RenderParagraph paragraph, int base, int glyph, int length) {
      var n = find.firstEndingAfter(map.rawOffsets[base]);
      while (n < find.hits.length &&
          find.hits[n].start < map.rawOffsets[base + length]) {
        final hit = find.hits[n];
        final selection = TextSelection(
          baseOffset: glyph + map.localOffset(hit.start, base, length),
          extentOffset: glyph + map.localOffset(hit.end, base, length),
        );
        for (final box in paragraph.getBoxesForSelection(selection)) {
          final rect = MatrixUtils.transformRect(
            paragraph.getTransformTo(viewport),
            box.toRect(),
          );
          // Blend the foreground overlay without obscuring the glyph ink.
          final brightness = colors.brightness;
          canvas?.drawRect(
            rect,
            Paint()
              ..color = Color.alphaBlend(
                findHighlight(n == find.index, brightness),
                colors.surface,
              )
              ..blendMode = brightness == Brightness.light
                  ? BlendMode.darken
                  : BlendMode.lighten,
          );
          if (n == find.index) active ??= rect;
        }
        n++;
      }
    }

    final body = block.codeBody;
    if (body != null) {
      if (!body.isValid || body.isCollapsed) return null;
      final literal = body.textInside(source);
      RenderParagraph? paragraph;
      var ambiguous = false;
      void locate(RenderObject object) {
        if (object is RenderParagraph &&
            object.text.toPlainText(includeSemanticsLabels: false) == literal) {
          if (paragraph != null) ambiguous = true;
          paragraph = object;
        }
        object.visitChildren(locate);
      }

      locate(row);
      if (paragraph != null && !ambiguous) {
        highlight(paragraph!, block.start + body.start, 0, literal.length);
      }
      return active;
    }

    // A later mismatch can invalidate an earlier occurrence of repeated text.
    // Validate the entire row before drawing any candidate boxes.
    final runs =
        <({RenderParagraph paragraph, int base, int glyph, int length})>[];
    final skippedMarks = <int>{};
    final renderedMarks = <int>{};
    bool emphasis(int unit) => unit == 42 || unit == 95 || unit == 126;
    bool skippable(int unit) =>
        unit == 0 || syntax.isUnicodeWhitespace(unit) || emphasis(unit);
    var cursor = 0;
    var aligned = true;
    void visit(RenderObject object) {
      if (!aligned) return;
      if (object is! RenderParagraph) {
        object.visitChildren(visit);
        return;
      }
      final inlineChildren = <RenderObject>[];
      object.visitChildren(inlineChildren.add);
      var childIndex = 0;
      var glyph = 0;
      object.text.visitChildren((span) {
        if (!aligned) return false;
        if (span is PlaceholderSpan) {
          if (childIndex < inlineChildren.length) {
            visit(inlineChildren[childIndex++]);
          }
          glyph++;
        } else if (span is TextSpan && span.text != null) {
          final run = span.text!;
          var j = 0;
          while (j < run.length) {
            final unit = run.codeUnitAt(j);
            // Only step past masked syntax, whitespace and emphasis marks.
            // A rendered substitution must not steal the next identical word.
            while (
                cursor < source.length && source.codeUnitAt(cursor) != unit) {
              final skipped = source.codeUnitAt(cursor);
              if (!skippable(skipped)) break;
              if (emphasis(skipped)) skippedMarks.add(skipped);
              cursor++;
            }
            final start = cursor;
            while (j < run.length &&
                cursor < source.length &&
                source.codeUnitAt(cursor) == run.codeUnitAt(j)) {
              final matched = run.codeUnitAt(j);
              if (emphasis(matched)) renderedMarks.add(matched);
              j++;
              cursor++;
            }
            if (cursor == start) {
              if (syntax.isUnicodeWhitespace(unit)) {
                j++;
                continue;
              }
              aligned = false;
              return false;
            }
            final length = cursor - start;
            runs.add((
              paragraph: object,
              base: block.start + start,
              glyph: glyph + j - length,
              length: length,
            ));
          }
          glyph += run.length;
        }
        return true;
      });
    }

    visit(row);
    if (!aligned) return null;
    for (; cursor < source.length; cursor++) {
      final unit = source.codeUnitAt(cursor);
      if (!skippable(unit)) return null;
      if (emphasis(unit)) skippedMarks.add(unit);
    }
    if (skippedMarks.any(renderedMarks.contains)) return null;
    for (final run in runs) {
      highlight(run.paragraph, run.base, run.glyph, run.length);
    }
    return active;
  }

  /// The first visible glyph box, or null when the
  /// source match has no preview glyph or the block is outside the cache.
  Rect? currentGlyphBox() {
    final root = viewportKey.currentContext?.findRenderObject();
    if (root is! RenderBox || find.current == null) return null;
    final list = _list(root);
    final target = map.rowFor(find.current!.start);
    if (list == null || target < 0) return null;
    for (var row = list.firstChild; row != null; row = list.childAfter(row)) {
      if (list.indexOf(row) == target) return _row(row, target, root, null);
    }
    return null;
  }

  double? _belowTarget;
  double? _aboveTarget;

  /// Returns false if another layout pass is needed to mount a distant row.
  bool reveal() {
    final root = viewportKey.currentContext?.findRenderObject();
    if (root is! RenderBox || !scroll.hasClients || find.current == null) {
      return true;
    }
    final list = _list(root);
    if (list == null || list.firstChild == null) return true;
    final target = map.rowFor(find.current!.start);
    if (target < 0) return true;
    final pos = scroll.position;
    final first = list.indexOf(list.firstChild!);
    final last = list.indexOf(list.lastChild!);
    double delta;
    if (target < first || target > last) {
      final distance = target < first ? target - first : target - last;
      final mean = (list.childScrollOffset(list.lastChild!)! +
              list.lastChild!.size.height -
              list.childScrollOffset(list.firstChild!)!) /
          (last - first + 1);
      delta = distance.sign *
          math.max(pos.viewportDimension * .8, mean * distance.abs());
    } else {
      var row = list.firstChild!;
      while (list.indexOf(row) < target) {
        row = list.childAfter(row)!;
      }
      final active = currentGlyphBox();
      final y =
          active?.top ?? row.localToGlobal(Offset.zero, ancestor: root).dy;
      delta = y - root.size.height * .4;
    }
    if (target < first) _aboveTarget = pos.pixels;
    if (target > last) _belowTarget = pos.pixels;
    final low = _belowTarget;
    final high = _aboveTarget;
    final bracketed = (target < first || target > last) &&
        low != null &&
        high != null &&
        low < high;
    final offset = (bracketed ? (low + high) / 2 : pos.pixels + delta)
        .clamp(pos.minScrollExtent, pos.maxScrollExtent);
    if ((offset - pos.pixels).abs() < .5) return true;
    scroll.jumpTo(offset.toDouble());
    return target >= first && target <= last;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final root = viewportKey.currentContext?.findRenderObject();
    if (root is! RenderBox) return;
    final list = _list(root);
    if (list == null) return;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (var child = list.firstChild;
        child != null;
        child = list.childAfter(child)) {
      final index = list.indexOf(child);
      if (index < map.blocks.length) _row(child, index, root, canvas);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(PreviewFindPainter oldDelegate) => true;
}
