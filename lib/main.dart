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
    fontFamily: 'Microsoft YaHei', scaffoldBackgroundColor: surface,
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
  fontFamily: 'Microsoft YaHei',
  fontFamilyFallback: ['Microsoft YaHei UI', 'Segoe UI', 'Segoe UI Symbol'],
  fontSize: 16,
  height: 1.6,
  fontWeight: FontWeight.w400,
  letterSpacing: 0,
);

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  String? initialPath;
  String initialText = '';
  String? startupError;
  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
    if (arguments.isNotEmpty) {
      try {
        final path = parseStartupFilePath(arguments)!;
        final file = File(path).absolute;
        initialText = await file.readAsString(encoding: utf8);
        initialPath = file.path;
      } catch (error) {
        startupError = '无法打开文档：$error';
      }
    }
  }
  runApp(MarkdownApp(
    initialPath: initialPath,
    initialText: initialText,
    startupError: startupError,
  ));
}

class MarkdownApp extends StatefulWidget {
  const MarkdownApp({super.key, this.initialPath, this.initialText = '', this.startupError});
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
        home: EditorPage(
          initialPath: widget.initialPath,
          initialText: widget.initialText,
          startupError: widget.startupError,
          onThemeToggle: () => setState(() {
            mode = mode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
          }),
        ),
      );
}

enum ViewMode { both, editor, preview }

class EditorPage extends StatefulWidget {
  const EditorPage({super.key, required this.onThemeToggle, this.initialPath, this.initialText = '', this.startupError});
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
  final _controller = TextEditingController();
  final _editorScrollController = ScrollController();
  String? _path;
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

  bool get _dirty => _controller.text != _savedText;
  String get _documentLabel => '${_dirty ? '*' : ''}$_name';

  @override
  void initState() {
    super.initState();
    _path = widget.initialPath;
    if (_path != null) _name = File(_path!).uri.pathSegments.last;
    _savedText = widget.initialText;
    _controller.text = widget.initialText;
    _controller.addListener(_changed);
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
    setState(() {});
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
    _controller.dispose();
    _editorScrollController.dispose();
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
      if (_path == null || saveAs) {
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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已保存')));
      return true;
    } catch (error) {
      _error(error);
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

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
        child: TextField(
          controller: _controller,
          scrollController: Platform.isWindows ? _editorScrollController : null,
          maxLines: null,
          expands: true,
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
      );

    if (!Platform.isWindows) return editor;
    return Scrollbar(
      controller: _editorScrollController,
      scrollbarOrientation: ScrollbarOrientation.right,
      child: ScrollConfiguration(
        behavior: const _EditorScrollBehavior(),
        child: editor,
      ),
    );
  }

  Widget _markdownTheme(Widget child) {
    if (!Platform.isWindows) return child;
    final s = Theme.of(context).colorScheme;
    return markdown_ui.Theme(
      data: markdown_ui.ThemeData(
        useMaterial3: true, fontFamily: 'Microsoft YaHei',
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

  Widget _preview() => Container(
        color: Theme.of(context).colorScheme.surface,
        child: _markdownTheme(SelectionArea(
          child: CustomScrollView(
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
                                fontFamily: 'Microsoft YaHei',
                                fontWeight: FontWeight.w600,
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
                              fontFamilyFallback: ['Microsoft YaHei', 'Segoe UI Symbol'],
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
        )),
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
      onSelectionChanged: (value) => setState(() => _view = value.first),
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
      if (value == 'new') _newFile();
      if (value == 'open') _open();
      if (value == 'save') _save();
      if (value == 'saveAs') _save(saveAs: true);
      if (value == 'theme') widget.onThemeToggle();
      if (value == 'both') setState(() => _view = ViewMode.both);
      if (value == 'editor') setState(() => _view = ViewMode.editor);
      if (value == 'preview') setState(() => _view = ViewMode.preview);
      if (value == 'reset') setState(() { _view = ViewMode.both; _editorFraction = .5; });
    },
    itemBuilder: (_) => [
      if (collapsed) const PopupMenuItem(value: 'new', child: Text('新建')),
      if (collapsed) const PopupMenuItem(value: 'open', child: Text('打开')),
      if (includeSave) PopupMenuItem(value: 'save', enabled: !_busy, child: const Text('保存')),
      PopupMenuItem(value: 'saveAs', enabled: !_busy, child: const Text('另存为')),
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
          // At extreme widths, keep every action reachable without overlapping.
          if (width < 160) {
            return Align(alignment: Alignment.centerRight,
              child: _toolbarMore(collapsed: true, includeSave: true, includeViews: true));
          }
          final full = width >= 720;
          final tiny = width < 400;
          final showSave = width >= 480;
          final centerWidth = tiny ? 40.0 : (full ? 216.0 : 144.0);
          final sideWidth = ((width - centerWidth) / 2 - 16).clamp(0.0, double.infinity).toDouble();
          Widget action(String tip, IconData icon, VoidCallback? callback) => SizedBox(
            width: 40, height: 40,
            child: IconButton(tooltip: tip, iconSize: 21, onPressed: callback, icon: Icon(icon)),
          );
          return Stack(alignment: Alignment.center, children: [
            Positioned(left: 12, width: sideWidth,
              child: Tooltip(message: _documentLabel, child: Text(_documentLabel,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w500)))),
            SizedBox(width: centerWidth, child: tiny
              ? PopupMenuButton<ViewMode>(
                  tooltip: '视图', icon: const Icon(Icons.view_week_outlined, size: 21),
                  onSelected: (value) => setState(() => _view = value),
                  itemBuilder: (_) => ViewMode.values.map((mode) => CheckedPopupMenuItem(
                    value: mode, checked: mode == _view,
                    child: Text(['分栏', '编辑', '预览'][mode.index]))).toList(),
                )
              : _viewControl(compact: !full)),
            Positioned(right: 8, child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (full) action('新建', Icons.note_add_outlined, _newFile),
              if (full) action('打开', Icons.folder_open_outlined, _open),
              if (showSave) action('保存', Icons.save_outlined, _busy ? null : () => _save()),
              SizedBox(width: 40, height: 40, child: _toolbarMore(collapsed: !full, includeSave: !showSave)),
            ])),
          ]);
        }),
      ),
    ),
  );

  Widget _desktopBody(BoxConstraints constraints) {
    if (_view == ViewMode.editor) return _editor();
    if (_view == ViewMode.preview) return _preview();
    final width = constraints.maxWidth;
    if (width <= 10) return _editor();
    final available = width - 10;
    final minimum = available < 440 ? available * .2 : 220.0;
    final leftWidth = (available * _editorFraction).clamp(minimum, available - minimum).toDouble();
    return Row(children: [
      SizedBox(width: leftWidth, child: _editor()),
      MouseRegion(
        cursor: SystemMouseCursors.resizeColumn,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (details) => setState(() {
            _editorFraction = ((leftWidth + details.delta.dx) / available)
                .clamp(minimum / available, 1 - minimum / available);
          }),
          child: const SizedBox(width: 10, child: VerticalDivider(width: 10, thickness: 1)),
        ),
      ),
      Expanded(child: _preview()),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final mobile = !Platform.isWindows && (MediaQuery.sizeOf(context).width < 700 || Platform.isAndroid);
    final visible = mobile && _view == ViewMode.both ? ViewMode.editor : _view;
    return PopScope(
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
                if (value == 'reset') setState(() { _view = ViewMode.both; _editorFraction = .5; });
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
              onSelectionChanged: (value) => setState(() => _view = value.first),
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
  }
}
