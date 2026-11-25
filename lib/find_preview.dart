import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:gpt_markdown/plusparse/scanner.dart' as syntax;

import 'document_find.dart';

/// Mirrors the lazy preview's segment order, including its omission of
/// definition-only rows. Keep the original UTF-16 coordinates across CRLF.
class PreviewFindMap {
  final blocks = <({int start, int end, String visibleSource})>[];
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
      if ((left.startsWith('[') || left.startsWith('<')) &&
          Plusparse.parse(raw, definitions: defs, useDollarSignsForLatex: true)
              .children
              .isEmpty) {
        continue;
      }
      blocks.add((
        start: start,
        end: offset,
        visibleSource: _visibleSource(raw, defs)
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

  // Never align a repeated label/prose word with an invisible URL, title,
  // image description, or reference ID. Leave code spans/fences literal.
  static String _visibleSource(String text, MarkdownDefinitions defs) {
    final units = text.codeUnits.toList();
    // ATX heading/blockquote prefixes and list markers have no glyphs.
    // Keep fenced payloads untouched, including lines beginning with "# ".
    final prefixes = RegExp(
        r'^[ \t]*(?:(?:>[ \t]*)+|#{1,6}[ \t]+|[-*+][ \t]+(?:\[[ xX]\][ \t]+)?)');
    final fence = RegExp(r'^\s*(`{3,}|~{3,})');
    String? delimiter;
    var lineOffset = 0;
    for (final line in text.split('\n')) {
      final marker = fence.firstMatch(line)?.group(1);
      if (delimiter != null) {
        if (marker != null &&
            marker.startsWith(delimiter) &&
            line.trim() == marker) {
          delimiter = null;
        }
      } else if (marker != null) {
        delimiter = marker;
      } else {
        final prefix = prefixes.firstMatch(line);
        if (prefix != null) {
          units.fillRange(lineOffset, lineOffset + prefix.end, 0);
        }
      }
      lineOffset += line.length + 1;
    }
    final dollars = syntax.DollarMathCloser(text);
    var i = 0;
    void mask(int start, int end) {
      units.fillRange(start, end, 0);
    }

    while (i < text.length) {
      if (units[i] == 0) { i++; continue; }
      final c = text[i];
      // Equation renderers draw mathematical glyphs; the TeX source has
      // no literal text geometry. Keep later identical prose unambiguous.
      String? mathEnd;
      if (text.startsWith(r'\(', i)) mathEnd = r'\)';
      if (text.startsWith(r'\[', i)) mathEnd = r'\]';
      if (text.startsWith(r'$$', i)) mathEnd = r'$$';
      if (mathEnd != null) {
        final end = text.indexOf(mathEnd, i + 2);
        if (end >= 0) {
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
      if (c == '\\') {
        i += 2;
        continue;
      }
      if (c == '\x60' || (c == '~' && text.startsWith('~~~', i))) {
        var end = i + 1;
        while (end < text.length && text[end] == c) {
          end++;
        }
        final close = text.indexOf(text.substring(i, end), end);
        i = close < 0 ? end : close + end - i;
        continue;
      }
      final image = text.startsWith('![', i);
      if (image || c == '[') {
        final label = image ? i + 1 : i;
        final labelEnd = balancedEnd(text, label, '[', ']');
        if (labelEnd != null) {
          var end = labelEnd;
          if (end < text.length && text[end] == '(') {
            end = balancedEnd(text, end, '(', ')') ?? end;
          } else if (end < text.length && text[end] == '[') {
            end = balancedEnd(text, end, '[', ']') ?? end;
          }
          // Ask the same parser whether this is a real link. Unresolved
          // references and unmatched delimiters remain visible literally.
          final parsed =
              Plusparse.parse(text.substring(i, end), definitions: defs);
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

  static int? balancedEnd(String text, int start, String open, String close) {
    var depth = 1;
    for (var i = start + 1; i < text.length; i++) {
      final ch = text[i];
      if (ch == '\\\\') {
        i++;
      } else if (ch == open) {
        depth++;
      } else if (ch == close && --depth == 0) {
        return i + 1;
      }
    }
    return null;
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
    var cursor = 0;
    Rect? active;
    void visit(RenderObject object) {
      if (object is! RenderParagraph) {
        object.visitChildren(visit);
        return;
      }
      final inlineChildren = <RenderObject>[];
      object.visitChildren(inlineChildren.add);
      var childIndex = 0;
      var glyph = 0;
      object.text.visitChildren((span) {
        if (span is PlaceholderSpan) {
          if (childIndex < inlineChildren.length) {
            visit(inlineChildren[childIndex++]);
          }
          glyph++;
        } else if (span is TextSpan && span.text != null) {
          final run = span.text!;
          for (final token in RegExp(r'\S+|\s+').allMatches(run)) {
            final word = token[0]!;
            final start = source.indexOf(word, cursor);
            if (start < 0 || (word.trim().isEmpty && start != cursor)) continue;
            cursor = start + word.length;
            final base = block.start + start;
            var n = find.firstEndingAfter(map.rawOffsets[base]);
            while (n < find.hits.length &&
                find.hits[n].start < map.rawOffsets[base + word.length]) {
              final hit = find.hits[n];
              final a = map.localOffset(hit.start, base, word.length);
              final b = map.localOffset(hit.end, base, word.length);
              for (final box in object.getBoxesForSelection(TextSelection(
                  baseOffset: glyph + token.start + a,
                  extentOffset: glyph + token.start + b))) {
                final rect = MatrixUtils.transformRect(
                    object.getTransformTo(viewport), box.toRect());
                // A viewport underlay disappears behind code/table surfaces.
                // Darken only the lighter pixels (light theme), or lighten
                // only the darker ones (dark theme), preserving text contrast.
                final brightness = colors.brightness;
                canvas?.drawRect(rect, Paint()
                  ..color = Color.alphaBlend(findHighlight(n == find.index, brightness), colors.surface)
                  ..blendMode = brightness == Brightness.light ? BlendMode.darken : BlendMode.lighten);
                if (n == find.index) active ??= rect;
              }
              n++;
            }
          }
          glyph += run.length;
        }
        return true;
      });
    }

    visit(row);
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
