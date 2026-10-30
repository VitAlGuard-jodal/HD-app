import 'dart:convert';

class SseEvent {
  const SseEvent(this.name, this.data);
  final String name;
  final String data;
  @override
  bool operator ==(Object other) =>
      other is SseEvent && other.name == name && other.data == data;
  @override
  int get hashCode => Object.hash(name, data);
}

// Kotlin 줄 단위 파서와 동일. EOF의 미완성 이벤트는 버린다.
class SseParser {
  String _eventName = 'message';
  final List<String> _dataLines = [];

  SseEvent? accept(String line) {
    if (line.isEmpty) {
      final event = _dataLines.isEmpty
          ? null
          : SseEvent(_eventName, _dataLines.join('\n'));
      _eventName = 'message';
      _dataLines.clear();
      return event;
    }
    if (line.startsWith(':')) return null;
    final separator = line.indexOf(':');
    final field = separator < 0 ? line : line.substring(0, separator);
    var value = separator < 0 ? '' : line.substring(separator + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    switch (field) {
      case 'event':
        _eventName = value.isEmpty ? 'message' : value;
      case 'data':
        _dataLines.add(value);
    }
    return null;
  }

  static List<SseEvent> parse(String text) {
    final parser = SseParser();
    return const LineSplitter()
        .convert(text)
        .map(parser.accept)
        .whereType<SseEvent>()
        .toList();
  }
}
