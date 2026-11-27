import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:filegate/filegate.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';
import 'package:material_ui/material_ui.dart' as markdown_ui;

import 'startup_arguments.dart';
import 'document_find.dart';
import 'document_history.dart';
import 'find_preview.dart';

// Use installed Windows fonts; do not redistribute Segoe UI font files.
const _readingFont = 'H2Readmd Segoe UI';
const _chineseReadingFont = 'H2Readmd Source Han Sans';
const _readingFallback = ['Segoe UI', _chineseReadingFont, 'Source Han Sans SC', 'Microsoft YaHei', 'Segoe UI Symbol'];

Future<void> _loadWindowsReadingFont() async {
  final windows = Platform.environment['WINDIR'] ?? r'C:\Windows';
  try {
    // Excluding Segoe UI Bold makes Markdown's w700 select Semibold (w600).
    // Chinese falls back independently to Source Han Sans SC at w400/w700.
    final fonts = await Future.wait(
      ['segoeui.ttf', 'segoeuii.ttf', 'seguisb.ttf', 'seguisbi.ttf'].map(
        (name) => File('$windows/Fonts/$name').readAsBytes(),
      ),
    );
    final loader = FontLoader(_readingFont);
    for (final bytes in fonts) {
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
    }
    await loader.load();
  } catch (error) {
    // Missing/inaccessible system fonts must not prevent opening documents.
    debugPrint('Reading font unavailable; using system fallback: $error');
  }
}


Future<void> _loadWindowsChineseFont() async {
  final windows = Platform.environment['WINDIR'] ?? r'C:\Windows';
  final localAppData = Platform.environment['LOCALAPPDATA'];
  try {
    final fonts = await Future.wait([
      'SourceHanSansSC-Regular.otf',
      'SourceHanSansSC-Bold.otf',
      '思源黑体 CN RegularItalic.ttf',
      '思源黑体 CN BoldItalic.ttf',
    ].map((name) async {
      final userFont = localAppData == null
          ? null : File('$localAppData/Microsoft/Windows/Fonts/$name');
      final file = userFont != null && await userFont.exists()
          ? userFont : File('$windows/Fonts/$name');
      return file.readAsBytes();
    }));
    // One family with real 400/700 upright and italic faces. FontLoader reads
    // weight/slant from the font metadata, including the user's italic faces.
    final loader = FontLoader(_chineseReadingFont);
    for (final bytes in fonts) {
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
    }
    await loader.load();
  } catch (error) {
    debugPrint('Chinese font unavailable; using system fallback: $error');
  }
}

ThemeData _neutralTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final surface = Color(dark ? 0xFF202020 : 0xFFFFFFFF);
  final text = Color(dark ? 0xFFECECEC : 0xFF242424);
  final secondary = Color(dark ? 0xFFB0B0B0 : 0xFF707070);
  final container = Color(dark ? 0xFF292929 : 0xFFF7F7F8);
  final border = Color(dark ? 0xFF414141 : 0xFFE5E5E5);
  final selected = Color(dark ? 0xFF3A3A3A : 0xFFE8E8E8);
  final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF777777), brightness: brightness).copyWith(
    primary: text, onPrimary: surface,
    secondary: text, onSecondary: surface,
    tertiary: text, onTertiary: surface,
    primaryContainer: selected, onPrimaryContainer: text,
    secondaryContainer: selected, onSecondaryContainer: text,
    tertiaryContainer: selected, onTertiaryContainer: text,
    surface: surface, onSurface: text, onSurfaceVariant: secondary,
    surfaceContainerLowest: surface, surfaceContainerLow: container,
    surfaceContainer: container, surfaceContainerHigh: container,
    surfaceContainerHighest: selected,
    outline: border, outlineVariant: border, surfaceTint: Colors.transparent,
  );
  return ThemeData(
    useMaterial3: true, colorScheme: scheme,
    fontFamily: _readingFont, fontFamilyFallback: _readingFallback, scaffoldBackgroundColor: surface,
    dividerColor: border,
    appBarTheme: AppBarTheme(
      backgroundColor: Color(dark ? 0xFF262626 : 0xFFF5F5F5),
      foregroundColor: text, elevation: 0, scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: text, selectionColor: text.withValues(alpha: 0.18),
      selectionHandleColor: text,
    ),
  );
}

const _windowsBodyStyle = TextStyle(
  fontFamily: _readingFont,
  fontFamilyFallback: _readingFallback,
  fontSize: 16,
  height: 1.6,
  fontWeight: FontWeight.w400,
  letterSpacing: 0,
);

const _storage = MethodChannel('h2readmd/storage');

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  String? initialPath;
  String initialText = '';
  String? initialVersion;
  String? startupError;
  if (Platform.isWindows) {
    await _loadWindowsReadingFont();
    await _loadWindowsChineseFont();
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
    if (arguments.isNotEmpty) {
      try {
        final path = parseStartupFilePath(arguments)!;
        final file = File(path).absolute;
        final opened = (await _storage.invokeMapMethod<String, dynamic>('read', {'path': file.path}))!;
        initialText = utf8.decode(opened['bytes'] as Uint8List);
        initialVersion = opened['version'] as String;
        initialPath = file.path;
      } catch (error) {
        startupError = '无法打开文档：$error';
      }
    }
  }
  runApp(MarkdownApp(
    initialPath: initialPath,
    initialText: initialText,
    initialVersion: initialVersion,
    startupError: startupError,
  ));
}

class MarkdownApp extends StatefulWidget {
  const MarkdownApp({super.key, this.initialPath, this.initialVersion, this.initialText = '', this.startupError});
  final String? initialVersion;
  final String? initialPath;
  final String initialText;
  final String? startupError;

  @override
  State<MarkdownApp> createState() => _MarkdownAppState();
}

class _MarkdownAppState extends State<MarkdownApp> {
  ThemeMode mode = ThemeMode.system;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'H2 Readmd',
        debugShowCheckedModeBanner: false,
        themeMode: mode,
        theme: Platform.isWindows ? _neutralTheme(Brightness.light) : ThemeData(
          useMaterial3: true,
          colorSchemeSeed: Colors.blueGrey,
          fontFamily: Platform.isWindows ? 'Microsoft YaHei' : null,
        ),
        darkTheme: Platform.isWindows ? _neutralTheme(Brightness.dark) : ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          colorSchemeSeed: Colors.blueGrey,
          fontFamily: Platform.isWindows ? 'Microsoft YaHei' : null,
        ),
        home: Builder(builder: (editorContext) => EditorPage(
          initialPath: widget.initialPath,
          initialVersion: widget.initialVersion,
          initialText: widget.initialText,
          startupError: widget.startupError,
          onThemeToggle: () => setState(() {
            mode = Theme.of(editorContext).brightness == Brightness.dark
                ? ThemeMode.light : ThemeMode.dark;
          }),
        )),
      );
}

enum ViewMode { both, editor, preview }

class EditorPage extends StatefulWidget {
  const EditorPage({super.key, required this.onThemeToggle, this.initialPath, this.initialVersion, this.initialText = '', this.startupError});
  final String? initialVersion;
  final VoidCallback onThemeToggle;
  final String? initialPath;
  final String initialText;
  final String? startupError;

  @override
  State<EditorPage> createState() => _EditorPageState();
}

// EditableText enables scrollbars in its own ScrollBehavior copy. Override
// the builder so it cannot add a second scrollbar inside the text padding.
class _EditorScrollBehavior extends MaterialScrollBehavior {
  const _EditorScrollBehavior();

  @override
  Widget buildScrollbar(BuildContext context, Widget child, ScrollableDetails details) => child;
}

class _EditorPageState extends State<EditorPage> with WindowListener {
  static const _files = Filegate();
  final _controller = FindEditingController();
  late TextEditingValue _lastDocumentValue;
  final _query = TextEditingController();
  final _replacement = TextEditingController();
  final _queryFocus = FocusNode();
  final _replacementFocus = FocusNode();
  final _previewFocus = FocusNode();
  final _queryKey = GlobalKey();
  final _replacementKey = GlobalKey();
  final _previewKey = GlobalKey();
  late final DocumentHistory _documentUndo;
  bool _panelOpen = false;
  bool _replaceMode = false;
  bool _returnToPreview = false;
  String _previewSelection = '';
  PreviewFindMap? _previewMap;
  int _revealGeneration = 0;
  DocumentFind get _find => _controller.find;
  bool get _fieldFocused => _editorFocus.hasFocus || _queryFocus.hasFocus || _replacementFocus.hasFocus;
  GlobalKey get _activeFieldKey => _queryFocus.hasFocus ? _queryKey :
      _replacementFocus.hasFocus ? _replacementKey : _editorKey;

  void _openFind(bool replace) {
    if (!_panelOpen) {
      _returnToPreview = _view == ViewMode.preview || _previewFocus.hasFocus;
      final selection = _controller.selection;
      final seed = _returnToPreview ? _previewSelection :
          selection.isValid ? selection.textInside(_controller.text) : '';
      if (seed.isNotEmpty) _query.text = seed;
    }
    setState(() {
      _panelOpen = true;
      _replaceMode = replace;
    });
    _refreshFind();
    _query.selection = TextSelection(baseOffset: 0, extentOffset: _query.text.length);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _panelOpen) _queryFocus.requestFocus();
    });
  }

  void _closeFind() {
    _revealGeneration++;
    setState(() {
      _panelOpen = false;
      _find.update(_controller.text, '', _find.matchCase);
      _previewMap = null;
    });
    if (_view == ViewMode.preview || (_returnToPreview && _view == ViewMode.both)) {
      _previewFocus.requestFocus();
    } else {
      _editorFocus.requestFocus();
    }
  }

  void _refreshFind({int? anchor, bool reveal = true}) {
    if (!_panelOpen) return;
    if (_find.source != _controller.text) _previewMap = null;
    setState(() => _find.update(_controller.text, _query.text, _find.matchCase, anchor: anchor));
    if (reveal) {
      _revealFind();
    } else {
      _revealGeneration++;
    }
  }

  PreviewFindPainter _previewPainter() => PreviewFindPainter(_previewKey,
      _previewScrollController, _find, _previewMap ??= PreviewFindMap(_controller.text),
      Theme.of(context).colorScheme);

  void _revealFind() {
    final generation = ++_revealGeneration;
    final hit = _find.current;
    if (hit == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _revealGeneration) return;
      final render = _editableState()?.renderEditable;
      if (render != null && _editorScrollController.hasClients) {
        final viewport = _editorScrollController.position.context.notificationContext?.findRenderObject();
        if (viewport is RenderBox) {
          final caret = render.getLocalRectForCaret(TextPosition(offset: hit.start));
          final y = render.localToGlobal(caret.topLeft).dy - viewport.localToGlobal(Offset.zero).dy;
          final pos = _editorScrollController.position;
          _editorScrollController.jumpTo((pos.pixels + y - pos.viewportDimension * .4)
              .clamp(pos.minScrollExtent, pos.maxScrollExtent).toDouble());
        }
      }
      final previewContext = _previewKey.currentContext;
      if (previewContext == null ||
          previewContext.findAncestorWidgetOfExactType<Offstage>()?.offstage == true) {
        return;
      }
      final painter = (previewContext.widget as CustomPaint).foregroundPainter;
      if (painter is! PreviewFindPainter) return;
      void preview(Duration _) {
        if (!mounted || generation != _revealGeneration || _view == ViewMode.editor) return;
        if (!painter.reveal()) {
          WidgetsBinding.instance.addPostFrameCallback(preview);
          WidgetsBinding.instance.ensureVisualUpdate();
        }
      }
      preview(Duration.zero);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _setView(ViewMode mode, {bool resetSplit = false}) {
    setState(() {
      _view = mode;
      if (resetSplit) _editorFraction = .5;
    });
    if (_panelOpen) _revealFind();
  }

  void _moveFind(int delta) {
    setState(() => _find.move(delta));
    _revealFind();
  }

  void _replaceFind(bool all) {
    final hit = _find.current;
    if (hit == null) return;
    final insert = _replacement.text;
    final next = _find.replace(insert, all: all);
    final end = (hit.start + insert.length).clamp(0, next.length);
    _documentUndo.replace(TextEditingValue(text: next, selection: TextSelection.collapsed(offset: end)));
    _refreshFind(anchor: all ? 0 : end);
    (_view == ViewMode.preview ? _previewFocus : _editorFocus).requestFocus();
  }

  final _editorKey = GlobalKey();
  final _editorFocus = FocusNode();
  bool _imeGeometryQueued = false;
  static const _desktopInput = MethodChannel('h2readmd/desktop_input');

  void _inputTrace(String message) {
    if (Platform.isWindows && Platform.environment['H2READMD_INPUT_TRACE'] == '1') {
      unawaited(_desktopInput.invokeMethod<void>('trace', message)
          .catchError((Object error) { debugPrint('Input trace unavailable: $error'); }));
    }
  }

  EditableTextState? _editableState([GlobalKey? fieldKey]) {
    EditableTextState? result;
    void visit(Element element) {
      if (element is StatefulElement && element.state is EditableTextState) {
        result = element.state as EditableTextState;
      } else {
        element.visitChildren(visit);
      }
    }
    (fieldKey ?? _editorKey).currentContext?.visitChildElements(visit);
    return result;
  }

  @override
  void onWindowFocus() => _trackImeGeometry();


  void _trackImeGeometry() {
    _inputTrace('Dart geometry requested focus=${_editorFocus.hasFocus} queued=$_imeGeometryQueued selection=${_controller.selection.baseOffset},${_controller.selection.extentOffset} composing=${_controller.value.composing.start},${_controller.value.composing.end}');
    if (Platform.isWindows && !_fieldFocused) {
      unawaited(_desktopInput.invokeMethod<void>('caretInactive')
          .catchError((Object error) { debugPrint('IME caret reset failed: $error'); }));
    }
    if (!Platform.isWindows || !_fieldFocused || _imeGeometryQueued) return;
    _imeGeometryQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      scheduleMicrotask(() {
        _imeGeometryQueued = false;
        if (!mounted || !_fieldFocused || _exitCommitted) return;
        final state = _editableState(_activeFieldKey);
        final selection = state?.widget.controller.selection;
        if (state == null || selection == null || !selection.isValid) return;
        final render = state.renderEditable;
        final rect = render.getLocalRectForCaret(
          TextPosition(offset: selection.extentOffset));
        final point = render.localToGlobal(rect.bottomLeft);
        final scale = View.of(state.context).devicePixelRatio;
        _inputTrace('Dart caret x=${point.dx} y=${point.dy} scale=$scale');
        unawaited(_desktopInput.invokeMethod<void>('caret',
            <double>[point.dx * scale, point.dy * scale])
            .catchError((Object error) { debugPrint('IME native caret failed: $error'); }));
        // Enqueue both messages in order without waiting for platform replies.
        // Selection/scroll/focus changes schedule fresh geometry, not a loop
        // dependent on a future frame happening after an asynchronous reply.
        for (final message in <String, Map<String, dynamic>>{
          'TextInput.setEditableSizeAndTransform': {
            'width': render.size.width, 'height': render.size.height,
            'transform': render.getTransformTo(null).storage.toList(),
          },
          'TextInput.setMarkedTextRect': {
            'x': rect.left, 'y': rect.top, 'width': rect.width, 'height': rect.height,
          },
        }.entries) {
          unawaited(SystemChannels.textInput.invokeMethod<void>(message.key, message.value)
              .catchError((Object error) { debugPrint('IME geometry update failed: $error'); }));
        }
      });
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  final _editorScrollController = ScrollController();
  final _previewScrollController = ScrollController();
  double? _editorLayoutWidth;
  double? _previewLayoutWidth;
  Widget? _lastDesktopPreview;
  String? _path;
  String? _diskVersion;
  bool _unconfirmedSave = false;
  String _name = 'Untitled.md';
  String _savedText = '';
  ViewMode _view = ViewMode.both;
  double _editorFraction = .5;
  bool _busy = false;
  bool _handlingExit = false;
  bool _exitCommitted = false;
  bool _launchingWindow = false;
  String? _lastNativeTitle;
  bool _syncingTitle = false;

  bool get _dirty => _unconfirmedSave || _controller.text != _savedText;
  String get _documentLabel => '${_dirty ? '*' : ''}$_name';

  @override
  void initState() {
    super.initState();
    _path = widget.initialPath;
    _diskVersion = widget.initialVersion;
    if (_path != null) _name = File(_path!).uri.pathSegments.last;
    _savedText = widget.initialText;
    _controller.text = widget.initialText;
    _lastDocumentValue = _controller.value;
    if (Platform.isWindows) _documentUndo = DocumentHistory(_controller);
    _controller.addListener(_changed);
    _editorFocus.addListener(_trackImeGeometry);
    _queryFocus.addListener(_trackImeGeometry);
    _replacementFocus.addListener(_trackImeGeometry);
    _query.addListener(_trackImeGeometry);
    _replacement.addListener(_trackImeGeometry);
    _editorScrollController.addListener(_trackImeGeometry);
    if (Platform.isWindows) {
      _desktopInput.setMethodCallHandler((call) async {
        _inputTrace('Dart native request=${call.method} focus=${_editorFocus.hasFocus} view=$_view');
        if (call.method == 'paste' && mounted && _fieldFocused && !_handlingExit && !_exitCommitted) {
          await _editableState(_activeFieldKey)?.pasteText(SelectionChangedCause.keyboard);
          _inputTrace('Dart paste completed');
        }
      });
    }
    if (Platform.isWindows) windowManager.addListener(this);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      if (widget.startupError != null) _error(widget.startupError!);
      if (Platform.isWindows) {
        try {
          await _syncWindowTitle();
          await windowManager.show();
          await windowManager.focus();
        } catch (error) {
          _error(error);
        }
      }
    });
  }

  void _changed() {
    final previous = _lastDocumentValue;
    final current = _controller.value;
    _lastDocumentValue = current;
    _trackImeGeometry();
    // EditableText listens to selection changes itself. Keep the normal
    // update path during composition and when the composing range changes.
    if (current.text == previous.text &&
        current.composing == previous.composing &&
        current.composing.isCollapsed) {
      return;
    }
    if (_panelOpen && current.text != _find.source) {
      _refreshFind(reveal: false);
    } else {
      setState(() {});
    }
    _syncWindowTitle();
  }

  Future<void> _syncWindowTitle() async {
    if (!Platform.isWindows || !mounted || _exitCommitted || _syncingTitle) return;
    _syncingTitle = true;
    try {
      // Serialize native updates and pick up changes made during an await.
      // Ordinary typing while already dirty does not send redundant calls.
      while (mounted && !_exitCommitted) {
        final title = _path == null && !_dirty
            ? 'H2 Readmd'
            : '$_documentLabel - H2 Readmd';
        if (title == _lastNativeTitle) break;
        await windowManager.setTitle(title);
        _lastNativeTitle = title;
      }
    } catch (error) {
      // A title failure must not turn a successful save into a failed save.
      debugPrint('Unable to update window title: $error');
    } finally {
      _syncingTitle = false;
    }
  }

  @override
  void dispose() {
    if (Platform.isWindows) windowManager.removeListener(this);
    _controller.removeListener(_changed);
    if (Platform.isWindows) _documentUndo.dispose();
    _controller.dispose();
    _query.dispose();
    _replacement.dispose();
    _queryFocus.dispose();
    _replacementFocus.dispose();
    _previewFocus.dispose();
    _editorFocus.removeListener(_trackImeGeometry);
    _editorFocus.dispose();
    _editorScrollController.removeListener(_trackImeGeometry);
    _editorScrollController.dispose();
    if (Platform.isWindows) _desktopInput.setMethodCallHandler(null);
    _previewScrollController.dispose();
    super.dispose();
  }

  @override
  void onWindowClose() {
    _traceClose('Dart onWindowClose');
    _closeWindowsWindow();
  }

  void _traceClose(String stage) {
    if (Platform.isWindows && Platform.environment['MDREADER_CLOSE_TRACE'] == '1') {
      // ignore: avoid_print
      print('[close pid=$pid ms=${DateTime.now().millisecondsSinceEpoch}] $stage');
    }
  }

  Future<void> _closeWindowsWindow() async {
    if (!Platform.isWindows || _handlingExit || _exitCommitted) return;
    _handlingExit = true;
    try {
      final canLeave = await _canLeave();
      _traceClose('unsaved check finished: allow=$canLeave');
      if (!canLeave) return;
      _exitCommitted = true;
      _traceClose('setPreventClose(false) begin');
      await windowManager.setPreventClose(false);
      _traceClose('normal close request begin');
      await windowManager.close();
      _traceClose('normal close request returned');
    } catch (error) {
      _exitCommitted = false;
      // Restore the safeguard if requesting the native close failed.
      try {
        await windowManager.setPreventClose(true);
      } catch (restoreError) {
        _traceClose('failed to restore close interception: $restoreError');
      }
      _error(error);
    } finally {
      _handlingExit = false;
    }
  }

  void _error(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('操作失败：$error')),
    );
  }

  Future<bool> _canLeave() async {
    if (_busy) return false;
    if (!_dirty) return true;
    final answer = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('有未保存的修改'),
        content: const Text('保存当前文档后继续？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, 'cancel'), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(context, 'discard'), child: const Text('不保存')),
          FilledButton(onPressed: () => Navigator.pop(context, 'save'), child: const Text('保存')),
        ],
      ),
    );
    if (answer == 'discard') return true;
    if (answer == 'save') {
      final saved = await _save();
      return saved && !_dirty;
    }
    return false;
  }

  Future<void> _newFile() async {
    if (Platform.isWindows) {
      if (_launchingWindow) return;
      _launchingWindow = true;
      try {
        await _startDocumentWindow();
      } catch (error) {
        _error(error);
      } finally {
        _launchingWindow = false;
      }
      return;
    }
    if (!await _canLeave()) return;
    _controller.clear();
    setState(() {
      _savedText = '';
      _path = null;
      _name = 'Untitled.md';
    });
  }

  Future<void> _open() async {
    if (Platform.isWindows) {
      if (_launchingWindow) return;
      _launchingWindow = true;
      try {
        final picked = await _files.pickFiles(allowedExtensions: ['md', 'markdown']);
        if (picked == null || picked.isEmpty) return;
        final path = picked.first.fileSystemPath;
        if (path == null) throw StateError('所选文件没有可用的本地路径');
        await _startDocumentWindow(path: File(path).absolute.path);
      } catch (error) {
        _error(error);
      } finally {
        _launchingWindow = false;
      }
      return;
    }
    if (!await _canLeave()) return;
    try {
      final picked = await _files.pickFiles(allowedExtensions: ['md', 'markdown']);
      if (picked == null || picked.isEmpty) return;
      final entry = picked.first;
      final bytes = await _files.readAllBytes(entry.path);
      final content = utf8.decode(bytes);
      if (!mounted) return;
      setState(() {
        _path = entry.path;
        _name = entry.name;
        _savedText = content;
        _controller.text = content;
      });
    } catch (error) {
      _error(error);
    }
  }

  Future<void> _startDocumentWindow({String? path}) async {
    if (!Platform.isWindows) return;
    // Pass arguments directly to CreateProcess; never interpolate a shell command.
    // resolvedExecutable follows the running Debug/Profile/Release installation.
    final executable = Platform.resolvedExecutable;
    await Process.start(
      executable,
      path == null ? const <String>[] : ['--open-file', path],
      workingDirectory: File(executable).parent.path,
      mode: ProcessStartMode.detached,
      runInShell: false,
    );
  }

  Future<bool> _save({bool saveAs = false}) async {
    if (_busy) return false;
    setState(() => _busy = true);
    try {
      final content = _controller.text;
      final bytes = Uint8List.fromList(utf8.encode(content));
      String? warning;
      if (Platform.isWindows) {
        final saved = await _storage.invokeMapMethod<String, dynamic>(
          _path == null || saveAs ? 'saveAs' : 'save',
          {'bytes': bytes, 'name': _name, 'path': _path ?? '', 'version': _diskVersion ?? ''},
        );
        if (saved == null || !mounted) return false;
        final path = saved['path'] as String;
        final version = saved['version'] as String;
        warning = saved['warning'] as String?;
        _path = path;
        _name = File(path).uri.pathSegments.last;
        _diskVersion = version;
        _unconfirmedSave = false;
      } else if (_path == null || saveAs) {
        final saved = await _files.saveFile(
          bytes,
          suggestedName: _name,
          allowedExtensions: ['md', 'markdown'],
          mimeType: 'text/markdown',
        );
        if (saved == null) return false;
        _path = saved.path;
        _name = saved.name;
      } else {
        await _files.writeFile(_path!, bytes);
      }
      if (!mounted) return true;
      setState(() => _savedText = content);
      _syncWindowTitle();
      if (warning != null && warning.isNotEmpty) {
        await _saveNotice('保存完成，需要检查备份目录', warning);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已保存')));
      }
      return true;
    } on PlatformException catch (error) {
      if (mounted && (error.code == 'recovery' || error.code == 'document_conflict')) {
        setState(() => _unconfirmedSave = true);
        _syncWindowTitle();
      }
      if (error.code == 'recovery' && mounted) {
        await _saveNotice('请核对磁盘文件', error.message ?? '无法核实保存结果，请另存为新文件。');
      } else {
        _error(error.message ?? error.code);
      }
      return false;
    } catch (error) {
      _error(error);
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveNotice(String title, String message) => showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(child: SelectableText(message)),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('知道了'))],
    ),
  );

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    final selection = _controller.selection;
    final start = selection.isValid ? selection.start : _controller.text.length;
    final end = selection.isValid ? selection.end : start;
    final updated = _controller.text.replaceRange(start, end, text);
    _controller.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: start + text.length),
    );
  }

  Future<void> _openLink(String url, String title) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !{'http', 'https'}.contains(uri.scheme)) return;
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        throw StateError('无法打开链接');
      }
    } catch (error) {
      _error(error);
    }
  }

  Widget _editor() {
    final editor = Container(
        color: Theme.of(context).colorScheme.surface,
        child: Shortcuts(
          shortcuts: Platform.isWindows ? const <ShortcutActivator, Intent>{
            SingleActivator(LogicalKeyboardKey.keyY, control: true):
                RedoTextIntent(SelectionChangedCause.keyboard),
          } : const <ShortcutActivator, Intent>{},
          child: TextField(
          key: _editorKey,
          focusNode: _editorFocus,
          controller: _controller,
          maxLines: null,
          // Windows uses the panel's outer viewport; the field grows with text.
          expands: !Platform.isWindows,
          scrollPhysics: Platform.isWindows ? const NeverScrollableScrollPhysics() : null,
          textAlignVertical: TextAlignVertical.top,
          keyboardType: TextInputType.multiline,
          style: Platform.isWindows
              ? _windowsBodyStyle.copyWith(
                  color: Theme.of(context).colorScheme.onSurface,
                )
              : const TextStyle(fontFamily: 'monospace', fontSize: 15, height: 1.5),
          decoration: InputDecoration(
            isCollapsed: true,
            hintText: '在这里粘贴或输入 Markdown…',
            border: InputBorder.none,
            // InputDecorator pads outside EditableText's scroll viewport.
            // Keep Windows' vertical viewport flush with the preview pane;
            // unlike SliverPadding, this padding does not scroll away.
            contentPadding: Platform.isWindows
                ? const EdgeInsets.symmetric(horizontal: 20)
                : const EdgeInsets.all(20),
          ),
          ),
        ),
      );

    if (!Platform.isWindows) return editor;
    final documentEditor = Actions(actions: {
      UndoTextIntent: CallbackAction<UndoTextIntent>(onInvoke: (_) => _documentUndo.undo()),
      RedoTextIntent: CallbackAction<RedoTextIntent>(onInvoke: (_) => _documentUndo.redo()),
    }, child: editor);
    return Scrollbar(
      controller: _editorScrollController,
      scrollbarOrientation: ScrollbarOrientation.right,
      child: ScrollConfiguration(
        behavior: const _EditorScrollBehavior(),
        child: LayoutBuilder(builder: (context, constraints) {
          return SingleChildScrollView(
            controller: _editorScrollController,
            primary: false,
            // This padding participates in maxScrollExtent and scrolls away.
            // It does not inset the viewport or move the scrollbar inward.
            padding: const EdgeInsets.only(bottom: 20),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: (constraints.maxHeight - 20).clamp(0.0, double.infinity).toDouble(),
              ),
              child: documentEditor,
            ),
          );
        }),
      ),
    );
  }

  Widget _markdownTheme(Widget child) {
    if (!Platform.isWindows) return child;
    final s = Theme.of(context).colorScheme;
    return markdown_ui.Theme(
      data: markdown_ui.ThemeData(
        useMaterial3: true, fontFamily: _readingFont, fontFamilyFallback: _readingFallback,
        // CodeField merges this style before applying its Consolas family.
        // Keep the CJK fallback explicit for fenced code's Text.rich as well.
        textTheme: markdown_ui.TextTheme(
          bodyMedium: Theme.of(context).textTheme.bodyMedium?.copyWith(
            fontFamilyFallback: const [_chineseReadingFont, 'Source Han Sans SC', 'Microsoft YaHei', 'Segoe UI Symbol'],
          ),
        ),
        colorScheme: markdown_ui.ColorScheme.fromSeed(
          seedColor: const Color(0xFF777777), brightness: s.brightness,
        ).copyWith(
          primary: s.primary, onPrimary: s.onPrimary,
          secondary: s.secondary, onSecondary: s.onSecondary,
          primaryContainer: s.primaryContainer, onPrimaryContainer: s.onPrimaryContainer,
          secondaryContainer: s.secondaryContainer, onSecondaryContainer: s.onSecondaryContainer,
          surface: s.surface, onSurface: s.onSurface, onSurfaceVariant: s.onSurfaceVariant,
          surfaceContainer: s.surfaceContainer,
          surfaceContainerLow: s.surfaceContainerLow,
          surfaceContainerHigh: s.surfaceContainerHigh,
          surfaceContainerHighest: s.surfaceContainer,
          outline: s.outline, outlineVariant: s.outlineVariant,
          surfaceTint: Colors.transparent,
        ),
      ),
      child: child,
    );
  }

  Widget _preview({bool visible = true}) => Container(
        color: Theme.of(context).colorScheme.surface,
        child: _markdownTheme(SelectionArea(
          focusNode: _previewFocus,
          onSelectionChanged: (content) => _previewSelection = content?.plainText ?? '',
          child: CustomPaint(
            key: _previewKey,
            foregroundPainter: visible && _panelOpen && _find.hits.isNotEmpty ? _previewPainter() : null,
            child: CustomScrollView(
            controller: _previewScrollController,
            primary: false,
            slivers: [
              SliverPadding(
                // Match the Windows editor's zero top inset. This changes
                // scrollable content spacing, not the viewport or block gaps.
                padding: Platform.isWindows
                    ? const EdgeInsets.fromLTRB(20, 0, 20, 20)
                    : const EdgeInsets.all(20),
                sliver: SliverGptMarkdown(
                  _controller.text,
                  useDollarSignsForLatex: true,
                  config: GptMarkdownConfig(
                    style: Platform.isWindows
                        ? _windowsBodyStyle.copyWith(
                            color: Theme.of(context).colorScheme.onSurface,
                          )
                        : null,
                    styleSheet: Platform.isWindows
                        ? GptMarkdownStyleSheet(
                            heading: HeadingStyle(
                              textStyle: TextStyle(
                                fontFamily: _readingFont,
                                fontFamilyFallback: _readingFallback,
                                fontWeight: FontWeight.w700,
                                height: 1.4,
                                letterSpacing: 0,
                              ),
                            ),
                            codeBlock: CodeBlockStyle(
                              fontFamily: 'Consolas',
                              fontSize: 15,
                              backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
                              borderColor: Theme.of(context).colorScheme.outlineVariant,
                              borderWidth: 1,
                              borderRadius: const Radius.circular(8),
                              textColor: Theme.of(context).colorScheme.onSurface,
                            ),
                            inlineCode: InlineCodeStyle(
                              fontFamily: 'Consolas',
                              fontFamilyFallback: [_chineseReadingFont, 'Source Han Sans SC', 'Microsoft YaHei', 'Segoe UI Symbol'],
                              backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
                              color: Theme.of(context).colorScheme.onSurface,
                              borderWidth: 0,
                              borderColor: Colors.transparent,
                              borderRadius: const Radius.circular(4),
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                            ),
                            table: TableStyle(
                              borderColor: Theme.of(context).colorScheme.outlineVariant,
                              borderWidth: 1,
                              headerBackground: Theme.of(context).colorScheme.surfaceContainer,
                              rowStripeColor: Theme.of(context).colorScheme.surface,
                            ),
                          )
                        : null,
                    onLinkTap: _openLink,
                    // The package's Checkbox uses material_ui.Material, which
                    // is a different type from Flutter's Material. Read-only
                    // icons need neither Material ancestor nor tap callbacks.
                    checkboxBuilder: (context, checked, content, style) => Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Semantics(
                          checked: checked,
                          child: ExcludeSemantics(
                            child: Icon(
                              checked
                                  ? Icons.check_box_outlined
                                  : Icons.check_box_outline_blank,
                              size: 20,
                              color: Theme.of(context).colorScheme.onSurface,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Flexible(child: content),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ))),
      );

  Widget _viewControl({bool compact = false}) {
    final scheme = Theme.of(context).colorScheme;
    return SegmentedButton<ViewMode>(
      showSelectedIcon: false,
      segments: [
        ButtonSegment(value: ViewMode.both, label: compact ? null : const Text('分栏'),
          icon: compact ? const Icon(Icons.vertical_split_outlined, size: 18) : null, tooltip: '分栏'),
        ButtonSegment(value: ViewMode.editor, label: compact ? null : const Text('编辑'),
          icon: compact ? const Icon(Icons.edit_outlined, size: 18) : null, tooltip: '编辑'),
        ButtonSegment(value: ViewMode.preview, label: compact ? null : const Text('预览'),
          icon: compact ? const Icon(Icons.article_outlined, size: 18) : null, tooltip: '预览'),
      ],
      selected: {_view},
      onSelectionChanged: (value) => _setView(value.first),
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(0, 34)),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10)),
        textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 13)),
        foregroundColor: WidgetStatePropertyAll(scheme.onSurface),
        backgroundColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected) ? scheme.secondaryContainer : Colors.transparent),
        side: WidgetStatePropertyAll(BorderSide(color: scheme.outlineVariant)),
        shape: const WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(7)))),
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }

  Widget _toolbarMore({required bool collapsed, required bool includeSave, bool includeViews = false}) => PopupMenuButton<String>(
    tooltip: '更多', iconSize: 21,
    onSelected: (value) {
      if (value == 'find') _openFind(false);
      if (value == 'replace') _openFind(true);
      if (value == 'new') _newFile();
      if (value == 'open') _open();
      if (value == 'save') _save();
      if (value == 'saveAs') _save(saveAs: true);
      if (value == 'theme') widget.onThemeToggle();
      if (value == 'both') _setView(ViewMode.both);
      if (value == 'editor') _setView(ViewMode.editor);
      if (value == 'preview') _setView(ViewMode.preview);
      if (value == 'reset') _setView(ViewMode.both, resetSplit: true);
    },
    itemBuilder: (_) => [
      if (collapsed) const PopupMenuItem(value: 'new', child: Text('新建')),
      if (collapsed) const PopupMenuItem(value: 'open', child: Text('打开')),
      if (includeSave) PopupMenuItem(value: 'save', enabled: !_busy, child: const Text('保存')),
      PopupMenuItem(value: 'saveAs', enabled: !_busy, child: const Text('另存为')),
      const PopupMenuItem(value: 'find', child: Text('查找  Ctrl+F')),
      const PopupMenuItem(value: 'replace', child: Text('替换  Ctrl+H')),
      if (includeViews) const PopupMenuItem(value: 'both', child: Text('分栏')),
      if (includeViews) const PopupMenuItem(value: 'editor', child: Text('编辑')),
      if (includeViews) const PopupMenuItem(value: 'preview', child: Text('预览')),
      const PopupMenuItem(value: 'theme', child: Text('切换浅色／深色')),
      const PopupMenuItem(value: 'reset', child: Text('恢复默认布局')),
    ],
  );

  PreferredSizeWidget _windowsToolbar() => PreferredSize(
    preferredSize: const Size.fromHeight(54),
    child: Material(
      color: Theme.of(context).appBarTheme.backgroundColor,
      child: Container(
        height: 54,
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Theme.of(context).colorScheme.outlineVariant))),
        child: LayoutBuilder(builder: (context, constraints) {
          final width = constraints.maxWidth;
          final compact = width < 420;
          final menuViews = width < 300;
          final actionSize = compact ? 36.0 : 40.0;
          Widget action(String tip, IconData icon, VoidCallback? callback) => SizedBox(
            width: actionSize, height: 40,
            child: IconButton(
              tooltip: tip, iconSize: 21, padding: EdgeInsets.zero,
              onPressed: callback, icon: Icon(icon),
            ),
          );
          final controls = Row(children: [
            SizedBox(width: menuViews ? 36 : (compact ? 126 : 216), child: menuViews
              ? PopupMenuButton<ViewMode>(
                  tooltip: '视图', padding: EdgeInsets.zero,
                  icon: const Icon(Icons.view_week_outlined, size: 21),
                  onSelected: (value) => _setView(value),
                  itemBuilder: (_) => ViewMode.values.map((mode) => CheckedPopupMenuItem(
                    value: mode, checked: mode == _view,
                    child: Text(['分栏', '编辑', '预览'][mode.index]))).toList(),
                )
              : _viewControl(compact: compact)),
            const Spacer(),
            action('新建', Icons.note_add_outlined, _newFile),
            action('打开', Icons.folder_open_outlined, _open),
            action('保存', Icons.save_outlined, _busy ? null : () => _save()),
            SizedBox(width: actionSize, height: 40,
              child: _toolbarMore(collapsed: false, includeSave: false)),
          ]);
          // Keep file actions visible; only exceptionally small windows scale.
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: width < 208
                ? FittedBox(fit: BoxFit.scaleDown,
                    child: SizedBox(width: 192, height: 40, child: controls))
                : controls,
          );
        }),
      ),
    ),
  );

  Widget _desktopBody(BoxConstraints constraints) {
    final width = constraints.maxWidth;
    final split = _view == ViewMode.both && width > 10;
    final available = (width - 10).clamp(0.0, double.infinity).toDouble();
    final minimum = available < 440 ? available * .2 : 220.0;
    final leftWidth = (available * _editorFraction).clamp(minimum, available - minimum).toDouble();
    final showEditor = _view != ViewMode.preview;
    final showPreview = _view != ViewMode.editor && (width > 10 || _view == ViewMode.preview);
    if (showEditor) _editorLayoutWidth = split ? leftWidth : width;
    if (showPreview) _previewLayoutWidth = split ? available - leftWidth : width;
    // Keep the mounted viewport, but don't feed edits or new Markdown
    // configurations into its sliver while it is offstage.
    if (showPreview || _lastDesktopPreview == null) {
      _lastDesktopPreview = _preview(visible: showPreview);
    }
    // Stable sibling slots retain both subtrees and their ScrollPositions.
    // Hidden panes keep their last width so hiding does not reflow their text.
    return Stack(children: [
      Positioned(left: 0, top: 0, bottom: 0,
        width: _editorLayoutWidth ?? width,
        child: Offstage(offstage: !showEditor,
          child: ExcludeFocus(excluding: !showEditor, child: _editor()))),
      Positioned(right: 0, top: 0, bottom: 0,
        width: _previewLayoutWidth ?? width,
        child: Offstage(offstage: !showPreview,
          child: ExcludeFocus(excluding: !showPreview, child: _lastDesktopPreview!))),
      Positioned(left: leftWidth, top: 0, bottom: 0, width: 10,
        child: Offstage(offstage: !split,
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeColumn,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragUpdate: (details) => setState(() {
                _editorFraction = ((leftWidth + details.delta.dx) / available)
                    .clamp(minimum / available, 1 - minimum / available);
              }),
              child: const VerticalDivider(width: 10, thickness: 1),
            ),
          ),
        ),
      ),
      if (_panelOpen) Positioned(top: 8, right: 8,
        width: (width - 16).clamp(0, 410).toDouble(),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: (constraints.maxHeight - 16).clamp(0.0, double.infinity)),
          child: SingleChildScrollView(child: _findPanel()),
        )),
    ]);
  }

  Widget _findPanel() {
    final colors = Theme.of(context).colorScheme;
    final enabled = _find.current != null;
    const radius = BorderRadius.all(Radius.circular(6));
    final border = OutlineInputBorder(
      borderRadius: radius, borderSide: BorderSide(color: colors.outlineVariant));
    final focusedBorder = border.copyWith(borderSide: BorderSide(width: 1.5,
      color: Color.alphaBlend(colors.onSurfaceVariant.withValues(alpha: .5), colors.outlineVariant)));
    final buttonStyle = ButtonStyle(
      visualDensity: VisualDensity.standard,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      minimumSize: const WidgetStatePropertyAll(Size(32, 32)),
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 8)),
      shape: const WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: radius)),
      foregroundColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.disabled)
          ? colors.onSurface.withValues(alpha: .38) : colors.onSurface),
      backgroundColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.selected)
          ? colors.secondaryContainer : Colors.transparent),
      overlayColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.pressed)) return colors.onSurface.withValues(alpha: .14);
        if (states.contains(WidgetState.focused)) return colors.onSurface.withValues(alpha: .12);
        if (states.contains(WidgetState.hovered)) return colors.onSurface.withValues(alpha: .07);
        return Colors.transparent;
      }),
    );
    final iconStyle = buttonStyle.copyWith(
      fixedSize: const WidgetStatePropertyAll(Size.square(32)),
      iconSize: const WidgetStatePropertyAll(18),
      iconColor: buttonStyle.foregroundColor,
      padding: const WidgetStatePropertyAll(EdgeInsets.zero),
    );
    Widget field(bool replace) => TextField(
      key: replace ? _replacementKey : _queryKey,
      controller: replace ? _replacement : _query,
      focusNode: replace ? _replacementFocus : _queryFocus,
      onChanged: replace ? null : (_) => _refreshFind(anchor: 0),
      decoration: InputDecoration(isDense: true, filled: true, fillColor: colors.surface,
        border: border, enabledBorder: border, focusedBorder: focusedBorder,
        hintText: replace ? '替换为' : '查找内容',
        contentPadding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8)),
    );
    Widget button(String tip, Widget icon, VoidCallback? action, {bool? selected}) => IconButton(
      tooltip: tip, style: iconStyle, isSelected: selected, onPressed: action, icon: icon);
    Widget arrow(bool up) => Builder(builder: (context) => CustomPaint(
      size: const Size.square(18),
      painter: _FindChevron(up, IconTheme.of(context).color ?? colors.onSurface)));
    final actions = Wrap(spacing: 2, alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center, children: [
      Padding(padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text('${_find.index + 1}/${_find.hits.length}',
          style: Theme.of(context).textTheme.labelMedium?.copyWith(color: colors.onSurfaceVariant))),
      button('区分大小写', const Text('Aa', style: TextStyle(fontSize: 14)),
        () { _find.matchCase = !_find.matchCase; _refreshFind(); }, selected: _find.matchCase),
      button('上一个', arrow(true), enabled ? () => _moveFind(-1) : null),
      button('下一个', arrow(false), enabled ? () => _moveFind(1) : null),
      button('关闭查找', const Icon(Icons.close), _closeFind),
    ]);
    final replaceActions = Wrap(spacing: 2, alignment: WrapAlignment.end, children: [
      TextButton(style: buttonStyle, onPressed: enabled ? () => _replaceFind(false) : null, child: const Text('替换')),
      TextButton(style: buttonStyle, onPressed: enabled ? () => _replaceFind(true) : null, child: const Text('全部替换')),
    ]);
    return Material(elevation: 3, color: colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: colors.outlineVariant)),
      child: Padding(padding: const EdgeInsets.all(6), child: LayoutBuilder(builder: (_, box) {
        Widget row(Widget input, Widget controls) => box.maxWidth < 320
            ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                input, const SizedBox(height: 4), Align(alignment: Alignment.centerRight, child: controls)])
            : Row(children: [Expanded(child: input), const SizedBox(width: 6),
                SizedBox(width: box.maxWidth * .52,
                  child: Align(alignment: Alignment.centerRight, child: controls))]);
        return Focus(onKeyEvent: (_, event) {
          if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
          final value = (_replacementFocus.hasFocus ? _replacement : _query).value;
          if (value.composing.isValid && !value.composing.isCollapsed) return KeyEventResult.ignored;
          if (event.logicalKey == LogicalKeyboardKey.escape) {
            _closeFind();
          } else if (event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.numpadEnter) {
            _moveFind(HardwareKeyboard.instance.isShiftPressed ? -1 : 1);
          } else { return KeyEventResult.ignored; }
          return KeyEventResult.handled;
        }, child: Column(mainAxisSize: MainAxisSize.min, children: [
          row(field(false), actions),
          if (_replaceMode) ...[const SizedBox(height: 4), row(field(true), replaceActions)],
        ]));
      })));
  }

  @override
  Widget build(BuildContext context) {
    final mobile = !Platform.isWindows && (MediaQuery.sizeOf(context).width < 700 || Platform.isAndroid);
    final visible = mobile && _view == ViewMode.both ? ViewMode.editor : _view;
    final page = PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop || _handlingExit) return;
        _handlingExit = true;
        try {
          if (await _canLeave() && mounted && Platform.isAndroid) {
            await SystemNavigator.pop();
          }
        } finally {
          _handlingExit = false;
        }
      },
      child: Scaffold(
        appBar: Platform.isWindows ? _windowsToolbar() : AppBar(
          title: Text(_documentLabel, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(tooltip: '新建', onPressed: _newFile, icon: const Icon(Icons.note_add_outlined)),
            IconButton(tooltip: '打开', onPressed: _open, icon: const Icon(Icons.folder_open_outlined)),
            IconButton(tooltip: '粘贴', onPressed: _paste, icon: const Icon(Icons.content_paste)),
            IconButton(tooltip: '保存', onPressed: _busy ? null : () => _save(), icon: const Icon(Icons.save_outlined)),
            PopupMenuButton<String>(
              tooltip: '更多',
              onSelected: (value) {
                if (value == 'saveAs') _save(saveAs: true);
                if (value == 'theme') widget.onThemeToggle();
                if (value == 'reset') _setView(ViewMode.both, resetSplit: true);
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'saveAs', child: Text('另存为')),
                PopupMenuItem(value: 'theme', child: Text('切换浅色／深色')),
                PopupMenuItem(value: 'reset', child: Text('恢复默认布局')),
              ],
            ),
          ],
        ),
        body: Column(children: [
          if (!Platform.isWindows)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: SegmentedButton<ViewMode>(
              segments: mobile
                  ? const [
                      ButtonSegment(value: ViewMode.editor, label: Text('编辑')),
                      ButtonSegment(value: ViewMode.preview, label: Text('预览')),
                    ]
                  : const [
                      ButtonSegment(value: ViewMode.both, label: Text('分栏')),
                      ButtonSegment(value: ViewMode.editor, label: Text('编辑')),
                      ButtonSegment(value: ViewMode.preview, label: Text('预览')),
                    ],
              selected: {visible},
              onSelectionChanged: (value) => _setView(value.first),
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => mobile
                  ? (visible == ViewMode.preview ? _preview() : _editor())
                  : _desktopBody(constraints),
            ),
          ),
        ]),
      ),
    );
    if (!Platform.isWindows) return page;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): () => _openFind(false),
        const SingleActivator(LogicalKeyboardKey.keyH, control: true): () => _openFind(true),
        if (_panelOpen) const SingleActivator(LogicalKeyboardKey.escape): () {
          final composing = (_replacementFocus.hasFocus ? _replacement : _query).value.composing;
          if (!_fieldFocused || !composing.isValid || composing.isCollapsed) _closeFind();
        },
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): () {
          if (!_handlingExit && !_exitCommitted) _save();
        },
      },
      child: Focus(autofocus: true, onKeyEvent: (_, event) {
        // Text fields handle their own intents. Check focus at dispatch time:
        // a toolbar button or the preview can gain focus without rebuilding.
        if (_fieldFocused || (!_panelOpen && !_previewFocus.hasFocus) ||
            (event is! KeyDownEvent && event is! KeyRepeatEvent)) {
          return KeyEventResult.ignored;
        }
        final keys = HardwareKeyboard.instance;
        if (!keys.isControlPressed || keys.isAltPressed || keys.isMetaPressed) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.keyZ) {
          keys.isShiftPressed ? _documentUndo.redo() : _documentUndo.undo();
        } else if (event.logicalKey == LogicalKeyboardKey.keyY && !keys.isShiftPressed) {
          _documentUndo.redo();
        } else {
          return KeyEventResult.ignored;
        }
        return KeyEventResult.handled;
      }, child: page),
    );
  }
}

/// Draw the navigation marks at desktop control size, independently of
/// which Material icon glyphs are present in the installed font subset.
class _FindChevron extends CustomPainter {
  const _FindChevron(this.up, this.color);
  final bool up;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final dy = up ? 2.25 : -2.25;
    final path = Path()
      ..moveTo(center.dx - 4.5, center.dy + dy)
      ..lineTo(center.dx, center.dy - dy)
      ..lineTo(center.dx + 4.5, center.dy + dy);
    canvas.drawPath(path, Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.75
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round);
  }

  @override
  bool shouldRepaint(_FindChevron old) => old.up != up || old.color != color;
}
