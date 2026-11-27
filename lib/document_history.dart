import 'dart:async';

import 'package:flutter/widgets.dart';

/// Windows document history. Typing is grouped, but a replacement always
/// closes the typing group and creates one immediately available undo step.
class DocumentHistory {
  DocumentHistory(this.controller, {int byteBudget = 64 * 1024 * 1024})
      : assert(byteBudget >= 0),
        _byteBudget = byteBudget,
        _estimatedBytes = _cost(controller.value),
        _states = [_snapshot(controller.value)] {
    controller.addListener(_record);
  }

  final TextEditingController controller;
  final List<TextEditingValue> _states;
  final int _byteBudget;
  int _estimatedBytes;
  int _index = 0;
  Timer? _typingGroup;
  bool _applying = false;

  // Charge each retained snapshot independently: UTF-16 payload plus a fixed
  // allowance for the entry, string and editing metadata. Dart may share text
  // or use one-byte strings, so this estimates history size, not heap usage.
  static int _cost(TextEditingValue value) => 64 + 2 * value.text.length;

  static TextEditingValue _snapshot(TextEditingValue value) => value.copyWith(
    composing: TextRange.empty,
    selection: value.selection.isValid
        ? value.selection
        : const TextSelection.collapsed(offset: 0),
  );

  void _record() {
    final value = controller.value;
    if (_applying || (value.composing.isValid && !value.composing.isCollapsed)) return;
    final snapshot = _snapshot(value);
    if (_typingGroup != null && _index > 0 && _states[_index - 1].text == snapshot.text) {
      // Typing and immediately erasing it leaves no empty undo step.
      _estimatedBytes -= _cost(_states.removeLast());
      _index--;
      _endGroup();
    }
    if (_states[_index].text == snapshot.text || _typingGroup != null) {
      _estimatedBytes += _cost(snapshot) - _cost(_states[_index]);
      _states[_index] = snapshot;
      _trimOldest();
      return;
    }
    _append(snapshot);
    _typingGroup = Timer(const Duration(milliseconds: 500), _endGroup);
  }

  void _append(TextEditingValue value) {
    while (_states.length > _index + 1) {
      _estimatedBytes -= _cost(_states.removeLast());
    }
    _states.add(value);
    _estimatedBytes += _cost(value);
    _index++;
    _trimOldest();
  }

  void _trimOldest() {
    // Keep both ends of the latest undo step even if that pair alone is
    // larger than the budget. Moving the undo/redo cursor never trims.
    var count = 0;
    while (_estimatedBytes > _byteBudget && count < _index - 1) {
      _estimatedBytes -= _cost(_states[count]);
      count++;
    }
    if (count > 0) {
      _states.removeRange(0, count);
      _index -= count;
    }
  }

  void _endGroup() {
    _typingGroup?.cancel();
    _typingGroup = null;
  }

  void replace(TextEditingValue next) {
    if (next.text == controller.text) return;
    _endGroup();
    final before = _snapshot(controller.value);
    if (_states[_index].text != before.text) _append(before);
    _states[_index] = before;
    _append(_snapshot(next));
    _apply();
  }

  void undo() {
    if (!controller.value.composing.isCollapsed && controller.text != _states[_index].text) {
      _apply();
      return;
    }
    if (_index == 0) return;
    _index--;
    _apply();
  }

  void redo() {
    if (_index + 1 >= _states.length) return;
    _index++;
    _apply();
  }

  void _apply() {
    _endGroup();
    _applying = true;
    try {
      controller.value = _states[_index];
    } finally {
      _applying = false;
    }
  }

  void dispose() {
    controller.removeListener(_record);
    _endGroup();
  }
}
