import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_reader/startup_arguments.dart';

void main() {
  test('No arguments opens a blank document', () {
    expect(parseStartupFilePath([]), isNull);
  });

  for (final path in [
    r'D:\Documents\document.md',
    r'D:\My Documents\meeting notes.md',
    r'D:\文档\测试文档.md',
    r'D:\My Documents\中文 空格 é Ω.markdown',
  ]) {
    test('Positional path is preserved: $path', () {
      expect(parseStartupFilePath([path]), path);
    });
    test('Existing --open-file path is preserved: $path', () {
      expect(parseStartupFilePath(['--open-file', path]), path);
    });
  }

  test('Malformed arguments are rejected', () {
    for (final arguments in <List<String>>[
      ['--open-file'],
      ['--unknown', 'document.md'],
      ['one.md', 'two.md'],
      ['--open-file', 'one.md', 'two.md'],
      [''],
      ['--open-file', ''],
    ]) {
      expect(() => parseStartupFilePath(arguments), throwsFormatException);
    }
  });
}
