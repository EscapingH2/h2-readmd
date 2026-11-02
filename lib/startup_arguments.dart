/// Returns the document path from already-tokenized process arguments.
/// Supports Windows "Open with" and the application's new-window protocol.
String? parseStartupFilePath(List<String> arguments) {
  if (arguments.isEmpty) return null;

  final String path;
  if (arguments.length == 1 && !arguments.first.startsWith('--')) {
    path = arguments.first;
  } else if (arguments.length == 2 && arguments.first == '--open-file') {
    path = arguments[1];
  } else {
    throw const FormatException('无效的启动参数');
  }
  if (path.isEmpty) throw const FormatException('无效的启动参数');
  return path;
}
