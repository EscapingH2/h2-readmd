import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:window_manager/window_manager.dart';
import 'package:markdown_reader/main.dart';
import 'package:markdown_reader/find_preview.dart';
import 'package:markdown_reader/document_find.dart';
import 'package:markdown_reader/document_history.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const windowChannel = MethodChannel('window_manager');
  final nativeTitles = <String>[];

  setUp(() {
    nativeTitles.clear();
    // Widget tests have no native window. Only startup/title calls are mocked.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, (call) async {
      switch (call.method) {
        case 'isMinimized':
          return false;
        case 'setTitle':
          nativeTitles.add((call.arguments as Map)['title'] as String);
          return null;
        case 'show':
        case 'focus':
          return null;
        default:
          throw StateError('Unexpected window method: ${call.method}');
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, null);
  });

  Future<void> startApp(WidgetTester tester, MarkdownApp app) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
  }

  Finder previewText(String text) => find.descendant(
        of: find.byType(SliverGptMarkdown),
        matching: find.textContaining(text, findRichText: true),
      );

  testWidgets('Windows caret updates work with input tracing on or off', (tester) async {
    const channel = MethodChannel('h2readmd/desktop_input');
    final calls = <MethodCall>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await startApp(tester, const MarkdownApp(initialText: '甲乙'));
    final editor = tester.widget<TextField>(find.byType(TextField));
    editor.focusNode!.requestFocus();
    await tester.pumpAndSettle();
    calls.clear();
    editor.controller!.value = const TextEditingValue(
      text: '甲乙拼',
      selection: TextSelection.collapsed(offset: 3),
      composing: TextRange(start: 2, end: 3),
    );
    await tester.pump();
    await tester.pump();

    final state = tester.state<EditableTextState>(find.byType(EditableText));
    final render = state.renderEditable;
    final rect = render.getLocalRectForCaret(const TextPosition(offset: 3));
    final point = render.localToGlobal(rect.bottomLeft) * View.of(state.context).devicePixelRatio;
    expect(calls.lastWhere((c) => c.method == 'caret').arguments, [point.dx, point.dy]);
    final traces = calls.where((c) => c.method == 'trace').map((c) => c.arguments as String);
    if (Platform.environment['H2READMD_INPUT_TRACE'] == '1') {
      expect(traces, contains(startsWith('Dart geometry requested')));
      expect(traces, contains(startsWith('Dart caret x=')));
    } else {
      expect(traces, isEmpty);
    }
  }, skip: !Platform.isWindows);

  test('Literal multiline replacements preserve CRLF, Unicode and replacement characters', () {
    final find = DocumentFind();
    const source = '甲.*\r\n😄甲.*\r\n尾';
    find.update(source, '.*\r\n', false);
    expect(find.hits.length, 2);
    find.move(-1);
    expect(find.replace('', all: false), '甲.*\r\n😄甲尾');
    expect(find.replace(r'$1', all: true), r'甲$1😄甲$1尾');
    find.update(source, '', false);
    expect(find.current, isNull);
  });

  testWidgets('Find uses source matches, retains query across modes and undoes replace all', (tester) async {
    const original = '[Word](Word) word 中文';
    await startApp(tester, const MarkdownApp(initialText: original));
    final editor = tester.widget<TextField>(find.byType(TextField));
    editor.focusNode!.requestFocus();
    editor.controller!.selection = const TextSelection(baseOffset: 1, extentOffset: 5);
    Future<void> shortcut(LogicalKeyboardKey key, {bool shift = false}) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(key);
      if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
    }
    await tester.pump(const Duration(seconds: 1));
    await shortcut(LogicalKeyboardKey.keyF);
    PreviewFindPainter previewHighlights() => tester.widgetList<CustomPaint>(
        find.byType(CustomPaint)).map((p) => p.foregroundPainter)
        .whereType<PreviewFindPainter>().single;
    final label = previewHighlights().currentGlyphBox();
    expect(label, isNotNull);
    expect(find.text('1/3'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.text('2/3'), findsOneWidget);
    expect(previewHighlights().currentGlyphBox(), isNull); // Hidden URL.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(previewHighlights().currentGlyphBox()!.left, greaterThan(label!.left));
    await tester.tap(find.byTooltip('上一个'));
    await tester.pump();
    await tester.tap(find.text('Aa'));
    await tester.pump();
    expect(find.text('2/2'), findsOneWidget);
    await shortcut(LogicalKeyboardKey.keyH);
    for (final width in [1200.0, 300.0]) {
      await tester.binding.setSurfaceSize(Size(width, 800));
      await tester.pumpAndSettle();
      final query = tester.getRect(find.widgetWithText(TextField, '查找内容'));
      final replacement = tester.getRect(find.widgetWithText(TextField, '替换为'));
      expect(query.left, replacement.left);
      expect(query.right, replacement.right);
      expect(tester.getCenter(find.text('2/2')).dx, lessThan(tester.getCenter(find.text('Aa')).dx));
      expect(tester.takeException(), isNull);
    }
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    await tester.pumpAndSettle();
    expect(find.text('2/2'), findsOneWidget);
    expect(editor.controller!.text, original);
    await tester.enterText(find.widgetWithText(TextField, '替换为'), '新');
    await tester.tap(find.text('全部替换'));
    await tester.pumpAndSettle();
    expect(editor.controller!.text, '[新](新) word 中文');
    expect(find.text('0/0'), findsOneWidget);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, '替换')).onPressed, isNull);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, '全部替换')).onPressed, isNull);
    expect(tester.widget<IconButton>(find.byWidgetPredicate((w) => w is IconButton && w.tooltip == '上一个')).onPressed, isNull);
    await tester.pump(const Duration(seconds: 1));
    await shortcut(LogicalKeyboardKey.keyZ);
    expect(editor.controller!.text, original);
    await shortcut(LogicalKeyboardKey.keyY);
    expect(editor.controller!.text, '[新](新) word 中文');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: !Platform.isWindows);

  for (final marker in ['~~~', '```']) {
    testWidgets('Open $marker fence keeps literal math and link payload glyphs', (tester) async {
      const body = r'Code $hit$ [hit](hit)';
      await startApp(tester, MarkdownApp(initialText: '$marker\r\n$body'));
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查找  Ctrl+F'));
      await tester.pumpAndSettle();
      final query = find.widgetWithText(TextField, '查找内容');
      final paragraph = tester.renderObject<RenderParagraph>(find.descendant(
        of: find.byType(SliverGptMarkdown),
        matching: find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText() == body),
      ));
      Future<void> checkBox(String needle, int index, int total) async {
        expect(find.text('$index/$total'), findsOneWidget);
        final painter = tester.widgetList<CustomPaint>(find.byType(CustomPaint))
            .map((w) => w.foregroundPainter).whereType<PreviewFindPainter>().single;
        final at = needle.allMatches(body).elementAt(index - 1).start;
        final expected = paragraph.getBoxesForSelection(
            TextSelection(baseOffset: at, extentOffset: at + needle.length)).first.toRect();
        final viewport = painter.viewportKey.currentContext!.findRenderObject()!;
        final rect = MatrixUtils.transformRect(paragraph.getTransformTo(viewport), expected);
        expect(painter.currentGlyphBox(), rect);
      }
      await tester.enterText(query, 'hit');
      await tester.pumpAndSettle();
      for (var i = 1; i <= 3; i++) {
        await checkBox('hit', i, 3);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
      }
      await tester.enterText(query, 'Code');
      await tester.pumpAndSettle();
      await checkBox('Code', 1, 1); // The renderer also inserts a "Code" header.
      await tester.pumpWidget(const SizedBox.shrink());
    }, skip: !Platform.isWindows);
  }

  testWidgets('Ambiguous rendered text reveals its source row without a false highlight', (tester) async {
    final source = [for (var i = 0; i < 100; i++) '段落 $i', '尾段 &amp; amp'].join('\n\n');
    await startApp(tester, MarkdownApp(initialText: source));
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查找  Ctrl+F'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '查找内容'), 'amp');
    await tester.pumpAndSettle();
    final painter = tester.widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((w) => w.foregroundPainter).whereType<PreviewFindPainter>().single;
    expect(find.text('1/2'), findsOneWidget);
    expect(painter.scroll.offset, greaterThan(0));
    expect(previewText('尾段 & amp').hitTestable(), findsWidgets);
    expect(painter.currentGlyphBox(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: !Platform.isWindows);

  test('Escaped closing bracket does not expose a repeated link destination', () {
    const text = r'[same\]](same) same';
    final map = PreviewFindMap(text);
    final find = DocumentFind()..update(text, 'same', true);
    expect(find.hits.map((h) => h.start), [1, 9, 15]);
    expect(map.blocks.single.visibleSource.substring(9, 13), '\x00' * 4);
    expect(map.rowFor(9), 0);
  });

  test('Typing, replacement, and later typing have distinct history boundaries', () {
    final doc = TextEditingController(text: '甲');
    final history = DocumentHistory(doc);
    addTearDown(() { history.dispose(); doc.dispose(); });
    doc.text = '甲乙';
    doc.selection = const TextSelection.collapsed(offset: 1);
    history.replace(const TextEditingValue(text: '甲丙', selection: TextSelection.collapsed(offset: 2)));
    doc.text = '甲丙丁';
    history.undo();
    expect(doc.text, '甲丙');
    history.undo();
    expect(doc.text, '甲乙');
    expect(doc.selection.extentOffset, 1);
    history.undo();
    expect(doc.text, '甲');
    history.redo();
    expect(doc.text, '甲乙');
    doc.selection = const TextSelection.collapsed(offset: 0);
    history.redo();
    expect(doc.text, '甲丙');
    doc.text = '新分支';
    history.redo();
    expect(doc.text, '新分支');
  });

  for (final mode in ['分栏', '预览', '编辑']) {
    testWidgets('Rapid replacements have separate undo and redo steps ($mode)', (tester) async {
      await startApp(tester, const MarkdownApp(initialText: 'old old old'));
      final doc = tester.widget<TextField>(find.byType(TextField)).controller!;
      if (mode != '分栏') {
        await tester.tap(find.text(mode));
        await tester.pump();
      }
      Future<void> ctrl(LogicalKeyboardKey key) async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(key);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
      }
      await ctrl(LogicalKeyboardKey.keyH);
      await tester.enterText(find.widgetWithText(TextField, '查找内容'), 'old');
      await tester.enterText(find.widgetWithText(TextField, '替换为'), 'new');
      await tester.tap(find.text('替换'));
      await tester.pump();
      expect(doc.text, 'new old old');
      await tester.tap(find.text('全部替换'));
      await tester.pump();
      expect(doc.text, 'new new new');
      await ctrl(LogicalKeyboardKey.keyZ);
      expect(doc.text, 'new old old');
      await ctrl(LogicalKeyboardKey.keyZ);
      expect(doc.text, 'old old old');
      await ctrl(LogicalKeyboardKey.keyY);
      expect(doc.text, 'new old old');
      await ctrl(LogicalKeyboardKey.keyY);
      expect(doc.text, 'new new new');
      await tester.pumpWidget(const SizedBox.shrink());
    }, skip: !Platform.isWindows);
  }

  for (final brightness in Brightness.values) {
    testWidgets('Theme menu toggles the displayed $brightness system theme', (tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = brightness;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await startApp(tester, const MarkdownApp());

      Brightness displayed() => Theme.of(tester.element(find.byType(Scaffold))).brightness;
      Future<void> toggle() async {
        await tester.tap(find.byTooltip('更多'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('切换浅色／深色'));
        await tester.pumpAndSettle();
      }

      expect(displayed(), brightness);
      await toggle();
      expect(displayed(), brightness == Brightness.dark ? Brightness.light : Brightness.dark);
      await toggle();
      expect(displayed(), brightness);
      await tester.pumpWidget(const SizedBox.shrink());
    }, skip: !Platform.isWindows);

    testWidgets('Find paints readable preview text and both chevrons in $brightness', (tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = brightness;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final capture = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(key: capture, child: const MarkdownApp(initialText: 'A A')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查找  Ctrl+F'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, '查找内容'), 'A A');
      await tester.pumpAndSettle();

      final preview = find.byWidgetPredicate((w) => w is CustomPaint && w.foregroundPainter is PreviewFindPainter);
      final painter = tester.widget<CustomPaint>(preview).foregroundPainter! as PreviewFindPainter;
      final glyph = painter.currentGlyphBox()!.shift(tester.getTopLeft(preview));
      final surface = painter.colors.surface;
      final ink = painter.colors.onSurface;
      final highlight = Color.alphaBlend(findHighlight(true, brightness), surface);
      final boundary = capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      // Inspect the composited pixels, including the viewport's repaint layers.
      final image = boundary.toImageSync();
      final pixels = (await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
      bool hasColor(Rect box, Color color) {
        final rgb = color.toARGB32();
        for (var y = box.top.ceil(); y < box.bottom.floor(); y++) {
          for (var x = box.left.ceil(); x < box.right.floor(); x++) {
            final offset = (y * image.width + x) * 4;
            if ([0, 1, 2].every((c) =>
                (pixels.getUint8(offset + c) - ((rgb >> (16 - c * 8)) & 255)).abs() <= 2)) {
              return true;
            }
          }
        }
        return false;
      }
      try {
        expect(hasColor(glyph, ink), isTrue, reason: 'Preview glyph retains its text color');
        expect(hasColor(glyph.inflate(1), highlight), isTrue, reason: 'Preview uses editor highlight color');
        for (final tip in ['上一个', '下一个']) {
          expect(hasColor(tester.getRect(find.byTooltip(tip)).deflate(7), ink), isTrue, reason: tip);
        }
      } finally {
        image.dispose();
      }
      await tester.pumpWidget(const SizedBox.shrink());
    }, skip: !Platform.isWindows);
  }

  testWidgets('Search reaches distant lazy blocks, wraps, and survives view switches', (tester) async {
    final source = ['# 海岸', for (var i = 0; i < 220; i++) '第 $i 段正文', '**海岸**'].join('\n\n');
    await startApp(tester, MarkdownApp(initialText: source));
    final document = tester.widget<TextField>(find.byType(TextField)).controller!;
    final preview = tester.widget<CustomScrollView>(find.byType(CustomScrollView)).controller!;
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查找  Ctrl+F'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '查找内容'), '海岸');
    await tester.pumpAndSettle();
    expect(find.text('1/2'), findsOneWidget);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(find.text('2/2'), findsOneWidget);
    expect(preview.offset, greaterThan(1000));
    expect(previewText('海岸').hitTestable(), findsWidgets);
    await tester.tap(find.text('预览'));
    await tester.pumpAndSettle();
    expect(find.text('2/2'), findsOneWidget);
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('下一个'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('分栏'));
    await tester.pumpAndSettle();
    expect(find.text('1/2'), findsOneWidget);
    expect(preview.offset, 0);
    expect(document.text, source);
    await tester.tap(find.byTooltip('关闭查找'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: !Platform.isWindows);

  testWidgets('New document previews edits and clears dirty state on restore',
      (tester) async {
    await startApp(tester, const MarkdownApp());
    expect(find.text('Untitled.md'), Platform.isWindows ? findsNothing : findsOneWidget);
    expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text, '');

    await tester.enterText(find.byType(TextField), '中文预览测试');
    await tester.pumpAndSettle();
    expect(find.text('*Untitled.md'), Platform.isWindows ? findsNothing : findsOneWidget);
    expect(previewText('中文预览测试'), findsWidgets);
    if (Platform.isWindows) {
      expect(nativeTitles.last, '*Untitled.md - H2 Readmd');
    }

    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    expect(find.text('Untitled.md'), Platform.isWindows ? findsNothing : findsOneWidget);
    expect(find.text('*Untitled.md'), findsNothing);
    expect(previewText('中文预览测试'), findsNothing);
    if (Platform.isWindows) {
      expect(nativeTitles.last, 'H2 Readmd');
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Windows toolbar keeps file actions visible at every width',
      (tester) async {
    await startApp(tester, const MarkdownApp());
    for (final width in [180.0, 240.0, 300.0, 400.0, 800.0, 1920.0]) {
      await tester.binding.setSurfaceSize(Size(width, 800));
      await tester.pumpAndSettle();
      Rect? previous;
      for (final tip in ['新建', '打开', '保存', '更多']) {
        final finder = find.byTooltip(tip);
        expect(finder, findsOneWidget);
        final rect = tester.getRect(finder);
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(width));
        if (previous != null) expect(rect.left, greaterThanOrEqualTo(previous.right));
        previous = rect;
      }
      expect(find.text('Untitled.md'), findsNothing);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: !Platform.isWindows);

  for (final outcome in ['cancel', 'conflict', 'recovery', 'edit during save', 'overwrite']) {
    testWidgets('Save As preserves editor state: $outcome', (tester) async {
      const original = r'C:\docs\old.md';
      const selected = r'C:\docs\new.md';
      const channel = MethodChannel('h2readmd/storage');
      final reply = Completer<Object?>();
      final calls = <MethodCall>[];
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return reply.future;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await startApp(tester, const MarkdownApp(initialPath: original, initialVersion: 'old'));
      await tester.enterText(find.byType(TextField), 'first');
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('另存为'));
      await tester.pumpAndSettle();
      expect(calls.single.method, 'saveAs');
      expect((calls.single.arguments as Map)['version'], 'old');
      if (outcome == 'edit during save') await tester.enterText(find.byType(TextField), 'second');
      switch (outcome) {
        case 'cancel': reply.complete(null);
        case 'conflict': reply.completeError(PlatformException(code: 'save_failed', message: '磁盘文件已被修改'));
        case 'recovery': reply.completeError(PlatformException(code: 'recovery', message: '请检查 previous.md'));
        default: reply.complete({'path': selected, 'version': 'next'});
      }
      await tester.pumpAndSettle();
      if (outcome == 'recovery') {
        expect(find.text('请核对磁盘文件'), findsOneWidget);
        await tester.tap(find.text('知道了'));
        await tester.pumpAndSettle();
      }
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          outcome == 'edit during save' ? 'second' : 'first');
      expect(nativeTitles.last, switch (outcome) {
        'edit during save' => '*new.md - H2 Readmd',
        'overwrite' => 'new.md - H2 Readmd',
        _ => '*old.md - H2 Readmd',
      });
      await tester.pumpWidget(const SizedBox.shrink());
    }, skip: !Platform.isWindows);
  }

  for (final outcome in ['saved', 'failure', 'edited']) {
    testWidgets('Close rechecks snapshot after save: $outcome', (tester) async {
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final reply = Completer<Object?>();
      const storage = MethodChannel('h2readmd/storage');
      final saves = <String>[];
      messenger.setMockMethodCallHandler(storage, (call) async {
        saves.add(call.method);
        return reply.future;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(storage, null));
      const path = r'C:\docs\close.md';
      await startApp(tester, const MarkdownApp(initialPath: path, initialVersion: 'opened'));
      final controller = tester.widget<TextField>(find.byType(TextField)).controller!;
      controller.text = 'draft';
      await tester.pumpAndSettle();
      final methods = <String>[];
      messenger.setMockMethodCallHandler(windowChannel, (call) async {
        methods.add(call.method);
        return null;
      });
      (tester.state(find.byType(EditorPage)) as WindowListener).onWindowClose();
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();
      expect(saves, ['save']);
      if (outcome == 'edited') controller.text = 'newer draft';
      if (outcome == 'failure') {
        reply.completeError(PlatformException(code: 'save_failed', message: '只读文件'));
      } else {
        reply.complete({'path': path, 'version': 'saved'});
      }
      await tester.pumpAndSettle();
      expect(methods.contains('close'), outcome == 'saved');
      expect(methods.contains('setPreventClose'), outcome == 'saved');
      expect(controller.text, outcome == 'edited' ? 'newer draft' : 'draft');
      await tester.pumpWidget(const SizedBox.shrink());
    }, skip: !Platform.isWindows);
  }

  testWidgets('A clean buffer becomes unsaved when its disk baseline is lost', (tester) async {
    const channel = MethodChannel('h2readmd/storage');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'document_conflict', message: '原路径不存在');
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await startApp(tester, const MarkdownApp(initialPath: r'C:\docs\lost.md', initialVersion: 'old'));
    await tester.tap(find.byTooltip('保存'));
    await tester.pumpAndSettle();
    expect(nativeTitles.last, '*lost.md - H2 Readmd');
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: !Platform.isWindows);

  for (final newDocument in [false, true]) {
    testWidgets('Ctrl+S saves ${newDocument ? "new" : "opened"} document with editor focus',
        (tester) async {
      const path = r'C:\Documents\中文 文档.md';
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('h2readmd/storage'), (call) async {
        calls.add(call);
        return {'path': path, 'version': 'saved-${calls.length}'};
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('h2readmd/storage'), null));
      await startApp(tester, MarkdownApp(initialPath: newDocument ? null : path, initialVersion: newDocument ? null : 'opened'));
      for (final text in ['首次保存', '再次保存']) {
        await tester.enterText(find.byType(TextField), text);
        await tester.pumpAndSettle();
        expect(tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus, isTrue);
        expect(nativeTitles.last, startsWith('*'));
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(calls.length, text == '首次保存' ? 1 : 2);
        final call = calls.last;
        expect(call.method, newDocument && calls.length == 1 ? 'saveAs' : 'save');
        final arguments = call.arguments as Map;
        expect(utf8.decode(arguments['bytes'] as List<int>), text);
        expect(arguments['path'], newDocument && calls.length == 1 ? '' : path);
        expect(arguments['version'], calls.length == 2 ? 'saved-1' : newDocument ? '' : 'opened');
        expect(nativeTitles.last, '中文 文档.md - H2 Readmd');
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    }, skip: !Platform.isWindows);
  }

  testWidgets('Selection updates keep the preview and report IME caret geometry', (tester) async {
    const input = MethodChannel('h2readmd/desktop_input');
    final calls = <MethodCall>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(input, (call) async { calls.add(call); return null; });
    addTearDown(() => messenger.setMockMethodCallHandler(input, null));
    await startApp(tester, const MarkdownApp(initialText: '中文输入'));
    final field = find.byType(TextField);
    await tester.showKeyboard(field);
    await tester.pumpAndSettle();
    final sliver = find.byType(SliverGptMarkdown);
    final before = tester.widget(sliver);
    final controller = tester.widget<TextField>(field).controller!;
    calls.clear();
    tester.testTextInput.updateEditingValue(const TextEditingValue(
      text: '中文输入', selection: TextSelection(baseOffset: 1, extentOffset: 3)));
    await tester.pump();
    expect(controller.selection, const TextSelection(baseOffset: 1, extentOffset: 3));
    expect(tester.widget(sliver), same(before));
    void expectCaret(int offset) {
      final render = tester.state<EditableTextState>(find.byType(EditableText)).renderEditable;
      final local = render.getLocalRectForCaret(TextPosition(offset: offset)).bottomLeft;
      final expected = render.localToGlobal(local) * tester.view.devicePixelRatio;
      expect(calls.lastWhere((call) => call.method == 'caret').arguments, [expected.dx, expected.dy]);
    }
    expectCaret(3);
    const composing = TextEditingValue(text: '中文拼音',
        selection: TextSelection.collapsed(offset: 4), composing: TextRange(start: 2, end: 4));
    tester.testTextInput.updateEditingValue(composing);
    await tester.pump();
    expect(controller.value, composing);
    expectCaret(4);
    calls.clear();
    final moved = composing.copyWith(selection: const TextSelection.collapsed(offset: 2));
    tester.testTextInput.updateEditingValue(moved);
    await tester.pump();
    expect(controller.value, moved);
    expectCaret(2);
    tester.testTextInput.updateEditingValue(moved.copyWith(composing: TextRange.empty));
    await tester.pump();
    expect(controller.value.composing, TextRange.empty);
    expect(tester.widget<SliverGptMarkdown>(sliver).data, composing.text);
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: !Platform.isWindows);

  testWidgets('Hidden preview retains its text and viewport until shown', (tester) async {
    final text = List.generate(120, (i) => '第 $i 段').join('\n\n');
    await startApp(tester, MarkdownApp(initialText: text));
    final sliver = find.byType(SliverGptMarkdown, skipOffstage: false);
    final preview = tester.widget<CustomScrollView>(find.byType(CustomScrollView)).controller!;
    final position = preview.position;
    preview.jumpTo(400);
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    final hidden = tester.widget(sliver);
    final controller = tester.widget<TextField>(find.byType(TextField)).controller!;
    for (final tail in ['中', '中文', '中']) {
      controller.text = text + tail;
      await tester.pump();
      expect(tester.widget(sliver), same(hidden));
      expect(tester.widget<SliverGptMarkdown>(sliver).data, text);
    }
    await tester.tap(find.text('预览'));
    await tester.pump();
    expect(tester.widget<SliverGptMarkdown>(sliver).data, controller.text);
    await tester.pumpAndSettle();
    expect(preview.position, same(position));
    expect(preview.offset, closeTo(400, 1));
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: !Platform.isWindows);

  testWidgets('Hidden preview search tracks source edits and reveals the latest hit', (tester) async {
    await startApp(tester, const MarkdownApp(initialText: '目标'));
    final doc = tester.widget<TextField>(find.byType(TextField)).controller!;
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查找  Ctrl+F'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '查找内容'), '目标');
    await tester.pumpAndSettle();
    doc.text = ['目标', for (var i = 0; i < 110; i++) '段落 $i', '**末尾目标**'].join('\n\n');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('下一个'));
    await tester.pumpAndSettle();
    expect(find.text('2/2'), findsOneWidget);
    Iterable<PreviewFindPainter> painters() => tester.widgetList<CustomPaint>(
        find.byType(CustomPaint, skipOffstage: false)).map((w) => w.foregroundPainter)
        .whereType<PreviewFindPainter>();
    expect(painters(), isEmpty);
    await tester.tap(find.text('分栏'));
    await tester.pumpAndSettle();
    expect(find.text('2/2'), findsOneWidget);
    final painter = painters().single;
    expect(painter.currentGlyphBox(), isNotNull);
    expect(painter.scroll.offset, greaterThan(1000));
    expect(previewText('末尾目标').hitTestable(), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: !Platform.isWindows);

  testWidgets('View switches retain both viewport states and independent offsets',
      (tester) async {
    await startApp(tester, MarkdownApp(
      initialText: List.generate(200, (i) => 'Line $i').join('\n\n')));
    final editorFinder = find.byType(SingleChildScrollView, skipOffstage: false);
    final previewFinder = find.byType(CustomScrollView, skipOffstage: false);
    final editorController = tester.widget<SingleChildScrollView>(editorFinder).controller!;
    final previewController = tester.widget<CustomScrollView>(previewFinder).controller!;
    final editorPosition = editorController.position;
    final previewPosition = previewController.position;
    final editableState = tester.state<EditableTextState>(
      find.byType(EditableText, skipOffstage: false));
    editorController.jumpTo(350);
    previewController.jumpTo(600);
    await tester.pumpAndSettle();
    for (final mode in ['编辑', '分栏', '预览', '分栏', '编辑', '分栏', '预览', '编辑']) {
      await tester.tap(find.text(mode));
      await tester.pumpAndSettle();
      expect(editorController.position, same(editorPosition));
      expect(previewController.position, same(previewPosition));
      expect(tester.state<EditableTextState>(
        find.byType(EditableText, skipOffstage: false)), same(editableState));
      expect(editorController.offset, closeTo(350, 1));
      expect(previewController.offset, closeTo(600, 1));
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: !Platform.isWindows);

  testWidgets('Windows editor exposes first and last lines after resize',
      (tester) async {
    final source = List.generate(160, (i) => '第 $i 行：长文档换行测试 ' * 5).join('\n');
    await startApp(tester, MarkdownApp(initialText: source));
    for (final mode in ['分栏', '编辑']) {
      await tester.tap(find.text(mode));
      await tester.pumpAndSettle();
      for (final size in [const Size(1200, 800), const Size(900, 500)]) {
        await tester.binding.setSurfaceSize(size);
        await tester.pumpAndSettle();
        final viewportFinder = find.byWidgetPredicate((widget) =>
            widget is SingleChildScrollView && widget.controller != null);
        expect(viewportFinder, findsOneWidget);
        final viewport = tester.widget<SingleChildScrollView>(viewportFinder);
        final controller = viewport.controller!;
        expect(controller.positions.length, 1);
        expect(controller.position.maxScrollExtent, greaterThan(0));
        final editable = tester.state<EditableTextState>(find.byType(EditableText)).renderEditable;
        final bounds = tester.getRect(viewportFinder);
        final scrollbarFinder = find.ancestor(
            of: viewportFinder, matching: find.byType(Scrollbar));
        expect(tester.getRect(scrollbarFinder), bounds);

        controller.jumpTo(controller.position.maxScrollExtent);
        await tester.pump();
        final last = editable.getLocalRectForCaret(TextPosition(offset: source.length));
        final lastBottom = editable.localToGlobal(last.bottomRight).dy;
        expect(lastBottom, lessThanOrEqualTo(bounds.bottom - 18));
        expect(lastBottom, greaterThan(bounds.top));

        controller.jumpTo(0);
        await tester.pump();
        final first = editable.getLocalRectForCaret(const TextPosition(offset: 0));
        expect(editable.localToGlobal(first.topLeft).dy,
            greaterThanOrEqualTo(bounds.top - 1));
        expect(tester.takeException(), isNull);
      }
    }
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: !Platform.isWindows);

  testWidgets('Initial document starts saved and renders Markdown',
      (tester) async {
    const source = '**初始文档**';
    await startApp(
        tester,
        MarkdownApp(
          initialPath: File('protocol.md').absolute.path,
          initialText: source,
        ));
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        source);
    expect(find.text('protocol.md'), Platform.isWindows ? findsNothing : findsOneWidget);
    if (Platform.isWindows) {
      expect(nativeTitles.last, 'protocol.md - H2 Readmd');
    }
    expect(previewText('初始文档'), findsWidgets);
    expect(previewText('**初始文档**'), findsNothing);

    await tester.enterText(find.byType(TextField), '$source\n修改');
    await tester.pumpAndSettle();
    expect(find.text('*protocol.md'), Platform.isWindows ? findsNothing : findsOneWidget);
    if (Platform.isWindows) {
      expect(nativeTitles.last, '*protocol.md - H2 Readmd');
    }

    await tester.enterText(find.byType(TextField), source);
    await tester.pumpAndSettle();
    expect(find.text('protocol.md'), Platform.isWindows ? findsNothing : findsOneWidget);
    expect(find.text('*protocol.md'), findsNothing);
    if (Platform.isWindows) {
      expect(nativeTitles.last, 'protocol.md - H2 Readmd');
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
