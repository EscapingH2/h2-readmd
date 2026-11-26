import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_reader/find_preview.dart';

void main() {
  test('Unclosed bracket mapping grows near linearly as input doubles', () {
    int measure(String source) {
      final watch = Stopwatch()..start();
      final map = PreviewFindMap(source);
      watch.stop();
      expect(map.blocks.single.end, source.length);
      return watch.elapsedMicroseconds;
    }

    final inputs = [
      for (final n in [1024, 2048, 4096, 8192]) '[' * n,
    ];
    final samples = [for (final _ in inputs) <int>[]];
    for (var round = 0; round < 14; round++) {
      for (var i = 0; i < inputs.length; i++) {
        final index = round.isEven ? i : inputs.length - 1 - i;
        final elapsed = measure(inputs[index]);
        if (round >= 5) samples[index].add(elapsed);
      }
    }
    final timings = [for (final values in samples) (values..sort())[4]];
    // An 8x input costs ~64x on the old path. Compare medians over the
    // whole range to tolerate scheduler noise without a machine-specific SLA.
    // ignore: avoid_print
    print('PreviewFindMap median microseconds (1024..8192 brackets): $timings');
    expect(timings.last / timings.first, lessThan(22));
  });
}
