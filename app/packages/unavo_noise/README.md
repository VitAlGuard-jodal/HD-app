# unavo_noise
Android의 flutter_webrtc 캡처 후단에서 RNNoise로 잡음을 제거하는 로컬 플러그인입니다.
RNNoise 출처: https://github.com/xiph/rnnoise v0.2, BSD-3 (`src/rnnoise/COPYING`).
48 kHz·480샘플(10 ms)의 int16 스케일 float 버퍼를 제자리 처리하며 다른 형식은 바이패스합니다.
WebRTC가 전달하는 풀밴드 채널 0만 처리하고 리샘플링은 하지 않습니다.
`getUserMedia` 또는 `createPeerConnection` 이후 `UnavoNoise.setEnabled`를 호출합니다.
`UnavoNoise.status()`로 상태와 누적 프레임 수를 확인하며 로그 태그는 `UNAVO_NOISE`입니다.
앱 기본값은 켜짐이며 `--dart-define=UNAVO_NOISE=off`로 끌 수 있습니다.
iOS는 미구현이며 플러그인이 없는 플랫폼은 `false` / `{'supported': false}`를 반환합니다.
