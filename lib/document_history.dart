import 'dart:async';

import 'package:flutter/widgets.dart';

/// Windows document history. Typing is grouped, but a replacement always
/// closes the typing group and creates one immediately available undo step.
class DocumentHistory {
  DocumentHistory(this.controller) : _states = [_snapshot(controller.value)] {
    controller.addListener(_record);
  }

  final TextEditingController controller;
  final List<TextEditingValue> _states;
  int _index = 0;
  Timer? _typingGroup;
  bool _applying = false;

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
      _states.removeLast();
      _index--;
      _endGroup();
    }
    if (_states[_index].text == snapshot.text || _typingGroup != null) {
      _states[_index] = snapshot;
      return;
    }
    _append(snapshot);
    _typingGroup = Timer(const Duration(milliseconds: 500), _endGroup);
  }

  void _append(TextEditingValue value) {
    _states.removeRange(_index + 1, _states.length);
    _states.add(value);
    _index++;
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
