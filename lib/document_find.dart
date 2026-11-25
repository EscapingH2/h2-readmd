import 'package:flutter/material.dart';

/// All offsets are UTF-16 offsets into the unmodified editor string.
class DocumentFind {
  String source = '';
  String query = '';
  bool matchCase = false;
  List<TextRange> hits = const [];
  int index = -1;
  TextRange? get current => index < 0 ? null : hits[index];

  void update(String text, String needle, bool sensitive, {int? anchor}) {
    final start = anchor ?? current?.start ?? 0;
    source = text;
    query = needle;
    matchCase = sensitive;
    hits = needle.isEmpty
        ? const []
        : [
            for (final m in RegExp(RegExp.escape(needle),
                    caseSensitive: sensitive, unicode: true)
                .allMatches(text))
              TextRange(start: m.start, end: m.end),
          ];
    index = hits.isEmpty ? -1 : firstEndingAfter(start);
    if (index == hits.length) index = 0;
  }

  int firstEndingAfter(int offset) {
    var low = 0;
    var high = hits.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (hits[mid].end <= offset) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  void move(int delta) {
    if (hits.isNotEmpty) index = (index + delta) % hits.length;
  }

  String replace(String replacement, {required bool all}) {
    final out = StringBuffer();
    var offset = 0;
    for (final hit in all ? hits : [current!]) {
      out.write(source.substring(offset, hit.start));
      out.write(replacement);
      offset = hit.end;
    }
    return (out..write(source.substring(offset))).toString();
  }
}

Color findHighlight(bool active, Brightness brightness) =>
    brightness == Brightness.dark
        ? (active ? const Color(0xbaaa7431) : const Color(0x805e777f))
        : (active ? const Color(0xbaffaa39) : const Color(0x80ffdf69));

class FindEditingController extends TextEditingController {
  final find = DocumentFind();

  @override
  TextSpan buildTextSpan(
      {required BuildContext context,
      TextStyle? style,
      required bool withComposing}) {
    if (find.hits.isEmpty || find.source != text) {
      return super.buildTextSpan(
          context: context, style: style, withComposing: withComposing);
    }
    final composing = withComposing && value.isComposingRangeValid
        ? value.composing
        : TextRange.empty;
    final stops = {
      0,
      text.length,
      if (composing.isValid) ...[composing.start, composing.end],
      for (final hit in find.hits) ...[hit.start, hit.end]
    }.toList()
      ..sort();
    final spans = <TextSpan>[];
    var hit = 0;
    final brightness = Theme.of(context).brightness;
    for (var i = 0; i + 1 < stops.length; i++) {
      final start = stops[i];
      while (hit < find.hits.length && find.hits[hit].end <= start) {
        hit++;
      }
      spans.add(TextSpan(
          text: text.substring(start, stops[i + 1]),
          style: TextStyle(
            backgroundColor:
                hit < find.hits.length && find.hits[hit].start <= start
                    ? findHighlight(hit == find.index, brightness)
                    : null,
            decoration: composing.start <= start && start < composing.end
                ? TextDecoration.underline
                : null,
          )));
    }
    return TextSpan(style: style, children: spans);
  }
}
