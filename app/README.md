# 우나보 Flutter 앱

> 초기(10/29 F1) 작업 메모입니다. 채널 수·테스트 안내 등 일부는 그 뒤 바뀌었습니다. 현재 구조는 저장소 README 와 `docs/ARCHITECTURE.md` 를 보세요.

Flutter 3.47.4 stable 기반의 단일 Android/iOS 프로젝트다. Android 패키지와 iOS 앱 bundle ID는 `kr.modumoa.hdapp`이다. Android는 minSdk 28, targetSdk 34, compileSdk 37을 사용한다.

`lib/main.dart`에서 세션을 복원하고 표지 → 로그인/가입 → 방·친구·마이크 탭으로 이동한다. `unavo/device`의 automotive 기능 플래그가 true이면 같은 화면을 `CarShell`로 감싼다. Android/iOS의 기본 음성 엔진은 `flutter_webrtc 1.6.3`을 사용하는 `WebRtcMediaEngine`이다. `NoopMediaEngine`은 테스트 주입과 미지원 플랫폼에 남겨 둔다.

음성은 방에 먼저 입장한 4명까지 풀 메시로 연결한다. `hello.members`의 서버 정렬(`joinedAt`, 동률이면 handle)을 유지하며, 새 통화 참여자가 기존 참여자에게 offer를 보낸다. 동시 offer는 사전순으로 작은 handle이 유지한다. `GET /v1/turn`은 로그인된 사용자의 STUN/TURN 설정을 반환하고, 통화 중 TTL의 80% 시점에 재발급·ICE restart를 수행한다. 서버에는 `TURN_SECRET`, `TURN_REALM`, `TURN_URIS`, `TURN_TTL_SECONDS`를 설정한다. secret이 없으면 STUN만 반환한다.

통화 시작 전에 입력 시험을 종료한다. 네이티브 채널은 포커스·세션·장치 선택·스피커 출력을 관리하고, 통화 녹음은 WebRTC가 담당한다. 네이티브 레벨 미터는 입력 시험에서만 동작하며, 참여자 발화 표시는 WebRTC 수신 통계에서 500ms마다 계산한다. F3 테스트는 작성만 했으며, 실제 송수신·오디오 경로는 메인이 기기로 검증해야 한다.

메인이 실행할 순서:

```sh
cd app
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

F1 작성 중에는 위 네 명령과 Gradle/Xcode 빌드를 실행하지 않았다. 설치를 허용한 Dart 패키지는 `flutter_svg`, `shared_preferences` 두 개다. `any` 제약은 메인의 최초 `pub get`이 SDK에 호환되는 최신 안정판을 선택하게 하며, 생성된 `pubspec.lock`으로 실제 버전을 확인·고정해야 한다. 네이티브 Kotlin에서는 기존 앱에 사용하던 AndroidX Core와 coroutines만 재사용한다.

초기 `flutter create --no-pub --empty --org kr.modumoa --project-name unavo --platforms android,ios app`은 SDK 캐시 쓰기 제한으로 실패했다. 대신 같은 Flutter 3.47.4 스파이크의 생성 파일을 복사하여 프로젝트 이름·식별자·플랫폼 설정을 바꿨다. 빌드 캐시, 생성된 플러그인 등록 파일, 개인 signing team과 기기별 경로는 가져오지 않았다.

기본 서버 주소는 Android `http://10.0.2.2:8787`, iOS `http://127.0.0.1:8787`이다. 실기기는 로그인 화면의 서버 주소 행에서 설정한다. 디버그 빌드는 RFC1918 IPv4 주소의 HTTP도 허용하고, 그 밖의 주소는 HTTPS가 필요하다. 원본 서버에는 토큰 갱신, 내 방 목록, 친구 온라인 상태 API가 없다. 따라서 매 요청·재연결에서 현재 토큰을 읽고, 내 방에는 현재 참여 중인 방을 표시하며, 친구 상태는 확인 가능한 같은 방 여부만 표시한다.

폰 배경은 원본 1080×2400 PNG를 `BoxFit.cover`로 표시한다. 작업 중 갱신된 8b 정본에 맞춰 표지·안쪽·좁은 화면 각각 밤/낮 PNG를 사용한다. 412×915에서는 패널 상단 304dp, 360×780에서는 260dp를 기준으로 하며, 다른 크기에서도 실제 배율·중앙 crop을 반영한 레터링 SVG 경계 +12dp를 보호한다. 작은 화면에서는 내용을 스크롤하며, 키보드가 올라올 때만 패널을 위로 올린다. 첨부된 이전 로그인·통화 이미지보다 안쪽 레터링이 작다. 밤/낮 조작부 팔레트는 같고 배경만 바뀐다.

폰트 라이선스는 저장소의 [Rye OFL](../licenses/fonts/rye/OFL.txt)과 [Black Han Sans OFL](../licenses/fonts/blackhansans/OFL.txt)을 참조한다. Pirata One은 PNG에 구워져 있으며 폰트 파일을 번들하지 않는다.

채널은 `unavo/device`, `unavo/audio`, `unavo/call` 세 종류다. 오디오는 `unavo/audio/levels`, 통화는 `unavo/call/events` EventChannel을 함께 사용한다. Android 알림의 끊기는 비공개 브로드캐스트로 네이티브 통화 상태를 종료하고 Dart `RoomSession.leaveCall`에 전달하여 WebRTC 트랙·피어를 정리한다. 방 멤버십/SSE는 유지된다.
