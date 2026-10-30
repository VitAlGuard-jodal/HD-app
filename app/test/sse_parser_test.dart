import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/net/sse_parser.dart';

void main() {
  test('parsesNamedEventsAndIgnoresPing', () {
    final events = SseParser.parse(
      'event: hello\ndata: {"self":"driver_1"}\n\n: ping\n\nevent: member-joined\ndata: {"handle":"friend_2"}\n\n',
    );
    expect(events, const [
      SseEvent('hello', '{"self":"driver_1"}'),
      SseEvent('member-joined', '{"handle":"friend_2"}'),
    ]);
  });
  test('joinsMultipleDataLinesWithNewline', () {
    final events = SseParser.parse(
      'event: signal\ndata: {\ndata:  "kind": "ice"\ndata: }\n\n',
    );
    expect(events.single, const SseEvent('signal', '{\n "kind": "ice"\n}'));
  });
  test('defaultsNameAndResetsAfterEachEvent', () {
    final events = SseParser.parse('event: hello\ndata: {}\n\ndata: {}\n\n');
    expect(events.map((e) => e.name), ['hello', 'message']);
  });
  test('supportsCrLfUnknownFieldsAndEmptyData', () {
    expect(SseParser.parse('id: 1\r\nretry: 500\r\ndata:\r\n\r\n'), const [
      SseEvent('message', ''),
    ]);
  });
  test('discardsIncompleteEventAtEof', () {
    expect(SseParser.parse('event: signal\ndata: {"partial":true}\n'), isEmpty);
    expect(SseParser.parse(': ping\n\nevent: hello\n\n'), isEmpty);
  });
  test('preservesColonsAndStripsOnlyOneLeadingSpace', () {
    final parser = SseParser();
    expect(parser.accept('event: signal'), isNull);
    expect(parser.accept('data:  {"url":"https://example.test"}'), isNull);
    expect(
      parser.accept(''),
      const SseEvent('signal', ' {"url":"https://example.test"}'),
    );
  });
}
