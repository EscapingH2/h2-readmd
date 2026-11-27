import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_reader/document_find.dart';
import 'package:markdown_reader/document_history.dart';

TextEditingValue entry(String text, {int? offset}) => TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: offset ?? text.length),
    );

DocumentHistory track(TextEditingController doc, int budget) {
  final history = DocumentHistory(doc, byteBudget: budget);
  addTearDown(() {
    history.dispose();
    doc.dispose();
  });
  return history;
}

void main() {
  test('Documents retain independent histories through repeated eviction', () {
    final first = TextEditingController.fromValue(entry('00'));
    final second = TextEditingController.fromValue(entry('00'));
    // Each two-code-unit state costs 68 bytes.
    final short = track(first, 3 * 68);
    final long = track(second, 64 * 1024 * 1024);
    for (var i = 1; i <= 30; i++) {
      final next = entry(i.toString().padLeft(2, '0'), offset: i % 3);
      short.replace(next);
      long.replace(next);
    }
    for (var i = 29; i >= 0; i--) {
      short.undo();
      long.undo();
      expect(second.value,
          entry(i.toString().padLeft(2, '0'), offset: i == 0 ? 2 : i % 3));
      final retained = i < 28 ? 28 : i;
      expect(first.value, entry('$retained', offset: retained % 3));
    }
    short.redo();
    short.redo();
    expect(first.value, entry('30', offset: 0));
  });

  test(
      'Branching discards redo before charging and preserves the oldest fitting state',
      () {
    final doc = TextEditingController.fromValue(entry('a'));
    final h = track(doc, 4 * 66);
    for (final s in ['b', 'c', 'd', 'e']) {
      h.replace(entry(s));
    }
    h.undo();
    h.undo(); // b, [c], d, e
    doc.selection = const TextSelection(baseOffset: 1, extentOffset: 0);
    final branchPoint = doc.value;
    doc.value = entry('x');
    h.redo();
    expect(doc.value, entry('x'));
    h.undo();
    expect(doc.value, branchPoint);
    h.undo();
    expect(doc.value, entry('b'));
    h.redo();
    h.replace(entry('longer'));
    h.redo();
    expect(doc.value, entry('longer'));
    h.undo();
    expect(doc.value, branchPoint);
  });

  testWidgets(
      'A growing typing group trims at its new size and keeps the 500 ms boundary',
      (tester) async {
    final doc = TextEditingController.fromValue(entry('a'));
    final h = track(doc, 3 * 66);
    h.replace(entry('b'));
    doc.value = entry('c');
    await tester.pump(const Duration(milliseconds: 499));
    doc.value =
        entry('😀'); // Two UTF-16 units. The oldest state no longer fits.
    await tester.pump(const Duration(milliseconds: 1));
    doc.value = entry('d');
    h.undo();
    expect(doc.value, entry('😀'));
    h.undo(); // b was evicted when the new group appended d.
    expect(doc.value, entry('😀'));
    h.redo();
    expect(doc.value, entry('d'));
  });

  test(
      'Erasing a grouped edit releases its charge and restores the prior selection',
      () {
    final doc = TextEditingController.fromValue(entry('a'));
    final h = track(doc, 3 * 66);
    h.replace(entry('b'));
    doc.value = entry('c');
    doc.value = entry('b', offset: 0);
    h.replace(entry('d'));
    h.undo();
    expect(doc.value, entry('b', offset: 0));
    h.undo();
    expect(doc.value, entry('a'));
  });

  test('Oversized replace-all keeps the complete source and result as one step',
      () {
    final original = entry('甲乙' * 1024, offset: 500);
    final doc = TextEditingController.fromValue(original);
    final h = track(doc, 256);
    final find = DocumentFind()..update(doc.text, '乙', true);
    final next = entry(find.replace('😀乙', all: true));
    h.replace(next);
    h.undo();
    expect(doc.value, original);
    h.redo();
    expect(doc.value, next);
    h.replace(entry('x'));
    h.replace(entry('y'));
    h.undo();
    h.undo();
    expect(doc.value, entry('x'));
  });

  test(
      'Composition is kept live and an oversized committed edit remains undoable',
      () {
    final doc = TextEditingController.fromValue(entry('旧'));
    final h = track(doc, 1);
    final composing =
        entry('候选').copyWith(composing: const TextRange(start: 0, end: 2));
    doc.value = composing;
    expect(doc.value, composing);
    h.undo();
    expect(doc.value, entry('旧'));
    doc.value = composing;
    doc.value = entry('候选');
    h.undo();
    expect(doc.value, entry('旧'));
    h.redo();
    expect(doc.value, entry('候选'));
  });
}
