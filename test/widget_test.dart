import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:markdown_reader/main.dart';

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

  testWidgets('New document previews edits and clears dirty state on restore',
      (tester) async {
    await startApp(tester, const MarkdownApp());
    expect(find.text('Untitled.md'), findsOneWidget);
    expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text, '');

    await tester.enterText(find.byType(TextField), '中文预览测试');
    await tester.pumpAndSettle();
    expect(find.text('*Untitled.md'), findsOneWidget);
    expect(previewText('中文预览测试'), findsWidgets);
    if (Platform.isWindows) {
      expect(nativeTitles.last, '*Untitled.md - H2 Readmd');
    }

    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    expect(find.text('Untitled.md'), findsOneWidget);
    expect(find.text('*Untitled.md'), findsNothing);
    expect(previewText('中文预览测试'), findsNothing);
    if (Platform.isWindows) {
      expect(nativeTitles.last, 'H2 Readmd');
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

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
    expect(find.text('protocol.md'), findsOneWidget);
    if (Platform.isWindows) {
      expect(nativeTitles.last, 'protocol.md - H2 Readmd');
    }
    expect(previewText('初始文档'), findsWidgets);
    expect(previewText('**初始文档**'), findsNothing);

    await tester.enterText(find.byType(TextField), '$source\n修改');
    await tester.pumpAndSettle();
    expect(find.text('*protocol.md'), findsOneWidget);
    if (Platform.isWindows) {
      expect(nativeTitles.last, '*protocol.md - H2 Readmd');
    }

    await tester.enterText(find.byType(TextField), source);
    await tester.pumpAndSettle();
    expect(find.text('protocol.md'), findsOneWidget);
    expect(find.text('*protocol.md'), findsNothing);
    if (Platform.isWindows) {
      expect(nativeTitles.last, 'protocol.md - H2 Readmd');
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
