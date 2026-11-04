final _transportCcLines = RegExp(
  r'^a=(?:rtcp-fb:(?:\d+|\*)[ \t]+transport-cc|'
  r'extmap:\d+(?:/\w+)?[ \t]+'
  r'http://www\.ietf\.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01)'
  r'(?:[ \t][^\r\n]*)?(?:\r?\n|$)',
  multiLine: true,
);

/// Disable transport-wide feedback without rewriting other SDP lines/endings.
String stripTransportCc(String sdp) => sdp.replaceAll(_transportCcLines, '');
