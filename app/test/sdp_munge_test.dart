import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/call/sdp_munge.dart';

const _transportCcUri =
    'http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01';

void main() {
  test('transport-cc feedback와 extmap만 제거하고 CRLF와 다른 줄을 보존한다', () {
    const sdp =
        'v=0\r\n'
        'm=audio 9 UDP/TLS/RTP/SAVPF 111 109\r\n'
        'a=rtpmap:111 opus/48000/2\r\n'
        'a=rtcp-fb:111 transport-cc\r\n'
        'a=rtcp-fb:109 transport-cc\r\n'
        'a=rtcp-fb:* transport-cc\r\n'
        'a=rtcp-fb:111 goog-remb\r\n'
        'a=rtcp-fb:111 nack\r\n'
        'a=extmap:3 $_transportCcUri\r\n'
        'a=extmap:4/sendonly $_transportCcUri custom=1\r\n'
        'a=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level\r\n'
        'a=sendrecv\r\n';
    const expected =
        'v=0\r\n'
        'm=audio 9 UDP/TLS/RTP/SAVPF 111 109\r\n'
        'a=rtpmap:111 opus/48000/2\r\n'
        'a=rtcp-fb:111 goog-remb\r\n'
        'a=rtcp-fb:111 nack\r\n'
        'a=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level\r\n'
        'a=sendrecv\r\n';

    expect(stripTransportCc(sdp), expected);
    expect(stripTransportCc(stripTransportCc(sdp)), expected);
  });

  test('transport-cc가 없거나 비슷한 문자열만 있으면 원문 그대로 반환한다', () {
    for (final sdp in [
      '',
      'v=0\r\na=rtcp-fb:111 goog-remb\r\n\r\na=sendrecv',
      'v=0\na=rtcp-fb:111 nack\na=sendrecv\n',
      'a=rtcp-fb:111 transport-cc-extra\r\n'
          'a=extmap:3 $_transportCcUri-extra\r\n'
          'a=x-note:transport-cc\r\n',
    ]) {
      expect(stripTransportCc(sdp), sdp);
    }
  });

  test('LF 입력과 마지막 개행이 없는 transport-cc 줄도 제거한다', () {
    expect(
      stripTransportCc(
        'a=rtcp-fb:111 transport-cc\n'
        'v=0\n'
        'a=extmap:3 $_transportCcUri',
      ),
      'v=0\n',
    );
    expect(stripTransportCc('a=rtcp-fb:111 transport-cc'), '');
  });
}
