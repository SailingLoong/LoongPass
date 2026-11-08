// ZCode endpoint interoperability adapted from magpie-community/plugins
// packages/zcode 0.1.56 (MIT). This does not alter tool text or tool references.
import 'dart:convert';

class ZcodeToolSearch {
  static const _name = 'ToolSearch';
  static const _alias = 'ToolSearchTool';
  static const _placeholder = 'DeferredToolPlaceholder';
  final Map<String, dynamic> body;
  final bool renamed;
  ZcodeToolSearch._(this.body, this.renamed);

  factory ZcodeToolSearch.fromRequest(Map<String, dynamic> body) {
    final tools = body['tools'];
    if (tools is! List ||
        !tools.any((t) => t is Map && t['name'] == _name) ||
        tools.any((t) => t is Map && t['name'] == _alias)) {
      return ZcodeToolSearch._(body, false);
    }
    final request = jsonDecode(jsonEncode(body)) as Map<String, dynamic>;
    request['tools'] = [
      for (final tool in request['tools'])
        if (tool is! Map || tool['name'] != _placeholder)
          if (tool is Map)
            {
              for (final entry in tool.entries)
                if (entry.key != 'defer_loading') entry.key: entry.value,
              if (tool['name'] == _name) 'name': _alias,
            }
          else
            tool,
    ];
    for (final message in request['messages'] as List? ?? const []) {
      if (message is Map &&
          message['role'] == 'assistant' &&
          message['content'] is List) {
        for (final block in message['content']) {
          if (block is Map &&
              block['type'] == 'tool_use' &&
              block['name'] == _name)
            block['name'] = _alias;
        }
      }
    }
    final choice = request['tool_choice'];
    if (choice is Map && choice['type'] == 'tool' && choice['name'] == _name)
      choice['name'] = _alias;
    return ZcodeToolSearch._(request, true);
  }

  bool _restoreBlock(Object? block) {
    if (block is Map &&
        block['type'] == 'tool_use' &&
        block['name'] == _alias) {
      block['name'] = _name;
      return true;
    }
    return false;
  }

  /// Restores a JSON Message or SSE content-block event, never ordinary text.
  bool restore(Map<String, dynamic> value) {
    if (!renamed) return false;
    var changed = _restoreBlock(value['content_block']);
    if (value['content'] is List) {
      for (final block in value['content']) {
        changed = _restoreBlock(block) || changed;
      }
    }
    return changed;
  }
}
