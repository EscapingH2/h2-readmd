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
