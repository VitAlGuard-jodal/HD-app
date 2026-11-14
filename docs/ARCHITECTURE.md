# 설계 정본 (2026-10-28)

## 1. 식별 모델 — 아이디가 곧 사람

- `users.handle`: 로그인 아이디. 소문자 영문·숫자·밑줄, 3~20자, 유일. 바꿀 수 없다.
- `users.display_name`: 화면 표시 이름(2~20자). 바꿀 수 있다.
- 비밀번호는 `node:crypto` `scrypt` 로 해시(무작위 16바이트 솔트, N=16384, r=8, p=1, 64바이트).
- 토큰은 무작위 32바이트(base64url). 서버는 SHA-256 해시만 저장. 유효 30일.
- 전화번호·이메일 필드는 없다. 친구·방 초대·시그널링 수신자 지정은 전부 `handle` 로 한다.

## 2. 서버 API (v1, JSON, `Authorization: Bearer <token>`)

| 메서드·경로 | 본문 | 응답 | 비고 |
|---|---|---|---|
| `POST /v1/auth/signup` | `{handle, password, displayName, over14: true}` | `201 {user, token}` | 연령 확인 누락·false는 `400 AGE_REQUIRED`, 중복 아이디 `409` |
| `POST /v1/auth/login` | `{handle, password}` | `200 {user, token}` | 실패 `401` |
| `POST /v1/auth/logout` | — | `204` | 토큰 폐기. 그 토큰으로 열린 SSE 연결도 즉시 닫는다(다른 기기의 토큰은 유지) |
| `GET /v1/me` | — | `{user, room: null 또는 {code, name, createdBy, createdAt, members}, consent}` | `left_at IS NULL`인 방 중 `joined_at`이 가장 최근인 하나(동률은 방 ID 내림차순) |
| `PUT /v1/me/consent` | `{privacy?:{version}, location?:{version}}` | `200 {consent:{privacy:{version,at} 또는 null, location:{version,at} 또는 null}}` | 인증 필수. 하나 이상, 버전 1~8자·공백 불가. 잘못된 본문 `400 INVALID_CONSENT`. 생략 항목 보존 |
| `GET /v1/users/{handle}` | — | `{user}` 공개 정보(handle, displayName) | 없으면 `404`, 아이디 형식이 틀리면 `400` |
| `PATCH /v1/me` | `{displayName}` | `200 {user}` | 표시 이름 변경 |
| `GET /v1/contacts` | — | `{contacts:[user]}` | |
| `POST /v1/contacts` | `{handle}` | `201 {contact}` | 자기 자신·중복 `409` |
| `DELETE /v1/contacts/{handle}` | — | `204` | |
| `POST /v1/rooms` | `{name?, invitees?:[handle]}` | `201 {room}` | 만든 사람은 자동 참여 |
| `GET /v1/rooms/{code}` | — | `{room, members:[{handle, displayName, joinedAt}]}` | |
| `POST /v1/rooms/{code}/join` | — | `200 {room}` | 코드는 대소문자 구분 없이 받아 대문자로 정규화 |
| `POST /v1/rooms/{code}/leave` | — | `204` | |
| `GET /v1/rooms/{code}/events` | — | `text/event-stream` | 아래 이벤트 |
| `POST /v1/rooms/{code}/signal` | `{to: handle, kind, payload}` | `202` | `kind` ∈ offer·answer·ice·custom |

SSE 이벤트(`event:` 이름 / `data:` JSON): `hello{self}`, `member-joined{handle}`, `member-left{handle}`, `signal{from, kind, payload}`, 15초마다 `: ping` 주석.

시그널링을 WebSocket 이 아니라 SSE + POST 로 한 이유: Node 내장 모듈만으로 되고(설치 승인 불필요), 음성 시그널링은 초당 수 건이라 충분하다. WebSocket 으로 바꿀 일이 생기면 이 두 엔드포인트만 교체한다.

저장소는 `node:sqlite`(파일 `server/data/hdapp.sqlite`). 표: `users`, `tokens`, `contacts`, `rooms`, `room_members`.

## 3. 앱 구조 (`android/app`, 패키지 `kr.modumoa.hdapp`)

| 패키지 | 역할 |
|---|---|
| `auth` | 회원가입·로그인 화면, 토큰 보관(`SharedPreferences`, 프로토타입) |
| `net` | `HttpURLConnection` 기반 API 클라이언트, SSE 구독(코루틴) |
| `contacts` | 친구 목록·아이디로 추가 |
| `room` | 방 만들기·코드로 참여·참여자(아이디) 목록. 버튼은 둘로 나눈다: 「통화 참여/통화 끊기」(FGS·마이크만 켜고 끔, 방에는 남음)와 「방 나가기」(서버 leave + 통화 끊기 + 목록으로) |
| `audio` | **마이크 경로 결정**(아래 4절)·입력 레벨 측정 |
| `call` | `CallForegroundService`(FGS 유형 `microphone`, 알림 카테고리 `service`·ongoing — Pleos 에서 `call` 카테고리는 런처 통화 카드로 가고 버튼이 반응하지 않았음), `MediaEngine` 인터페이스 + `NoopMediaEngine` |

빌드: AGP 9.1.0 · Kotlin 2.4.0 · Gradle 9.3.1 · compileSdk 37 · **minSdk 28(Pleos 요구)** · **targetSdk 34(Pleos Connect 에뮬레이터 API 34)** · Compose BOM 2026.09.00 · JDK 17 타깃. 모든 액티비티에 `distractionOptimized=true` 메타데이터(주행 중 가려지지 않게, 에뮬레이터 실측 §8.2).

## 4. 마이크 정책 (`audio.MicRouter`)

1. `PackageManager.hasSystemFeature(FEATURE_AUTOMOTIVE)` 이면 **차량 모드**.
2. `AudioManager.getDevices(GET_DEVICES_INPUTS)` 로 입력 장치를 모은다. Pleos 에뮬레이터 실측 7개: Built-In Mic, Built-In Back Mic, Remote Submix In, FM Tuner, Tone Generator 0·1, Echo-Reference Mic.
3. 후보 순위
   - 차량 모드: `TYPE_BUILTIN_MIC` → (없으면) `TYPE_BLUETOOTH_SCO`·`TYPE_USB_HEADSET`·`TYPE_WIRED_HEADSET` → 나머지. `TYPE_ECHO_REFERENCE`·`TYPE_FM_TUNER`·`TYPE_REMOTE_SUBMIX`·`TYPE_TELEPHONY`·`TYPE_BUS` 는 제외.
   - 폰 모드: `BLUETOOTH_SCO`·`USB_HEADSET`·`WIRED_HEADSET` → `BUILTIN_MIC`.
4. 적용: `AudioManager.mode = MODE_IN_COMMUNICATION`, 오디오 포커스 `GAIN_TRANSIENT`(`USAGE_VOICE_COMMUNICATION`), `AudioRecord(VOICE_COMMUNICATION, 16 kHz, 모노, 16비트)` 에 `setPreferredDevice()` 로 **입력만** 고정한다. 통신(출력) 장치는 플랫폼 기본에 맡긴다 — 에뮬레이터 실측(2026-10-28)에서 `VOICE_COMMUNICATION` 용도만으로 차량 통화 버스 `bus4_call_out` 이 활성화됐고, `setCommunicationDevice()` 는 출력 장치용이라 입력 id 와 짝이 맞지 않는다. 오디오 객체 생성·시작·정지는 메인 스레드가 아니라 IO 디스패처에서 한다(실측 716 ms 멈춤). 통화가 끝나면 전부 되돌린다(`MODE_NORMAL`, 포커스 반납).
5. `AudioDeviceCallback` 으로 장치가 꽂히거나 빠지면 다시 고른다. 사용자가 수동으로 고른 장치는 그 장치가 사라질 때까지 유지한다.
6. 검증용 로그 태그 `HDAUDIO`: `mode=car|phone`, `inputs=[type:name#id,...]`, `chosen=type:name#id`, 100 ms 마다 `rms=NNN`. 장치 이름은 `productName` 에 `address` 가 있으면 덧붙인다(에뮬레이터는 7개 전부 productName 이 "Car on arm64 emulator" 라 id·주소로만 구별된다).
7. 레벨 표시는 dBFS 로그 눈금(−60 dBFS=0, 0 dBFS=1). 마이크 화면에 「마이크 시험」 토글을 두어 통화에 참여하지 않아도 화면이 보이는 동안 입력 레벨을 본다(FGS 없음, 화면을 떠나면 중지).

근거: 에뮬레이터 실측에서 `MODE_IN_COMMUNICATION`·`AUDIOFOCUS_GAIN_TRANSIENT`·마이크 입력·`bus4_call_out` 출력이 모두 동작(2026-10-23 P2). AEC·덕킹은 OEM HAL 몫이라 실차 검증 항목으로 남긴다.

## 5. 통화(미디어) — 보류 중

- 경로: libwebrtc(Android) + Opus 20 ms 모노 + NetEq + 손실 시 FEC + SFU(한국 리전) + TURN + ICE restart. 자세한 근거는 `~/dist/modumoa-group-call-voip/`.
- 지금은 `MediaEngine` 인터페이스(`join(room, self)`, `leave()`, `setMuted()`, `onRemoteSpeaking(handle)`) 와 `NoopMediaEngine` 만 둔다. libwebrtc 의존성 추가는 **Q-4 승인 뒤**.
- 참여 흐름은 "출발 전 보이는 화면에서 참여 → FGS 유지 → 망 바뀌면 자동 재합류" 로 고정(GMS 없음·API 34 마이크 FGS 제한 때문).

## 6. 결정 대기 (태곤 님)

- Q-3 앱 이름·패키지명(`kr.modumoa.hdapp` 임시).
- Q-4 libwebrtc(Android AAR)·SFU 설치 승인.
- 서버 배포 위치(Cloud Run 등)와 TURN 운영 주체.

## 7. 단일 앱·모드 분기·플랫폼 채널 3종 (Flutter F1, 2026-10-29)

앱은 `app/`의 Flutter 단일 프로젝트다. Android applicationId와 iOS bundle ID는 `kr.modumoa.hdapp`이다. 폰 레이아웃을 기본으로 사용하고, Android `FEATURE_AUTOMOTIVE`가 true이면 `DeviceMode.car`로 분기한다. F1의 `CarShell`은 같은 폰 화면을 감싸며 F2에서 차량 레이아웃으로 교체한다. 별도 폰/차량 앱을 만들지 않는다.

Dart는 인증·서버 주소·HTTP/SSE·방 세션·미디어 엔진 인터페이스 및 화면 상태를 소유한다. 상태 관리는 ChangeNotifier, 화면 이동은 기본 Navigator다. HTTP/SSE는 dart:io HttpClient, 영속 저장은 shared_preferences, SVG 아이콘은 flutter_svg를 사용한다. 일반 요청·아바타 다운로드는 `ApiClient` 수명의 HttpClient 하나를 재사용하고 타임아웃은 해당 요청만 abort하거나 본문 구독을 취소하며, SSE는 구독 시도마다 별도 클라이언트를 쓰고 `AppServices.dispose/logout`은 `api.close()`로 공유 클라이언트를 정리한다.

`AppServices.dispose()`는 동기 시그니처를 유지하되 `RoomSession.shutdown()`이 위치 POST→DELETE와 진행 중 follow 정리·SSE 구독 취소를 완료한 뒤 `whenComplete`에서 공유 클라이언트를 한 번 닫으며, 로그아웃 후 다음 요청에서 새 클라이언트를 만드는 규칙은 유지한다.

**화면 구성(M8a).** 통화·방은 앱 수준의 `AppServices.rooms`·`calls`가 소유하며 화면 수명과 분리된다. `RoomScreen.onHome`은 폰에서는 방 route와 그 아래 설정 route를 루트까지 pop하고 홈 탭을 로비로 돌리며, 차량에서는 `_carRoomVisible=false`로 바꾼다. 방 나가기·통화 종료는 호출하지 않는다. 로비의 참여 중인 방 카드와 통화 중 상태 칩을 유지하고 카드에서 기존 `_openRoom`으로 복귀한다. 폰은 새 방 route를 push하고 차량은 `_carRoomVisible=true`로 전환한다.

폰 로비 우상단과 차량 보조 패널 우상단의 `settings` 톱니바퀴가 공용 `SettingsScreen`을 연다. 위에서부터 프로필(`ProfileScreen`), 통화 음량(`RoomSession.setCallVolume`·기존 저장/미디어 경로), 마이크(`MicScreen`), 서버 주소, 약관·동의 문서, 지도 출처(`MapCreditsScreen`), 로그아웃을 둔다. 서버 주소는 현재 `store.baseUrl`을 표시하고 `AuthScreen(serverSettingsOnly: true)`의 기존 서버 필드·주소 검증·저장 경로로 연결한다. 이 경로에서는 로그인/가입을 제출하지 않는다. 정규화 주소의 scheme·host·port가 같으면 저장 후 설정으로 돌아가고, 출처가 다르며 로그인 중이면 기존 주소로 `services.logout()`(통화·공유·방 정리 포함)을 완료한 뒤 새 주소를 저장하여 로그인 화면으로 전환하며, 로그아웃 실패 시 주소·세션을 유지하고 오류를 표시한다. 약관은 `legal_consent.dart`의 `LegalDocumentsScreen`에서 같은 번들 Markdown 렌더러로 읽으며 동의 값을 변경하지 않는다. 로그아웃은 로비에 있던 `services.logout()`과 오류 처리를 그대로 이동한다. 로비에는 프로필·로그아웃·지도 출처 버튼을 두지 않는다. 모든 조작 버튼은 아이콘이고 `ControlScale`로 폰/차량 크기를 맞춘다.

로비의 `restoreSession()`은 `/v1/me`의 401 이외 실패를 2·5·15초 뒤 최대 세 번 재시도하며 매 요청 전 현재 세션·서버·화면 수명과 미참여 상태를 확인하고, 앱 `resumed` 때 로그인 상태에서 복귀 카드와 참여 방이 모두 없으면 진행 중 복원과 중복되지 않게 다시 시도한다.

차량 `CarDashboard`는 주 패널 안에 중첩 `Navigator`를 둔다. 루트 page는 `RoomsScreen`이며 방 또는 설정 page를 그 위에 둔다. 설정에서 여는 프로필·마이크·서버·약관·지도 출처 route도 이 내비게이터에 push한다. 방에서 톱니바퀴를 누르면 방 표시를 내리고 설정을 열며, 프로필 → 뒤로 → 설정 → 뒤로 → 로비 순서로 돌아간다. 중첩 내비게이터의 시스템 뒤로 가기는 `NavigatorPopHandler`로 전달한다. 보조 패널의 마이크 레벨·친구/마이크 선택 상태·플로팅 바는 화면 전환 중에도 같은 위젯 상태로 유지한다.

플랫폼 채널은 세 종류다. `unavo/device`는 automotive/마이크 기능을 조회한다. `unavo/audio`는 기존 Kotlin MicRouter의 장치 선택·자동 복귀·권한·입력 시험·스피커 출력을 연결하고 `unavo/audio/levels`에서 100ms 레벨 상태를 받는다. `unavo/call`은 microphone foreground service를 시작/종료하며 `unavo/call/events`에서 상태·알림 끊기·방 열기 이벤트를 받는다.

Android 입력 시험은 앱 소유 MicRouter가 관리하고 화면 이탈·통화 시작 전에 중지한다. F3 통화 캡처는 WebRTC가 소유하며 FGS는 포커스와 microphone 서비스 수명을 관리한다. iOS도 AVAudioSession을 네이티브 채널이 관리하고 통화 중 AVAudioEngine 미터를 중지한다. 통화 끊기는 미디어·마이크·FGS만 정리하고 방 멤버십/SSE를 유지한다. 방 나가기는 서버 leave까지 수행한다. 알림의 비공개 브로드캐스트는 네이티브 통화 상태를 종료하고 Dart에 WebRTC 정리를 전달한다.

Android SDK는 min 28 / target 34 / compile 37이다. 모든 Flutter 화면은 같은 서버 API와 같은 계정을 사용한다. Android/iOS의 기본 MediaEngine은 F3의 WebRtcMediaEngine이며, Noop은 테스트·미지원 플랫폼용이다. 기존 `android/` Compose 차량 앱의 캡처 구현은 이 변경에 포함하지 않는다.

## 8. 4인 음성 풀 메시와 TURN (Flutter F3, 2026-11-03)

`MeshCoordinator`는 Flutter에 의존하지 않고 피어 생성·SDP 순서·ICE 대기열·정원을 관리한다. 새 통화 참여자가 `hello.members` 및 이후 멤버 갱신의 기존 참여자에게 offer를 보낸다. 기존 참여자는 member-joined에서 offer를 만들지 않는다. 동시 offer는 handle 사전순으로 작은 쪽이 유지하고, 큰 쪽은 피어를 교체해 answer한다. 협상 ID로 늦은 answer·ICE·끊기 이벤트를 구분하며, SDP 이전 ICE는 보관한다. 입장 순서상 첫 4명만 통화할 수 있고 나머지는 기존 통화를 방해하지 않고 대기한다.

`GET /v1/turn`은 인증 후 만료 Unix 초와 handle로 username을 만들고 HMAC-SHA1(secret, username)의 base64 credential을 발급한다. STUN은 자격 없이, TURN은 secret이 있을 때만 제공하며 응답은 no-store다. WebRtcMediaEngine은 TTL의 80% 시점에 설정을 갱신한다. 안정된 피어의 ICE restart는 작은 handle이 제안하고, 응답이 없는 오퍼는 새 피어로 교체해 오래된 TURN 후보가 재전송되지 않게 한다.

로컬은 오디오 트랙 하나를 각 피어에 공유하고, 음소거는 enabled만 바꾼다. 원격 음성은 네이티브 WebRTC 재생을 사용하며 500ms마다 수신 audioLevel > 0.02를 발화로 표시한다. 실제 통신·라우팅과 알림/백그라운드 동작은 실기기 검증 대상이다.

테스트용 ICE 정책 스위치(F5a, 2026-11-04): `--dart-define=UNAVO_ICE_POLICY=relay` 를 주면 PeerConnection 에 `iceTransportPolicy: relay` 를 넣어 TURN 경로를 강제한다. 기본은 `all` 이며 설정 키를 생략한다. 같은 커밋에서 오디오 SDP 의 transport-cc(rtcp-fb 줄과 transport-wide-cc extmap 줄)를 양쪽 SDP 에서 제거한다 — 음성 전용이라 TWCC 대역폭 추정이 필요 없고, 차가 보낸 꼬인 수신 보고가 폰 WebRTC 를 초당 10만 줄 로그로 질식시켜 40초 만에 죽던 문제(iPhone 12 ↔ Pleos, TURN 경로 실측) 를 막는다. iOS 는 WebRTC 로그 수준을 error 로 내린다.

**createOffer 제약 맵(F5c, 2026-11-05).** flutter_webrtc 네이티브의 `createOffer` 제약은 `mandatory` 맵과 `optional` 리스트 아래에 WebRTC 키 이름(`IceRestart`, `OfferToReceiveAudio`, `OfferToReceiveVideo`)으로만 전달되며, 최상위의 `iceRestart`·`offerToReceiveAudio` 같은 키는 iOS·Android 모두 무시한다. `app/lib/call/webrtc_media_engine.dart`의 `offerConstraints`가 이 제약 맵의 단일 출처이며, ICE 재시작을 요청할 때만 `mandatory`에 `IceRestart: true`를 포함한다. 11/5 아이폰 와이파이→LTE 전환 실측에서 최상위 키로는 재시작이 일어나지 않아(로컬 ufrag 불변) 통화가 영구 끊김으로 남았던 결함의 수정이다.

**시그널 백로그와 SSE 침묵 타임아웃(F6a/F6b, 2026-11-06).** 참여자의 데이터가 끊기면 그 SSE 소켓은 서버 쪽에서 한동안 살아 있는 것으로 남아, `hub.sendTo` 가 죽은 소켓에 쓰고도 `delivered:true` 를 돌려준다(11/6 실측: 차 데이터 차단 뒤 서버가 끊김을 안 시각이 2분 뒤). 그래서 서버는 signal 을 수신자별로 60초·64건까지 보관(`RoomEventHub.queueSignal`)하고, 수신자가 events 를 다시 열면 hello 직후 보관분을 순서대로 재전송한다(`replaySignals`). 앱의 `MeshCoordinator.onSignal` 은 negotiationId 로 중복 offer/answer 를 무시하므로 재전송은 안전하다. leave 시 그 수신자 몫은 지운다(`clearSignals`). 앱은 SSE 원시 바이트 침묵 타임아웃을 35초에서 20초(서버 ping 15초 + 여유 5초, `ApiClient.sseSilenceTimeout`)로 줄여 죽은 연결을 더 빨리 다시 연다.

**차량 통화 음량은 CarAudioService 의 CALL 그룹이 정한다(2026-11-06).** Pleos 에뮬레이터 실측: 앱 수신 게인 100%·`STREAM_VOICE_CALL` 5/5 최대인데도 폰→차 소리가 운전 중 듣기엔 작았다. 원인은 그 아래 차량 오디오 서비스의 볼륨 그룹 게인으로, CALL 그룹(`bus4_call_out`)이 기본 −25 dB(45단계 중 20)였다(`dumpsys car_service` 의 `Gain indexes`). 이 값은 앱이 못 쓰고 하드웨어 음량 키로만 움직이며, 통화 중 VOLUME_UP 을 보내면 CALL 그룹만 올라간다(MUSIC 그룹 불변). 25번 보내 45(0 dB)로 올리자 앱 변경 없이 "적당" 판정(태곤 님). 결정: 차에는 추가 게인을 얹지 않는다(휠 음량을 올렸을 때 깨질 수 있음). 시연 전 `app/tool/pleos_call_volume.sh` 로 올린다. 실차의 기본 CALL 음량은 OEM 값이라 확인 필요.

**서버(Lightsail nano) 먹통 2건과 조치(2026-11-06).** 1차 15:56~16:07 KST: 우분투 자동 업데이트(`apt-daily-upgrade`, unattended-upgrades 메모리 피크 147 MB)와 fwupd 가 RAM 412 MB·스왑 0 인 VM 에서 같이 돌아 OOM·스래싱(부하 16~18). HTTPS·SSH·TURN 전부 무응답이었고 OOM 킬러가 두 번 죽인 뒤 돌아왔다. 우나보 서비스는 재시작 0회로 살아 있었다. 2차 16:42~21:30: 1차 스래싱 중 `systemd-networkd` 가 `ens5: Could not set route: Connection timed out → ens5: Failed` 로 인터페이스 관리를 포기해 DHCP 갱신이 멈췄고, 임대가 끝난 16:42 에 주소와 기본 경로가 사라졌다. OS 는 살아서 저널을 계속 썼지만(ssm-agent "network is unreachable") 네트워크만 죽어 상태 점검이 실패했고, 재부팅으로 복구했다. 저널을 보면 fwupd 가 11/3 부터 매시간 ~145 MB 를 할당하다 OOM 으로 죽기를 수십 번 반복한 만성 압박이 깔려 있었다. 조치(결정 2 = A+B, `server/deploy/lightsail/harden.sh`): apt 타이머 2개 disable, `fwupd-refresh` mask, 1 GB 스왑 파일(fstab). 앱에서는 설계대로 SSE 끊김 배너가 떴고, 요청 타임아웃은 Dart `Future.timeout` 기본 문구 "Future not completed" 로 보였다(사용자 문구로 바꿀 항목).

**서버 유휴 데몬 정리(결정 4, 2026-11-09).** 재부팅 뒤에도 유휴 사용량이 412 MB 중 243 MB 라, 이 VM 에서 할 일이 없는 우분투 기본 데몬 셋을 껐다(`harden.sh` C 절): multipathd(다중 경로 저장장치용, `multipath -ll` 대상 0개, RSS 27 MB), ModemManager(모뎀 0개), unattended-upgrades.service(종료 시 진행 중 업데이트를 기다리는 데몬, 타이머를 끈 뒤 용도 없음, RSS 18 MB). 적용 직후 243 → 197 MB, unavo·caddy·coturn 영향 없음. snapd 와 amazon-ssm-agent(합계 약 27 MB)는 Lightsail 브라우저 SSH 의존 여부를 확인하지 못해 남겼다. 부수 관찰: SSH 로그인 때마다 motd 의 `release-upgrade-motd`(check-new-release, 파이썬) 가 약 85 MB 를 잠깐 쓴다 — 로그인 순간에만 생기는 스파이크라 조치 보류.

## 9. 차량 캡처 잡음 제거(RNNoise)와 진단 스위치 (Flutter F7a·F7c, 2026-11-06~09)

**구성.** 안드로이드 전용 플러그인 `app/packages/unavo_noise`(경로 의존성). flutter_webrtc 1.6.3 의 `AudioProcessingController.capturePostProcessing`(WebRTC 캡처 처리 **후단**) 에 `RnnoiseProcessor` 를 붙여 10 ms float32 프레임(int16 스케일)을 RNNoise(`src/rnnoise`, Xiph BSD-3, 사본·라이선스는 `licenses/rnnoise`) 로 처리한다. RNNoise 는 48 kHz·480 프레임만 받으므로 `WebRtcMediaEngine` 이 안드로이드에서 첫 flutter_webrtc 호출로 `WebRTC.initialize(audioSampleRate: 48000)` 을 건다. 어댑터는 뒤늦게 붙은 프로세서에 `initialize` 를 다시 불러 주지 않아 프로세서가 `numFrames*100` 으로 샘플레이트를 자가 인식한다. x86 에뮬레이터 빌드를 위해 상류 헤더를 함께 담고 `src/shim/os_support.h` 로 메모리 함수를 대체한다. 상류의 게인 감쇠 변경(bb18d2f)은 적용하지 않았다(오프라인 하네스: 지연 20 ms, 프레임 경계 클릭 없음, 게인 계단 p95 0.23 dB). iOS 는 같은 훅(`ExternalAudioProcessingDelegate`)이 있어 F7b 에서 같은 구조로 간다.

**스위치(`--dart-define`).** `UNAVO_NOISE=off` RNNoise 끔(프로세서를 떼어냄). `UNAVO_APM=off` getUserMedia 의 echoCancellation·noiseSuppression·autoGainControl 전부 false. `UNAVO_CAPTURE_DUMP=<초>` 캡처 처리 후단 신호를 16-bit PCM 으로 앱 외부 파일 폴더에 저장(`capture-in-*.pcm`, RNNoise 켜져 있으면 `capture-out-*.pcm` 도). 오디오 스레드는 복사·큐 적재만 하고 데몬 writer 가 쓴다. `UNAVO_CAPTURE_EXPORT_PORT=18085` 앱 안 루프백 HTTP 로 덤프를 내보낸다(`/list`, `/file/<이름>`, `/clear`). Pleos 에뮬레이터는 user 빌드·앱은 user 10 이라 adb 가 그 폴더를 못 읽어 이 통로가 필요하다. 회수: `adb forward tcp:18085 tcp:18085` 뒤 `curl http://127.0.0.1:18085/list`. 기본값(전부 미지정)에서는 세 스위치 모두 꺼져 기존 동작과 같다.

**11/9 실측(찌지직 원인).** 폰에서 "말하기 전부터 LP 표면음 같은 찌지직"이 들리던 문제는 RNNoise 도 48 kHz 도 아니었다(끈 빌드·F7a 이전 커밋 빌드 모두 동일). 캡처 덤프와 맥 마이크 동시 녹음을 비교하니 버스트 포락선이 일치했고(상관 0.70), 맥 마이크만 정지 15초=버스트 0, 타자 15초=초당 10.6 으로, **맥북 키보드·손 충격음이 몸체를 타고 내장 마이크로 들어간 것**이었다. 사슬: 충격음 → 에뮬레이터 호스트 오디오 경로 약 +14 dB(APM 을 꺼도 같음) → WebRTC NS 는 히스만 −13 dB → RNNoise 는 바닥을 −86 dBFS 로 지우되 충격음은 음성으로 판정(VAD p50 0.98, 82% > 0.5)해 통과 → 폰 +6 dB(200%). 무음 위에 툭툭만 남아 LP 질감이 된다. 에뮬레이터 캡처 스레드엔 기기 효과 체인이 0개라 처리는 WebRTC 것뿐이다. 조치(결정 6-A): 시연·녹화 중 맥에 손을 대지 않고 맥 입력 음량을 낮춰 피크(−2 dBFS) 여유를 둔다. RNNoise 의 VAD 로는 충격음과 말소리 시작부를 구별하지 못하므로(둘 다 ≈1.0) VAD 기반 충격음 억제는 쓰지 않는다. 측정 도구는 세션 스크래치(`analysis/analyze.py`·`analyze2.py`·`diag-run.sh`)에 있다.

**소프트 바닥(F7d, 결정 7-A′, 2026-11-09).** RNNoise 가 조용한 바닥을 −95 dBFS 까지 지워 "완전한 무음 위의 충격음"이 LP 표면음처럼 들리는 대비를 줄이려고, `SoftFloor.kt` 가 RNNoise 출력에 2 프레임(960 샘플, RNNoise 지연과 동일) 늦춘 입력을 섞는다. 섞는 이득은 `min(0.5, TARGET_RMS/rIn)`(목표 −63 dBFS) 로 입력이 클수록 자동으로 줄고, 내릴 땐 즉시·올릴 땐 프레임당 20% 로 평활해 충격음·말소리가 들어오는 프레임엔 섞이지 않는다. 어택 제한(무음에서 열릴 때 상승 속도 제한)은 실제 캡처 시뮬레이션에서 충격음 감쇠 0·말소리 음절 사이 최대 −16 dB 손상이라 넣지 않았다. 실기기(Pleos 에뮬레이터, 타자 중) 전후: 조용한 프레임 −95.1 → −64.2 dBFS, 말소리 −0.26 dB, 충격음 출력은 소프트 바닥으로 되살아나지 않음(p50 −60.5), 조용 구간 1 ms 포락선 p99−p50 54 → 21 dB. 끄기: `--dart-define=UNAVO_NOISE_FLOOR=off`.

## 10. 통화 안정성 묶음 (F8a·F8b, 2026-11-09 코드리뷰 결함 수정)

**재참여 정책.** 엔진의 `MediaConnectionState.failed` 는 "모든 피어가 failed 이고 복구(ICE restart·재오퍼)가 소진된" 종단 실패에만 쓴다(`receiveConnectionState()` 한 곳에서 판정). TURN 자격 갱신 실패·수신 음량 적용 실패·마이크 선택 실패는 경고(`mediaError`)로만 올리고 기존 피어를 보존한다. `RoomSession` 은 종단 failed 에서만 1·2·4초 재참여를 건다. 이전에는 자격 갱신 타임아웃 하나로 멀쩡한 메시를 전부 허물었다.

**offer 시한과 돌아온 쪽의 재제안.** `meshOfferTimeout = 8초` 안에 answer 가 없으면 피어를 닫고 새 negotiationId 로 재오퍼(간격 8·16·24초, 최대 3회, 56초에 종단 실패). `MeshCoordinator.reconcile(members)` 는 살아 있는 피어도 진행 중 협상도 없는 상대에게 **새 멤버 규칙과 무관하게** offer 를 보낸다. `RoomSession` 은 SSE 재접속 뒤 `Hello`·`Reconnected` 에서 이미 미디어에 참여한 경우 `mediaEngine.reconcilePeers()` 를 부른다. 11/9 실측(상대 SSE 가 내려간 사이 보낸 offer 유실 → 양쪽 영구 대기)의 수정이다. 글레어는 기존 규칙(사전순으로 작은 handle 이 자기 offer 유지·재전송)대로.

**복귀 정책(태곤 님 결정 11/9).** 프로세스가 살아 있는 채 통신만 끊겼다 돌아오면(터널) 같은 방에 자동 재입장하고 통화를 잇는다(위 reconcile). 앱을 **새로 켠 경우**(사용자가 끈 것이든 시스템이 죽인 것이든)는 메인 화면에 머물고 마이크·통화를 자동으로 켜지 않는다. `restoreSession` 은 `/v1/me` 를 읽어 `RoomSession.restorableRoom` 에 두고, 폰 방 목록·차 대시보드가 "참여 중인 방" 카드(방 이름·코드 + 입장 아이콘) 한 장을 보여 준다. 카드 탭 → 기존 입장 경로(`open` → hello → 자동 통화). `AppServices.initialize()` 의 네이티브 통화 상태 기반 자동 open 도 제거했다.

**수신 이득 상한 100%.** libwebrtc 는 수신 볼륨을 saturated cast 로 곱하므로 ×2.0 이면 −6 dBFS 위 샘플이 전부 잘리고, 차 송신 피크는 0 dBFS 로 실측됐다. `callVolume` 0~100(저장값 200 은 읽을 때 100), 슬라이더 max 100, 엔진 `_playbackVolume ≤ 1.0`. 소리 크기는 출력 경로(스피커/수화부) 결함을 고쳐 확보한다(묶음 2).

**타임아웃 문구.** `api_client.dart` 의 모든 `.timeout` 에 `onTimeout` 을 주어 `ApiException(0,'timeout','서버 응답 없음')` 을 던진다("Future not completed" 제거).

**안드로이드 오디오 포커스·FGS.** 영구 `AUDIOFOCUS_LOSS` 는 캡처 해제 + "다른 오디오가 우선되어 통화가 중단되었습니다" 로 통화 종료(이전 동작 복원), `LOSS_TRANSIENT`/`CAN_DUCK` 은 `isInterrupted` 로 올려 폰·차 내 카드에 마이크 꺼짐 아이콘과 "다른 오디오 때문에 잠시 중단" 을 표시한다. `CallForegroundService` 는 출력 경로 전환 실패를 `outputError` 로만 보고하고 통화를 시작하며, 통화 중 마이크 경로 오류는 1초 뒤 한 번 재적용하고 재실패 시 깨끗이 종료한다(열화 상태 지속 금지).

**서버.** `RoomEventHub` 가 30초 주기(`unref`)로 만료된 시그널 백로그를 전역 스윕한다(이전엔 같은 수신자를 다시 만질 때만 정리돼 복귀 없는 사용자마다 최대 64건이 영구 잔류). `GET /v1/rooms/:code` 는 `publicRoom + listRoomMembers` 로 응답을 직접 구성한다(바이트 동일).

**테스트 주의(F8c).** 위젯 테스트에서 `pumpAndSettle` 은 주기 타이머(SSE·자격 갱신·재오퍼·애니메이션) 때문에 끝나지 않는다 — 고정 `pump` 만 쓴다. 가짜 MethodChannel 핸들러 **안**에서 `expect` 를 호출하면 실패가 호출 쪽 catchError 에 삼켜져 테스트에 드러나지 않는다 — 핸들러는 기록만 하고 본문에서 검증한다. 각 testWidgets 에 30초 timeout.

## 11. 잡음 제거 방향 (결정 9-A, 2026-11-09)

**RNNoise 는 기본값에서 끈다**(`UNAVO_NOISE` 기본 `off`, 플러그인·스위치는 실험용으로 유지). 근거: 11/9 실기기 캡처에서 RNNoise 가 사용자의 생목소리 프레임 56% 를 잡음으로 판정(VAD<0.5)해 32~46 dB 깎았고(TTS 음성은 0 dB 통과), 폰에서 "말하는데 아무 소리도 안 들림"의 직접 원인이었다. 기기 출력과 오프라인 RNNoise 출력이 0.1 dB 차이로 같아 구현 결함이 아니라 모델 판정이다. 원인 후보(WebRTC NS 선처리와의 이중 처리·낮은 SNR·마이크 거리)는 가르지 않았다.

**기본 체인** = WebRTC 내장 처리(에코 제거·잡음 억제·자동 이득). 완료 기준은 블루투스 핸즈프리 통화급(상대 말소리 지연·끊김 없음, 말 안 할 때 거슬리는 소리 없음). 기준을 넘으면 잡음 트랙은 종료하고, 새 잡음 변수가 떠올라도 소거법으로 확장하지 않는다. 부족하다고 판단될 때만 ① 캡처 A(WebRTC 처리 끔 + RNNoise)로 이중 처리 가설 확인 → ② 같은 훅에서 GTCRN(초소형·MIT) / DeepFilterNet3(지연 +40 ms·연산 9배) 를 캡처 도구로 "목소리 보존 0 dB·바닥 감쇠" 수치 비교해 이기는 것만 채택. 기획서 문구는 "WebRTC 표준 잡음 억제 적용, 학습형 모델은 실험 모듈로 탑재".

**시연 환경(결정 6-A).** 찌지직의 실제 음원은 맥북 키보드·손·쿨링팬 충격음이 몸체를 타고 내장 마이크로 들어간 것. 시연·녹화 중 맥에 손을 대지 않고 맥 입력 음량을 낮춰 피크(실측 0 dBFS)에 여유를 둔다. 같은 방에 폰과 차를 두면 에코 제거기가 자기 목소리를 에코로 지워(26~43 dB) 음질 판단이 왜곡되므로, 음질 시험은 폰 마이크 음소거 또는 다른 방에서 한다.

## 12. 위치 공유·참여자별 궤적(M6·M7)

**식별.** `leader`/`RoomSession.leaderHandle`은 방을 만든 사람의 handle이다. 따라갈 대상은 방장과 무관한 `followTarget`이며 자기 자신은 따를 수 없다. 서버·앱은 함께 배포하는 follow 프로토콜 v2를 사용한다(§15). 이전 클라이언트 호환은 제공하지 않는다.

| 메서드·경로 | 본문 / 응답 | 규칙 |
|---|---|---|
| `POST /v1/rooms/:code/location` | `{stream,lat,lng,acc?,speed?,heading?,at,seq}` → `202 {accepted:true,dropped}` | 멤버만, handle은 인증 사용자, receivedAt은 서버 시각. 잘못된 표본 400, 간격 제한 429 |
| `GET /v1/rooms/:code/positions` | `{positions:[LocationFix],trails:{followTarget:[LocationFix]},revision}` | 멤버만, `Cache-Control: no-store`. 전체 최신 위치와 수신자의 수락된 대상 궤적만 |
| `DELETE /v1/rooms/:code/location` | `202 {accepted:true}` | 내 위치·양방향 follow·pending을 즉시 정리. 무변경 반복 삭제는 방송하지 않음 |

`LocationFix`는 `{handle,stream,lat,lng,acc?,speed?,heading?,at,seq,receivedAt}`다. 위도 −90~90, 경도 −180~180, acc/speed ≥ 0, heading 0~360, at ≥ 0을 유한수로 검사한다. `seq`는 `Number.isSafeInteger(seq) && seq >= 0`, 범위 0~9,007,199,254,740,991이고 stream은 16자리 소문자 hex다. handle별 400ms 최소 간격과 `(handle,stream)`별 seq 중복·역순 드롭을 유지한다. stream 변경으로 간격 제한을 우회할 수 없다. 앱 파서는 num을 검사하고 안전 정수를 int로 변환한다. 잘못된 location/hello/trail 표본 하나는 건너뛰며 다른 표본·통화 시그널과 SSE 연결은 유지한다. 원문·좌표 없이 프로세스당 한 번만 파싱 경고를 기록한다.

**메모리 저장소·revision.** 방별 최신 위치 1건/handle, 수락 관계(`accepted`, `followers`), 대기 요청(`pendingRequests`), 공유 중인 handle, 궤적, 마지막 seq·수신 시각과 `disconnectedAt`을 보관한다. 요청자는 한 대상만 요청하거나 따른다. 대기 요청은 팔로워가 아니며 궤적을 만들지 않는다. 수락된 첫 팔로워부터 대상의 현재 위치를 시작점으로 궤적을 만들고 최대 7,200점만 보관한다. 마지막 팔로워 해제 때 그 대상 궤적을 삭제한다. 방의 위치·관계·공유·단절/복귀·멤버 상태 변경마다 revision을 증가시키며, 중복 표본·무변경 follow 재요청·무변경 삭제는 증가시키지 않는다. 스냅샷은 내부 저장소와 분리된 사본이다.

**공유 수명·단절 유예(M7).** 마지막 SSE 소켓이 닫히면 DB 멤버십과 위치·follow·pending·궤적을 유지한 채 `disconnectedAt`을 기록하고 `LOCATION_DISCONNECT_GRACE_MS = 30초` 타이머를 시작한다. 같은 handle이 재구독하면 연장된 타이머도 취소하고 hello로 최신 상태를 복원한다. 다른 소켓이 남아 있으면 유예도 시작하지 않는다. 유예 만료 시 소켓이 없어도 `isSharing(code,handle)`이 참이고 마지막 위치 수신 `lastReceivedAt`부터 `LOCATION_STALE_MS = 90초` 미만이면 30초 유예를 다시 건다. 따라서 SSE가 끊겨도 위치 POST가 계속 수신되면 공유·follow·궤적을 유지한다. 위치까지 끊긴 공유자는 아래의 기존 stale sweep이 정리한다. 공유하지 않거나 현재 공유의 표본을 받은 적 없는 멤버는 기존대로 30초 뒤 `removeLocation(...,'left')`로 정리한다. 중지 후 속도 제한용으로 남은 수신 시각은 새 공유의 수신으로 보지 않는다. 만료 콜백은 기존 타이머와 빈 방 맵을 먼저 제거한 뒤 필요할 때 한 개만 다시 등록한다.

명시적 공유 중지·leave·로그아웃은 연장된 유예도 취소하고 즉시 정리한다. 마지막 멤버 leave는 방·위치·궤적·순번·시그널 백로그·유예 타이머를 삭제하며 서버 종료 때도 모든 유예를 취소한다. `/leave`는 현재·전 멤버에게 204, 한 번도 속하지 않은 사용자에게 403이며 이미 삭제된 방은 404다.

**stale 만료.** 마지막 저장 표본의 서버 receivedAt부터 `LOCATION_STALE_MS = 90초`가 지나면 snapshot/positions/hello에서 제외한다. 30초 주기 단일 sweep이 만료된 handle의 위치·궤적·관계를 삭제하고 `location-stopped {handle,reason:'stale',revision}` 및 해당 요청 ID의 종료 응답을 보낸다. 조회 경로도 만료 정리를 실행하므로 sweep 직전에도 오래된 위치를 노출하지 않는다. 위치·follow는 SQLite나 디스크에 저장하지 않으며 서버 프로세스 재시작으로 사라진다. 위치 POST는 개별 액세스 로그 없이 방별 분당 건수만 집계한다.

**앱 전송·취소 토큰.** 기능별 동의는 화면에서 받고 `LocationShare.start({required Object token, required bool Function() stillValid})`를 호출한다. 권한 요청 직전·권한 완료 후·watch 직전에 요청 유효성을 재검사한다. 모달 진입부터 토큰을 관리하며 수신 요청은 requestId, 송신 요청은 POST 결과의 requestId와 연결한다. FollowCancelled·MemberLeft·방 변경은 토큰을 무효화한다. 이번 요청이 새로 켠 공유는 즉시 stop하고, 이전부터 켜져 있던 공유는 유지한다. 수락 완료 후에는 요청 토큰에서 공유를 분리한다. pending 송신 요청은 수락 전까지 토큰을 유지한다. 기능별 동의 기록만으로 새 프로세스에서 GPS·공유를 자동 시작하지 않는다.

권한 거부는 “위치 권한이 없습니다”, 서비스 꺼짐은 “위치 서비스가 꺼져 있습니다”로 표시한다. 기본 전송은 1초이며 최신 표본 하나만 보류한다. speed < 0.5m/s·이동 < 3m이거나 연속 전송 실패 3회면 5초 간격이다. seq와 stream은 같은 실행의 중지·재시작·방 변경에도 유지한다. 송신자에게 location SSE를 반사하지 않으므로 성공한 자기 표본은 세션에서 직접 반영한다.

**차량 위치 출처(D2·접수양식 v3 ④).** `AppServices`의 기본 `VehicleLocationSource`는 폰에서 기존 geolocator만 사용하고, 차량에서 `unavo/location`의 `prepare`와 `unavo/location/events`를 통해 Pleos `FusedLocation:1.1.3`을 사용한다. 기존 기능 동의 모달 뒤 `LocationShare.start()`의 `source.requestPermission()` 안에서 geolocator 권한을 먼저 준비하고, Automotive일 때만 `FusedLocation.isSupported()` → `pleos.car.permission.FUSED_LOCATION` 런타임 요청 → `initialize()`를 실행한다. Android 위치 권한이 없더라도 Pleos 권한이 있으면 차량 출처는 사용할 수 있다. 두 권한 요청은 순차적이며 새 동의 모달·문구를 만들지 않는다. 미지원·초기화/권한 실패·채널 없음은 geolocator로 대체한다. SDK 스트림 오류·종료도 먼저 unregister하고 기존에 받은 권한으로만 대체하며, 통화 중 새 권한창을 띄우지 않는다. 취소 중에는 대체 구독도 새로 열지 않는다.

`LocationChannel`은 SDK를 차량에서만 생성하고, `onChanged(LocationData?)`의 null은 무시하며 `onError(Exception)`는 대체 신호로 전달한다. 위도·경도·heading·altitude·confidence·`timestampMillis`를 표본에 옮긴다. confidence의 단위는 문서가 보장하지 않으므로 metre accuracy(`acc`)로 보내지 않는다. 서버 계약은 그대로 두고 altitude/confidence는 로컬 표본에만 둔다. `timestampMillis`는 `LocationSample.at` → POST `at` → 지도 궤적과 음성 지연 판정까지 보존한다. 동일·역행 측정 시각은 버리고, 새 구독의 첫 표본 속도는 null, 다음 표본부터 구면 거리/측정 시간으로 m/s를 계산한다. 10초를 넘는 간격은 현재 속도를 보장하지 않아 null로 둔다. `RoomDirectionTracker`의 3m 이동·1.5m/s·45도·heading 20% 보정 규칙은 그대로다.

공유 중지·퇴장은 EventChannel cancel → `unregisterFusedLocationCallback`이다. SDK는 공유마다 release하지 않고 FlutterEngine 종료 때 unregister 후 release한다. 로그 태그는 `unavo-location`이며 source·register/unregister·측정 timestampMillis·대체 사유를 남기고 좌표는 남기지 않는다. `showLocationAccessBlockedPopup()`은 호출하지 않는다. 현재 공개 `Exception`/null 콜백만으로 차량 개인정보 설정 차단과 GPS 부재·권한 거부를 확정 구별할 수 없기 때문이다. FusedLocation은 geolocator의 위치 FGS/알림을 실행하지 않으므로 SDK 서비스의 배경 지속·시스템 위치 표시기는 에뮬레이터/차량 검증 대상이다.

**따라가기 음성(D2·접수양식 v3 ②).** `RoomSession`은 화면의 기존 follow notice를 그대로 남기고 `FollowVoiceGuidance`에 상태를 별도 전달한다. 차량의 수락된 따라가기만 대상이다. `stopped`는 “○○ 님이 위치 공유를 끝냈습니다”, `stale`은 “○○ 님 위치가 잠시 갱신되지 않고 있습니다”로 구별하며 이름은 `displayNameOf`를 사용한다. 서버에는 이미 receivedAt 기준 90초 stale 판정이 있지만 앱에 측정 시각 기반 조기 타이머는 없었다. 같은 90초를 재사용해 최신 `at` 이후 90초(첫 표본이 없으면 따라가기 시작 후 90초)에도 지연을 한 번 알린다. 이후 서버 stale 종료와 중복하지 않으며, fresh 표본이 돌아오면 지연 상태·대기/재생 안내를 지우고 다음 지연 전이만 다시 알린다. 복구 문장은 생략한다. `left`·`requester-stale`·거절을 상대의 명시적 공유 중지로 말하지 않는다. 화면 문구·지도·서버 stale 종료 규칙은 변경하지 않는다.

음성은 현재 발화 뒤 최대 1개의 최신 상태를 대기시킨다. 동일 대상/사건은 상태 전이마다 한 번, 10초가 지난 대기는 폐기하며 native에서도 초기화 후 유효기간을 재검사한다. 새 대상 선택·따라가기 중지·내 공유 중지·퇴장 시 타이머·대기를 지우고 stop한다. `unavo/tts`의 Kotlin `TtsChannel`은 첫 안내에서만 `TextToSpeech(context, Mode.ON_DEVICE)` → `initialize(OnInitializeListener)` → `setLocale(Locale.KOREA)` → `setAudioAttributes` → `speak`를 수행한다. registerApp은 호출하지 않는다. ErrorType·초기화 실패는 로그와 해당 안내 폐기로 끝나며 화면·통화에는 오류를 전파하지 않는다. 로그 태그 `unavo-tts`에 speak/onStart/onDone/onError/onStop을 남기고 표시 이름·문장 원문은 기록하지 않는다. 초기화 8초, 발화 15초, stop 응답 2초의 상한을 두며 초기화/stop 콜백이 아직 끝나지 않으면 SDK를 조기 release하지 않는다. 콜백이 영원히 없으면 인스턴스는 종료 콜백 또는 프로세스 종료까지 남고 이후 안내는 중단한다.

TTS는 NAVIGATION(`USAGE_ASSISTANCE_NAVIGATION_GUIDANCE`)/SPEECH와 `AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK`을 사용하며 완료·중지·오류에 포커스를 반납한다. 포커스를 받지 못하면 안내를 생략한다. 통화의 MODE_IN_COMMUNICATION·라우팅·음량은 바꾸지 않는다. 차량 MicRouter는 CAN_DUCK만으로 WebRTC를 mute하지 않고 HAL 동시 재생 정책을 따른다(LOSS/LOSS_TRANSIENT 처리는 유지). [Pleos 오디오 가이드](https://document.pleos.ai/docs/pleos-only/vehicle-app-developer-guide/audio-focus-development-guide/audio-focus-development)의 동시 재생 요청 방식과 [선행 묵음 가이드](https://document.pleos.ai/docs/pleos-only/vehicle-app-developer-guide/voice-guidance-preroll-silence-guide)를 적용했다. 공개 SDK는 PCM/무음 패딩 API를 제공하지 않아 포커스 획득 후 180ms 재생 지연만 둔다. 이는 실제 PCM 선행 묵음을 보장하지 않으며 SDK 서비스 내부 패딩·첫 음절·통화 중 가청성·CALL/NAVIGATION 믹싱은 실청해야 한다.

D2 네이티브 의존성은 Pleos 공개 Maven 저장소의 `TextToSpeech:3.3.1`·`FusedLocation:1.1.3` 두 개뿐이다(전이 의존성 제외). TTS_SERVICE·FUSED_LOCATION을 선언하고, FusedLocation AAR의 Automotive required=true가 폰 설치를 막지 않도록 앱의 required=false에 `tools:replace="android:required"`를 둔다. SDK의 binding 권한·queries는 AAR 병합에 맡긴다. iOS·pubspec·서버는 변경하지 않는다. D2 Dart 검증 파일은 `follow_voice_guidance_test.dart`, `vehicle_location_source_test.dart`, `room_session_location_test.dart`이며 실행·Gradle 빌드·병합 매니페스트 확인은 메인이 수행한다.

**배경 전송(M7, 결정 18-A).** 사용자가 기능별 동의 후 화면에서 공유를 켠 동안에는 잠금·앱 전환 뒤에도 위치 전송을 이어 간다. iOS는 “앱 사용 중” 권한으로 시작한 스트림에 `allowBackgroundLocationUpdates: true`, `showBackgroundLocationIndicator: true`, `pauseLocationUpdatesAutomatically: false`를 적용한다. Info.plist의 `UIBackgroundModes`는 기존 `audio`와 `location`이며 “항상 허용” 권한을 요구하지 않는다. 시스템 위치 표시기를 켜고 Xcode 프로젝트 파일은 변경하지 않는다.

Android의 geolocator 경로(폰 및 차량 SDK 대체)는 공유 스트림에만 `ForegroundNotificationConfig`를 전달한다. 위치용 포그라운드 서비스와 “우나보 위치 공유 중” 알림을 사용하며 본문은 “같은 방 참여자에게 내 위치를 보내고 있습니다”다. `setOngoing: true`, `enableWakeLock: true`, 기존 `drawable/ic_notification_small` 아이콘을 사용한다. targetSdk 34용 `FOREGROUND_SERVICE_LOCATION`과 wake lock용 `WAKE_LOCK`을 선언하고, 기존 `POST_NOTIFICATIONS` 권한 흐름을 유지하며 `ACCESS_BACKGROUND_LOCATION`은 추가하지 않는다. geolocator_android 5.2.1의 서비스 타입은 `location`, 알림 ID/채널은 `75415`/`geolocator_channel_01`이다. 통화 서비스의 `microphone`, `1`/`call`과 분리되어 통화·공유 동시 실행 시 알림도 각각 게시된다. 실제 알림 표시와 Pleos 차량 UI는 기기 확인 대상이다.

위치 스트림은 `LocationShare.start()`에서만 열고 `stop()`에서 구독을 취소한다. 공유 중지·방 나가기 때 네이티브 위치 갱신과 iOS 표시기·Android 포그라운드 알림·wake lock도 종료하는 경로를 사용한다. 앱 재실행이나 저장된 동의만으로 배경 공유를 시작하지 않는다.

**공유 중지·삭제 재시도.** stop은 로컬 GPS·보류 타이머·과거 위치 오류를 즉시 지운다. 삭제 작업은 `(code,handle,generation)`으로 보존하고 진행 중 위치 POST 뒤에 DELETE를 보낸다. 실패 시 1·2·4·8·16·32·60초(이후 최대 60초) 간격으로 재시도한다. 같은 방을 떠나거나 인증/멤버/방이 없어진 401·403·404이면 재시도를 중단한다. 새 공유는 이미 전송된 이전 DELETE 완료를 기다린 뒤 오래된 작업과 타이머를 폐기하므로 이전 세대 삭제가 새 공유 뒤에 실행되지 않는다. 삭제 대기는 `deletionPending`/`deletionStatus`의 “위치 삭제 대기 중”으로 표시하며 `LocationShare.error`와 분리한다. 방 변경도 과거 오류를 지운다.

퇴장 시도는 `canStart`로 새 공유만 차단하고 실제 `roomCode`는 유지하므로 DELETE와 leave가 모두 실패하면 삭제 재시도가 남으며, leave 성공으로 방 코드가 비워지거나 DELETE가 401·403·404를 반환하면 작업을 정리한다.

`leave()`/`forget()`은 `mediaEngine.leave()`와 `callService.stop()`을 먼저 호출하고 UI를 통화 종료 상태로 전환한다. 위치 POST→DELETE 완료는 그 뒤 기다리므로 위치 네트워크 지연이 마이크·오디오 종료를 늦추지 않는다. 같은 프로세스의 SSE 복귀는 hello의 수락 대상·pending 대상·수신 요청·revision으로 복원한다. 진행 중 follow POST와 오래된 hello, 먼저 도착한 SSE 응답의 순서 조정은 §15를 따른다.

**정차 규칙(D1·접수양식 v3 ①).** 차량의 `RoomSession.followNeedsStop`은 전역 주행 잠금과 같은 `AppServices.driving` 인스턴스의 `DrivingState.restricted`를 읽는다. `CarUxRestrictions.isRequiresDistractionOptimization()`에서 온 제한이 true이면 동의 모달 진입과 따라가기 시작을 막고 “정차 후 설정할 수 있습니다”를 표시한다. false이면 GPS 이동 상태와 무관하게 허용한다. 동의·위치 공유 시작 후 `startFollowing()`에서도 다시 확인한다. 폰에는 정차 제한이 없다.

주행 제한을 아직 받지 못했거나 사용할 수 없는 경우는 §17의 전역 잠금과 똑같이 `restricted=false`여서 허용한다. unavailable·잘못된 이벤트·채널 오류·스트림 종료 역시 같은 `DrivingState`에서 false로 정리한다. GPS의 `LocationShare.motionState`(최근 3초 창·0.5m/s·3m 기준)는 위치 기능에 남기되 따라가기 허용/취소 근거로 쓰지 않는다. unknown에서 시작한 뒤 첫 moving 표본 때문에 follow를 취소하던 경로는 제거했다. 이미 시작한 따라가기·위치 전송·궤적·통화는 이후 주행 잠금이나 GPS 이동에도 유지하며 중지는 기존 정리 경로를 따른다.

**동의 체계(결정 16-A·M7·M10·D1·D1b).** 첫 전체 동의 화면은 로그인한 계정의 필수 개인정보 서버 기록만으로 판정한다. 로그인·가입 성공 후와 저장 세션 복원 시 `GET /v1/me`의 `consent.privacy.version`을 `legalVersion = '3'`과 비교한다. 개인정보가 현재 버전이면 로비로 가고, null·누락·이전 버전이면 폰/차량 공용 `LegalConsentScreen`을 표시한다. 선택 항목인 위치의 서버 기록 유무·버전은 이 판정에 쓰지 않는다. 전체 동의는 첫 로그인에서 한 번 받고 개인정보 버전이 바뀌면 다시 받으며, 기능 동의는 켤 때마다 받는다. 새 세션의 동의 조회 중에는 입장과 알림의 방 열기를 보류한다. 기존 2·5·15초 재시도 후에도 조회하지 못하면 로그인은 보존하되 확인 실패 안내와 `legal-retry` 아이콘으로 수동 재조회하게 한다. 오프라인 새 실행을 로컬 동의로 통과시키지 않는다.

`SessionStore`는 GET 조회와 명시적 수락 PUT의 서버 응답을 메모리에만 보관한다. 동의용 SharedPreferences 키를 새로 만들지 않으며 옛 기기 키 `legal.consent.v1`는 읽거나 쓰거나 서버로 이관하지 않는다. 로그아웃·토큰/계정 변경·서버 출처(scheme/host/port) 변경 시 메모리 동의를 초기화하고 `sessionRevision`을 바꾼다. 이전 계정의 늦은 GET/PUT 응답은 적용하지 않는다. 같은 세션에서도 명시적 PUT보다 먼저 시작한 GET이 늦게 도착하면 새 수락 결과를 덮어쓰지 않는다. A 동의 → 로그아웃 → B 로그인은 B 기록을 새로 조회하고, A 재로그인은 A의 서버 동의를 다시 조회한다.

수락은 체크한 항목의 현재 버전으로 `PUT /v1/me/consent`를 보내고, 서버 응답의 해당 버전까지 확인한 뒤에만 다음 화면으로 이동한다. 대기 중에는 체크/제출을 막고, 실패하면 동의 화면과 선택을 유지하면서 오류를 표시하고 다시 제출할 수 있게 한다. 기존 필수 개인정보/선택 위치 문구와 차량 두 열 배치는 유지한다. 위치를 선택하지 않으면 개인정보만 전송하고 위치 동의를 새로 기록하지 않으며, 성공 후 통화·방 목록에 들어갈 수 있다. 이후 같은 계정의 로그인·복원에서도 서버 개인정보가 현재 버전이면 위치 기록 없이 전체 동의 화면을 건너뛴다. 미동의는 기존 안내·로그아웃 경로다.

가입 화면은 만 14세 이상 확인만 별도로 받는다. `over14: true`를 서버가 검사하고 계정 생성과 함께 `users.age_confirmed_at`을 기록한다. 가입 화면에는 개인정보·위치 문서 동의가 없으므로 가입 직후 전체 동의 화면에서 문서 동의를 한 번 받으며 나이를 재확인하지 않는다. 서버의 기존 `GET /v1/me`·`PUT /v1/me/consent` 계약과 DB는 변경하지 않는다. 문서 버전은 추천 경로 제공 항목을 추가한 2026-11-15 버전 4이며 책임자는 「우나보 팀 개인정보 담당」·이메일, 공개는 앱 안 「약관·동의 문서」 화면이다.

위치 항목을 선택하지 않았어도 §15의 따라가기·요청 수락 모달은 매 새 기능 시작 때 기존처럼 표시한다. 명시적 기능 동의 뒤 위치 버전 4를 해당 계정으로 기록하는 PUT의 성공을 기다린다. 같은 계정 세션의 개인정보·위치 v4 응답을 확인한 뒤 권한 요청·공유·follow를 시작하며, 기록 실패는 기능 시작을 차단하고 재시도할 수 있다. 기기 단위 동의 저장은 사용하지 않는다. 문서 동의만으로 공유를 자동 시작하지 않는다. 문서·요약·송수신 대화상자는 추천 경로 제공 조건을 함께 설명한다.

참여자 `_refresh`가 현재 조회·멤버 세대의 적용까지 성공하면 SSE 연결 상태(`isConnected=true`)에서만 `state.error`를 지우며, SSE 미연결 중에는 재접속 안내를 유지한다.

## 13. 지도 화면(M2·M3·M5a·C2·C3)

초기 M1의 데이터 통로에 실제 GPS와 지도 공급원 경계를 연결한다. 동의 UI와 수명은 §12·§14·§15를 따른다.

**공급원 선택(M3).** `app/lib/map/map_provider.dart`의 순수 함수 `selectMapProvider()`와 `mapProviderFromEnvironment()`가 `MapProvider.naver` / `vworld`를 고른다. `auto`는 `NAVER_CLIENT_ID`가 비어 있지 않으면 네이버, 없거나 공백이면 브이월드다. 브이월드 키도 없으면 M2의 타일 없는 단색 바탕을 유지한다. 명시적인 `naver` / `vworld`는 키 유무보다 우선하며, 빈 키의 명시적 네이버 선택은 SDK의 인증 오류로 표시한다. 공급원 문자열의 공백·대소문자는 정규화하고 알 수 없는 값은 auto로 처리한다. `AppServices.mapProvider`는 이 선택을 기본으로 쓰며 테스트에서 주입할 수 있다. 기존 AppServices 테스트는 브이월드를 명시해 네이티브 지도 위젯을 만들지 않는다.

**초기화 순서.** `main()`에서 `WidgetsFlutterBinding.ensureInitialized()` → 서비스 생성과 공급원 선택 → 네이버일 때만 `await FlutterNaverMap().init(clientId: naverClientId, onAuthFailed: ...)` → 기존 플랫폼 서비스 초기화 → `runApp` 순서다. 첫 NaverMap보다 SDK 초기화가 먼저 완료된다. `NAVER_CLIENT_ID`는 빌드 define에서만 읽고 코드·테스트·문서에 실제 인증값을 두지 않는다. 인증 실패는 메시지에서 인증값을 가린 뒤 debugPrint하고 `AppServices.mapAuthError`에는 오류 코드만 넣는다. 코드는 RoomScreen의 기존 오류 영역과 지도 상단 한 줄에 표시한다. init 자체가 예외를 던지면 키·예외 본문 없이 한 줄만 기록하고 runApp 전에 브이월드로 전환한다. 출처 화면도 최종 선택된 공급원을 사용한다.

**브이월드 타일 설정.** `app/lib/map/map_tiles.dart`의 `MapTiles.fromEnvironment()`가 `--dart-define`을 읽으며 `fromDefines()`로 같은 파싱을 단위 검증한다. 실제 키는 앱 코드에 넣지 않는다.

| define | 기본값 / 규칙 |
|---|---|
| `UNAVO_MAP_PROVIDER` | `auto`. `naver` / `vworld` / `auto` |
| `NAVER_CLIENT_ID` | 빈 문자열. `--dart-define`으로만 공급하며 실제 운용은 `--dart-define-from-file` JSON 사용 |
| `UNAVO_TILE_URL` | `https://api.vworld.kr/req/wmts/1.0.0/{key}/{layer}/{z}/{y}/{x}.png` |
| `UNAVO_TILE_KEY` | 빈 문자열. 없거나 공백이면 TileLayer 자체를 만들지 않는다 |
| `UNAVO_TILE_LAYER_LIGHT` / `UNAVO_TILE_LAYER_DARK` | `Base` / `midnight` |
| `UNAVO_TILE_ATTRIBUTION` | `© 국토교통부 브이월드`. 빈 설정도 이 출처로 대체한다 |
| `UNAVO_TILE_MIN_ZOOM` / `UNAVO_TILE_MAX_ZOOM` | `6` / `19`. 다크 상한 18. 잘못된 숫자는 기본값, 역전된 최솟값은 상한으로 보정한다 |

브이월드 WMTS 경로는 **tileMatrix/tileRow/tileCol = z/y/x** 순서다. 키와 레이어만 치환하고 좌표 치환은 flutter_map에 맡긴다. User-Agent 패키지 이름은 `kr.modumoa.hdapp`이다. 키 없음·타일 오류 시 테마에 맞춘 단색 위에 프로필·방향 마커와 궤적을 유지한다. 실패 로그는 프로세스당 한 번만 남기고 키가 포함된 URL·예외 본문을 출력하지 않는다.

**타일 이용 규칙.** M2 지시문의 브이월드 2026-10-30 약관 기준으로 원본 타일을 표시한다. 위성 레이어, 색 필터, 블렌드, 재스타일, 타일 Opacity를 사용하지 않으며 `TileDisplay.instantaneous()`로 타일 페이드도 끈다. 시스템 `MediaQuery.platformBrightness`가 바뀌면 제공 레이어 Base/midnight만 바꾼다. 지도 우하단 출처는 접기·숨기기 기능 없는 텍스트이며 키가 없어도 표시한다.

공급자는 기본 클래스 `NetworkTileProvider`이고 추가 캐시 패키지·수동 저장은 없다. **8.3.2에서는 이 공급자도 디스크 캐시가 기본으로 켜져 있으므로 `cachingProvider: const DisabledMapCachingProvider()`를 명시한다.** Flutter 이미지 메모리 캐시만 사용한다. 설치된 패키지 소스와 [공식 캐시 문서](https://docs.fleaflet.dev/layers/raster-tile-layer/caching.md)로 기본 동작을 확인했다. 대상은 Android/iOS 앱이며 브라우저 자체 캐시 정책을 다루는 웹 배포는 이번 범위가 아니다.

**네이버 표시·약관(M3).** 고정된 flutter_naver_map 1.4.4의 `NMapType.navi`와 `nightModeEnable`을 사용한다. 회전·기울임 제스처, 최대 기울임 63도, 건물 레이어를 켜고 축척·위치 버튼·실내 지도는 끈다. 첫 카메라는 내 위치 → 따라가는 대상 → 첫 참여자 → 서울시청 순서로 정하며 줌은 18이다. 설치 소스에서 옵션은 `didUpdateWidget`이 아니라 `NaverMap.build → _updateOptionsIfNeeded → controller._updateOptions`로 갱신됨을 확인했다. 밝기 변경 시 야간 옵션만 갱신하고 지도를 재생성하지 않는다.

NAVER 로고는 왼쪽 아래에 상시 유지하고 플로팅 바 여백을 확보한다. `logoClickEnable: true`로 SDK의 법적 고지·오픈소스 화면을 그대로 연다. 로고를 숨기거나 다른 UI로 덮지 않으며, 네이버 지도 위에 별도의 출처 텍스트는 붙이지 않는다. 타일 색 필터·변형·커스텀 스타일을 추가하지 않는다. 위의 디스크 캐시 금지는 브이월드 타일 규칙이며, 네이버 SDK 자체 지도 캐시는 SDK가 관리한다. 마커의 `NOverlayImage.fromWidget`은 SDK 내부 임시 이미지 캐시를 사용한다.

**교체 경계·표시.** `app/lib/map/room_map.dart`는 얇은 `RoomMap` facade와 `abstract class RoomMapController`를 제공한다. `RoomMapController.create(provider)`가 `NaverRoomMapController` / `VworldRoomMapController`를 만들고 facade가 대응하는 지도 구현을 선택한다. 기존 무인자 컨트롤러와 facade의 기본값은 브이월드로 유지한다. 컨트롤러는 `moveTo(latitude, longitude, zoom:)`, `follow()`, `recenter()`, `alignHeading(bool)`을 제공한다. facade 입력은 positions/trail/targetHandle/selfHandle/following/brightness/onInteraction/tiles와 car/fullscreen/onFullscreen/onStopSharing이다. 공통 지도 버튼은 facade 내부에 표시한다. positions는 표시 이름과 LocationFix를 담은 `RoomMapPosition`이다. RoomScreen은 서비스의 공급원·오류 상태를 전달하고 공급원별 SDK 카메라·좌표 타입은 사용하지 않는다. 브이월드 구현은 `vworld_room_map.dart`에 유지한다.

두 구현은 `room_map_geometry.dart`의 이동 방향·전방점·거리·카메라 계산과 `room_map_widgets.dart`의 프로필·방향 삼각형·거리 라벨·원형 버튼을 공유한다. C2(2026-11-13)는 **나·상대 모두** `MemberAvatar`로 사진 또는 선택한 마스코트를 표시하며, 프로필 미설정은 `mascot-01`이다. 사진 로딩·실패 중에도 기본 마스코트를 표시한다. 입장 순서 무지개 3dp 테두리, 내 alpha 1·상대 alpha 0.55, 내 마커 최상위 순서를 유지한다. 프로필 사진·마스코트·이름표는 지도 회전·기울임과 무관하게 똑바로 유지한다.

**마커 크기·위치(C2·C3).** `RoomMarkerStyle`의 프로필 지름은 나·상대 동일하게 폰 28dp·차량 32dp다. C3 방향 삼각형의 채움 경로는 차량 밑변 12×높이 7dp, 폰 10×6dp이며, 흰 2dp stroke를 포함한 외형은 각각 14×9dp·12×8dp다. 그 뒤에 검정 alpha `0x26`의 3dp stroke를 두어 흰 외곽선 바깥에 옅은 0.5dp 대비선을 남긴다. 모든 stroke는 round join이므로 꼭짓점이 캡처 영역 밖으로 늘어나지 않는다. 가장 바깥 대비선과 프로필 테두리 사이 간격은 2dp이며 방향 오버레이는 차량 56×56dp·폰 50×50dp다. 네이버·브이월드는 같은 `RoomDirectionPainter`를 사용한다.

상대 이름은 프로필 바로 아래 별도 12dp 영역에 9sp 한 줄 말줄임으로 표시하며, 이름표 폭은 프로필 지름 이하로 제한한다. 내 이름표는 생략한다. 프로필 비트맵에서 기존 회전용 빈 여백을 제거하고 이름표를 프로필 아래 1dp에 배치해, 프로필+이름표 비트맵은 상대 차량 32×44dp·폰 28×40dp다. **GPS anchor는 프로필 중심**이며 네이버의 y는 `diameter / 2 / size.height`, 브이월드는 그에 대응하는 alignment다. 방향과 프로필·이름표를 같은 GPS 좌표에 합친 전체 영역은 차량 56×56dp, 상대 폰 50×51dp(나 50×50dp)로 56dp를 넘지 않는다. 프로필 사진·이름표는 회전하지 않는다.

**방향 계산(C2).** `RoomDirectionTracker`는 handle별 기준 위치·마지막 표본·마지막 방향만 보관한다. 첫 표본에는 heading·speed가 있어도 방향을 표시하지 않는다. 같은 stream의 새 seq에서 기준 위치와의 거리가 `minimumMovementMeters=3.0 m` 이상이면 이동 방위각을 계산하고 기준점을 갱신한다. 3m 미만은 기준점을 유지해 이동을 누적하고, 정차·작은 흔들림에는 마지막 방향을 유지한다. 표본 heading은 `minimumHeadingSpeed=1.5 m/s` 이상이고 이동 방위와 최단 각도 차이가 `maximumHeadingDifference=45°` 이하일 때만 `headingWeight=0.2`로 보조한다(이동 방위 80%·heading 20%). 이동과 어긋나는 heading 0은 버리며 실제 북진 0은 허용한다. 각도 보정은 0/360 경계의 최단 방향으로 계산한다. 중복·역순 seq는 무시하고, stream 변경은 미확정 상태로 초기화하며, 사라진 참여자의 상태는 제거한다. `LocationFix`·서버 프로토콜은 바꾸지 않는다.

**방향 표시·캐시(C2·C3).** 방향 삼각형은 프로필과 별도 오버레이다. 네이버 프로필은 `angle: 0`, `isFlat: false`, 방향 마커도 `isFlat: false`로 둔다. flat 삼각형은 tilt 50에서 세로로 눌려 똑바로 선 프로필 안쪽에 들어올 수 있으므로, 카메라의 `nowCameraPositionStream`을 구독하여 화면 각도 `atan2(sin(이동 방위−카메라 방위), cos(이동 방위−카메라 방위) × cos(tilt))`만 `setAngle`로 갱신한다. 카메라 변경마다 위치를 다시 조회하거나 비트맵을 만들지 않는다. 회전·기울임에도 기본 마커의 형태가 유지되고 flat 마커는 함께 회전·기울어진다는 SDK 동작은 [네이버 공식 마커 문서](https://navermaps.github.io/android-map-sdk/guide-ko/5-2.html)의 플랫 절과 설치된 1.4.4 소스로 확인했다. 브이월드는 프로필 `Marker.rotate: true`로 지도 회전을 상쇄하고, 별도 삼각형은 `rotate: false`와 계산된 이동 방위를 적용하여 지도와 함께 회전한다. 방향 미확정 시 네이버는 오버레이를 생성하지 않거나 숨기고, 브이월드는 삼각형을 생략한다.

네이버 `RoomMarkerIconCache` 키는 `(handle, 표시 이름, 나 여부, brightness, car, avatar kind, avatar version, 입장 색)`이다. 좌표·heading 유무·heading 값·계산된 방향은 키에서 제외한다. 사진·마스코트는 캡처 전에 `ui.Image`로 디코딩한다. 실패 시 기본 마스코트 캡처를 30초 재사용하고 다음 sync에서 재시도한다. 방향 이미지는 `(입장 색, car)`별로 북쪽 삼각형만 캡처하여 최대 14개(7색×2모드)를 재사용한다. 위치 변경은 `setPosition`, 방향 변경은 `setAngle`, 스타일 변경은 `setIcon`·`setSize`·`setAlpha`로 처리한다. SDK alpha와 위젯 opacity를 이중 적용하지 않는다. 내 프로필/삼각형 global z-index는 300000/300001, 상대는 200000/200001이다. 브이월드는 C3에서 네이버와 동일하게 참여자별 프로필·삼각형 순서로 그리고 나를 마지막에 배치한다. 각도·지도 테마가 바뀌어도 방향 비트맵 캐시 키와 캡처 횟수는 늘리지 않는다. 참여자 제거 시 오버레이·프로필 캐시·디코딩 이미지를 정리하고, 지도 dispose 시 이미지·캐시·카메라 구독을 정리한다.

네이버 궤적은 금색 폭 8·테마 대비색 외곽선 폭 2의 `NPathOverlay`이며 2점 미만이면 생략한다. 이후 `setCoords`로 갱신한다. 브이월드는 기존 금색 폭 6의 둥근 Polyline이다. 지도에는 `trailOf(followTarget)`만 전달한다. 세션은 위치·궤적이 바뀔 때만 새 불변 스냅샷을 만들고 그 사이에는 같은 객체를 돌려주므로 네이버의 `listEquals`는 identical로 단락되고 브이월드는 궤적 참조가 바뀔 때만 투영한 `LatLng` 목록을 다시 만든다.

**따라가기 공통 규칙.** `roomForwardPoint()`·`followBounds()`는 계산된 direction이 있으면 전방 반평면의 가장 가까운 점을, 없으면 최근접 꼭짓점 다음 점을 고른다. 원시 `LocationFix.heading`은 사용하지 않는다. 적절한 점이 없으면 따라가는 대상의 현재 위치를 쓴다. 직선 거리는 `350 m` / `1.2 km` 형식이며 좌상단에 표시한다. 사용자 터치가 끝날 때까지 자동 이동을 멈추고 마지막 제스처/카메라 정지 뒤 5초 후 따라가기가 켜진 경우에만 재개한다. 따라가기 꺼짐에서는 새 표본·테마 변경으로 카메라를 자동 이동하지 않는다.

`naverFollowCamera()`는 SDK와 무관하게 내 위치 중심·tilt 50·계산된 이동 방향·거리 줌을 계산한다. 방위는 `RoomDirectionTracker`의 내 방향을 사용하고 미확정이면 현재 카메라 방위를 유지한다. 앞차 위치·궤적만으로 내 진행 방향을 추측하지 않는다. `RoomFollowCameraPolicy`의 기본 내비 줌과 따라가기 상한은 18, 원거리 하한은 14다. 대상까지 거리 `<200m: 18`, `<600m: 17`, `<1.5km: 16`, `<4km: 15`, 나머지 14를 쓴다. 상대 위치가 없거나 그룹장 본인이면 내 위치·줌 18이다. 두 지도 초기 카메라와 `moveTo()` 기본 줌도 18이다. 현재 런타임에는 두 좌표의 bounds를 SDK에 전달하는 자동 fit 동작이 없으며, 내 위치 중심·거리 단계 줌을 유지한다. 네이버는 최대 초당 1회 최신 표본으로 `NCameraUpdate.withParams`에 linear·800ms를 설정한다. 브이월드도 같은 중심·거리 줌을 쓰고 타일 공급원의 최소·최대 줌으로 제한하며, 2D 공급원이라 tilt는 적용하지 않는다.

수동 제스처 중에는 자동 이동을 멈추고 마지막 조작 종료·카메라 정지 후 5초 뒤 재개한다. 내 위치 버튼은 줌을 유지한 채 내 위치로 이동한다. 방향 정렬은 따라가기 여부와 무관하게 계산된 내 이동 방향으로 즉시 회전하고 이후 방향 갱신을 반영한다. 방향 미확정이면 현재 방위를 유지하고, 정차 시 마지막 방향을 유지한다. 다시 누르면 북쪽 위(0도)를 유지한다. 네이버 `withParams`에서 생략한 줌·tilt는 유지하고, 브이월드는 카메라 rotation에 반대 부호를 사용한다. 따라가기 해제는 보류 카메라 요청과 진행 중 전환을 취소한다.

**GPS·권한.** `AppServices` 기본 소스는 `GeolocatorLocationSource()`이며 테스트용 소스 주입도 유지한다. 서비스 확인 → checkPermission → denied일 때 requestPermission → 앱 권한 상태 변환 순서다. whileInUse/always는 granted, denied/unableToDetermine는 denied, deniedForever는 deniedForever다. 서비스 꺼짐은 serviceOff이며 권한 요청 도중 서비스가 꺼지는 경우도 다시 확인한다.

- Android: `AndroidSettings(forceLocationManager: true, accuracy: high, intervalDuration: 1s, distanceFilter: 0)`에 §12의 공유용 `foregroundNotificationConfig`를 설정한다. GMS가 없는 Pleos에서도 LocationManager를 사용하며 COARSE/FINE_LOCATION 권한을 유지한다.
- iOS: `AppleSettings(accuracy: best, activityType: automotiveNavigation, distanceFilter: 0, allowBackgroundLocationUpdates: true, showBackgroundLocationIndicator: true, pauseLocationUpdatesAutomatically: false)`. Info.plist의 `NSLocationWhenInUseUsageDescription`은 “같은 방 참여자에게 내 차 위치를 보여 주기 위해 사용합니다”이다. xcodeproj는 변경하지 않는다.
- hasSpeed/hasHeading/hasAccuracy가 false인 값과 음수·유효하지 않은 선택 필드는 null로 전달한다. watch 구독 취소는 네이티브 위치 스트림 취소로 전파된다.
- M7은 §12의 위치 포그라운드 서비스·iOS `location` 배경 모드로 사용자가 켠 공유를 배경에서도 유지한다. Android 배경 위치 권한과 iOS “항상 허용”은 요구하지 않는다.

**화면 연결(M5a).** 입장은 지도가 없는 통화 방이다. 다른 멤버 카드 동의 후만 지도를 표시한다. 폰 세로는 위 70% 지도·아래 30% 통화 방, 폰 가로와 차량 주 패널은 좌 70%·우 30%다. 플로팅 바의 위치 관련 버튼은 제거하고 지도 내부 버튼으로 옮긴다. 전체 화면에서는 통화 방 대신 참여자 아바타 인디케이터와 하단 음성·방 관리 바를 표시한다. 세부 흐름·워터마크·테마는 §15를 따른다.

설정의 map 아이콘은 최종 공급원을 전달해 `MapCreditsScreen`을 연다. 네이버는 “지도: 네이버 지도 (NAVER Cloud Platform Maps)·지도 왼쪽 아래 NAVER 로고를 누르면 법적 고지와 오픈소스 정보”를, 브이월드는 기존 출처·국토교통부의 “브이월드 배경지도”·공공누리 제1유형·“수정·가공하지 않음”을 표시한다. 두 공급원 모두 “위치는 방이 있는 동안만 서버(국내 리전)에 남습니다” 안내와 chevron 아이콘의 `showLicensePage` 연결을 유지한다. 위치 SVG 7종은 Fable이 공급한 기존 자산을 사용한다. 동작 테스트는 메모리 아이콘 번들을 사용한다.

**seq stream.** LocationShare는 프로세스에서 한 번 생성한 암호학적 난수 8바이트를 16자 소문자 hex stream으로 보낸다. 같은 실행의 stop/start·방 변경에도 stream과 기존 세션 seq 증가를 유지한다. POST 본문·위치 응답·SSE·hello의 LocationFix에 stream이 추가된다. 서버는 16자 hex를 검증하고 lastSeq를 `(handle, stream)`별로 보관한다. 새 stream의 seq 0은 이전 stream의 큰 seq와 비교하지 않고, 현재 위치는 여전히 handle당 한 건으로 덮어쓴다. 기존 handle별 400ms 속도 제한은 유지하므로 stream 변경으로 우회할 수 없다. 앱도 stream이 바뀐 위치를 받아들이고 각 대상의 궤적은 handle/stream별 마지막 seq로 중복 제거한다. 나머지 궤적·수신 시각·방 삭제 규칙은 M1과 같다. 옛 hello의 stream 누락은 앱에서 빈 문자열로 읽지만 새 서버 POST에는 유효한 stream이 필수다.

검사·빌드 예시:

```sh
cd /Users/rlaxorhs77/Desktop/HD-app/app
flutter analyze --no-pub
flutter test --no-pub test/map_provider_test.dart test/naver_room_map_test.dart test/room_map_test.dart test/f2_layout_test.dart test/room_speaking_test.dart test/session_restore_widget_test.dart test/ios_audio_channel_test.dart
flutter test --no-pub
flutter build apk --release --no-pub --target-platform android-arm64 --dart-define-from-file=<키 JSON 경로>
```

키 JSON은 레포 밖에서 관리하고 실제 키는 코드·테스트·문서에 기록하지 않는다. 브이월드로 되돌릴 때도 같은 JSON의 `UNAVO_MAP_PROVIDER`를 `vworld`로 지정한다. 네이버 SDK 위젯을 테스트에서 pump하지 않으며, 새 테스트는 공급원 선택·거리 줌·카메라 파라미터·2점 미만 궤적 생략의 순수 함수만 검사한다. M3 작업에서는 새 패키지 추가·flutter pub 실행·Flutter test/build를 하지 않고, 설치된 SDK와 패키지 소스를 기준으로 정적 분석·포맷까지만 검사한다. 위 test/build는 Fable이 별도로 실행한다.

## 14. 동의 UI(M4)

`ui/widgets/unavo_dialog.dart`의 `showConsentDialog(context, title:, lines:, detail:, note:)`는 bool, `showNoticeDialog(context, message:)`는 void Future를 반환한다. 두 팝업 모두 루트 Navigator의 `showDialog(barrierDismissible: false)`와 `PopScope(canPop: false)`를 사용해 화면 중앙에 뜬다. 바깥 탭·시스템 뒤로가기는 닫기를 유발하지 않으며, 응답 전에는 뒤쪽 화면과 차량 보조 패널의 버튼을 누를 수 없다. 방 상태가 바뀌어도 방 화면의 자동 pop이 앞에 있는 동의 모달을 대신 닫지 않는다. 기존 `location_consent_sheet.dart`는 제거했다.

폰의 카드 폭은 화면의 90% 이내·최대 420, 차량은 최대 560이다. 호출 위치의 `ControlScale`을 다이얼로그 경로에 전달해 폰 56dp·차량 80dp 조작부를 유지한다. 제목·본문과 선택 상세 영역은 스크롤할 수 있고 하단 응답 버튼은 고정한다. 동의는 기존 `check`, 미동의는 `back`, 안내 닫기는 `check` 아이콘의 `PanelButton`만 사용하며 버튼 글자는 표시하지 않는다. 접근성 라벨·선택 상태는 유지한다.

M5a는 프로필의 따라가기·따라가기 요청·따라가기 중지에 이 모달을 사용한다. 본문은 대상 또는 요청자의 표시 이름, 공유 범위, 종료 조건, 국내 서버의 보관 기간을 알린다. 미동의 안내와 시작 순서는 §15를 따른다. 시작·동의 대기 중에는 중복 조작을 막고, 여러 요청은 하나씩 처리한다.

`screens/phone/legal_consent.dart`는 로그인 뒤의 전체 동의 페이지다. 차량에서는 `CarShell`의 주 패널을 채우고 두 항목의 체크·전문 펼치기를 제공한다. 체크는 `check` 아이콘의 선택 상태와 색으로, 전문 펼치기는 `chevron`으로 표시한다. 두 문서가 로드되고 필수 개인정보 항목을 체크하면 하단 동의 버튼을 활성화한다. 위치 항목은 선택으로 표시한다. 전문은 `rootBundle.loadString('assets/legal/privacy.md')`와 `location.md`로 읽는다. 원문 파일을 수정하지 않고 `#`·`##` 줄은 제목, `-` 줄은 글머리 기호, 나머지는 본문으로 그리며 펼친 전문에는 별도 스크롤 영역을 둔다. 추가 마크다운 패키지는 사용하지 않는다.

검증 대상은 `unavo_dialog_test.dart`, `room_consent_flow_test.dart`, `legal_consent_test.dart`, 갱신한 `location_share_test.dart`·`room_session_location_test.dart`다. 새 위젯 테스트는 30초 timeout과 유한한 pump를 사용하고 이벤트 핸들러 안에서 expect하지 않는다. M4 작업에서는 format·analyze만 수행하며 Flutter test/build는 Fable이 별도로 실행한다.

M10은 중요 내용 표시(고시 제4조)를 위해 전문을 접어도 개인정보 요약 6줄(항목·목적·보유·제공·경로·거부)과 위치 요약 6줄(항목·제공·경로·제공처 보유·보유·거부)을 항상 표시한다. 라벨은 `UnavoType.body`의 굵은 gold, 본문은 같은 본문 스타일이며 줄 간격 4dp·블록 아래 8dp를 둔다. 360dp 폰과 차량 주 패널에서 줄바꿈하며 기존 전문 펼치기를 유지한다. 따라가기·따라가기 요청 모달의 마지막 줄에는 “동의하지 않아도 통화는 계속됩니다”를 추가하고 따라가기 중지에는 넣지 않는다. 가입 연령 확인과 문서 버전 3의 계정별 서버 보관·성공 후 진입·세션 복원 조회는 §12의 D1·D1b 규칙을 따른다.

## 15. 방 화면 UX(M5a)

**입장·따라가기.** 입장 시 지도 없이 멤버 카드와 음성·방 관리 바를 표시한다. 방 화면의 “우나보 UNAVO” 상단 제목만 제거하고 메인 화면의 제목·기존 워드마크는 유지한다. `MemberAvatar`는 표시 이름 첫 글자의 원형 아바타이며 이후 사진으로 바꿀 경계다. 공유 중인 내 카드 탭은 아래의 공유 중지 모달을 열고, 공유 중이 아니면 무동작이다. 다른 카드 탭은 `showConsentDialog(title: '따라가기')`를 열고 표시 이름, “○○ 님의 위치를 따라갑니다”, “내 위치도 같은 방 참여자에게 보입니다”, “방을 나가거나 위치 공유를 중지하면 공유가 끝납니다”, “위치는 방이 있는 동안만 서버(국내)에 남습니다”를 표시한다. 이것이 요청자의 위치 공유 동의다. 동의 → v4 기록 저장 성공 확인 → 꺼져 있으면 `LocationShare.start(token:, stillValid:)` → 성공 및 차량 주행 제한 해제를 확인 → follow POST → pending 대기 → 수락 확인 → 지도 표시 순서다. 이미 공유 중인 대상은 POST 응답에서 즉시 수락된다. 차량의 주행 제한 미확인 상태도 전역 잠금처럼 모달과 POST를 허용하며, GPS 표본은 따라가기 허용이나 취소의 근거로 쓰지 않는다(§12). 미동의는 “동의하지 않아 따라가기 기능을 사용할 수 없습니다” 안내다.

대상은 follow-request를 받으면 “따라가기 요청” 모달로 요청자 이름·공유 범위·종료 조건·보관 기간을 확인한다. 수락은 `start()` 성공 후 accepted:true, 미동의나 권한 실패는 accepted:false를 보낸다. 이미 공유 중이고 최신 개인정보·위치 동의가 확인된 경우 추가 모달 없이 수락한다. 구버전 동의이면 먼저 새 문구와 저장 성공을 확인한다. 서버도 현재 fix 또는 이전 수락으로 공유 중임을 아는 대상은 즉시 수락한다. 요청자의 거절 안내는 “○○ 님이 위치 공유에 동의하지 않았습니다”이며 followTarget과 지도를 해제한다. 대기 중 취소·방 변경·퇴장 뒤의 늦은 응답은 적용하지 않는다.

같은 대상 카드를 다시 탭하면 “따라가기 중지” 모달이다. check 선택 시 follow DELETE·지도 닫힘이며 내 공유는 계속한다. 공유 중인 내 카드와 지도 안 locationoff 버튼은 동일한 `showConsentDialog(title: '위치 공유 중지', lines: ['내 위치 공유를 중지합니다'])`를 연다. 선택 인자 `note`로 본문 아래에 “위치 공유를 중단하면 그룹 안 파트너와의 따라가기 연결이 끊깁니다. 통화는 계속됩니다. 그래도 하시겠습니까?”를 `UnavoType.caption` 회색 보조 스타일로 표시한다. check 선택은 내 공유·따라가기와 지도를 닫고, 나를 따르던 팔로워는 서버 종료 이벤트로 해제한다. back 선택은 상태를 유지한다. 방을 나가면 모두 종료한다. 동의 모달은 가운데·차단형·아이콘 버튼만 사용하는 M4 규칙을 유지한다.

**배치.** 폰은 SafeArea 전체를 사용한다. 세로 지도:통화 방 7:3(상/하), 가로는 7:3(좌/우)다. 차량은 CarShell 주 패널을 7:3(좌/우)로 쓴다. 폰 세로의 작은 통화 영역에는 가로 멤버 띠, 옆 통화 영역에는 세로 목록을 둔다. 바는 폰 SafeArea 바닥 또는 차량 주 패널 바닥 +8dp에 고정한다. M8a 일반 바는 왼쪽 [음소거·필요 시 재연결(폰)·음량], 가운데 [홈], 오른쪽 [출력 경로(폰)·나가기]다. 양쪽에 같은 폭을 배분해 홈을 기하학적 가운데에 두고, 부족한 폭은 가로 스크롤한다. 음량 펼침 모드는 [음량·슬라이더·나가기]를 유지하며 홈을 숨긴다. 음량은 폰·차량 모두 표시하고 수신 이득 상한 100%와 기존 차량 시스템 음량 연동 스위치는 유지한다. 좁은 패널의 버튼과 확장 음량 조작은 가로 스크롤한다.

`UnavoWatermark`는 Rye의 “Una Vox”를 “UNAVO” 글자 크기의 1/2로 두고 행 높이 1로 바로 붙인다. `LayoutBuilder`로 통화 방 영역 폭의 80%·높이의 40%를 한계로 잡고, 영역 폭에 비례하는 두 줄을 `FittedBox(scaleDown)`으로 맞춰 중앙에 표시한다(M5a-e). IgnorePointer·ExcludeSemantics를 유지하고 Stack에서 멤버 카드가 워터마크 위에 그려진다. `Theme.of(context).brightness`에 따라 다크는 크림색 `UnavoColors.text`·opacity 0.16, 라이트는 금색 `UnavoColors.gold`·opacity 0.18을 쓰며 M5a-d의 테마별 색상은 유지한다. 통화 패널 배경은 두 테마 모두 불투명 `UnavoColors.ink`다. 지도에는 배치하지 않는다. 전체 화면은 같은 지도 상태를 GlobalKey로 이동시켜 통화를 유지하고 통화 방은 숨긴다. 하단 바는 계속 보이며 좌상단에는 최대 6명 원형 아바타(폰 40·차량 56dp)를 가로로 놓는다. 말할 때 테두리 3dp와 바깥 글로우는 새 토큰 `UnavoColors.speaking = #7CFF5B`다. 자기 발화는 localSpeaking, 원격 발화는 speaking 집합을 따른다.

**지도 조작.** 우상단 세로 묶음은 흰 원·그림자·진회색 아이콘, 지름 폰44/차량64dp, 간격10dp다. focus는 줌 유지 재중심, compass는 heading/북쪽 위 토글, locationoff는 공유 중지다. 전체 화면에서는 collapse를 추가한다. 평상시 좌하단 로고 위에는 흰색 60% expand 원을 둔다. 네이버 로고는 클릭 가능하고 전체 화면의 바 위에 여백을 확보한다. 타일 변형은 하지 않는다. 신규 compass/expand/collapse SVG는 Fable이 공급하며 테스트는 메모리 icon_bundle을 사용한다. 마커·카메라는 §13을 따른다.

**자동 테마.** 수동 override·라이트/다크 토글은 전역 제거하고 저장된 수동 값은 읽지 않는다. ThemeMode.system 및 `MediaQuery.platformBrightness`가 앱·배경·지도 야간 모드의 출처다. Android Automotive(Pleos)는 OS가 전달하는 차량 주야간 모드, iOS는 시스템 다크 모드(사용자 설정의 일몰 자동 포함)를 따른다. iOS에는 주변 조도 센서의 공개 API가 없어 직접 센서를 읽지 않는다. Android 조도 센서 연결은 후속 결정 항목이다.

**서버 follow 프로토콜 v2.** 모두 인증된 같은 방 멤버에게만 허용하며 본문 수신 전후의 멤버 재검사를 유지한다. follow/respond/unfollow 세 경로는 합산하여 방·handle당 1초에 한 번만 처리한다(429 `FOLLOW_RATE_LIMIT`). 앱은 이 응답을 받으면 같은 작업 큐에서 1초 후 한 번 재시도한다.

| 메서드·경로 | 본문 | 응답·SSE |
|---|---|---|
| `POST /v1/rooms/:code/follow` | `{target}` | `202 {requestId,revision,accepted}`. 공유 중인 대상이면 즉시 accepted, 아니면 pending 저장 |
| `POST /v1/rooms/:code/follow/respond` | `{requestId,accepted}` | `202 {accepted,revision}`. 수락은 같은 대상의 대기 요청들을 수락하며 거절은 지정 요청만 해제. 모르는·완료된·다른 대상의 ID는 404 `FOLLOW_EXPIRED` |
| `DELETE /v1/rooms/:code/follow` | — | `202 {accepted:true,revision}`. 요청자의 수락 관계 또는 pending만 해제 |

SSE `follow-request {requestId,requester,displayName,revision}`와 `follow-response {requestId,requester,target,accepted,revision,reason?}`를 사용한다. 대상 전환·취소·응답 완료 시 대상에게 `follow-cancelled {requestId,requester,revision,reason}`를 보낸다(`cancelled`/`accepted`/`declined`). 수락 완료 알림은 토큰을 확정하고 취소 알림은 그 요청만 무효화한다. 이미 열린 차단형 모달은 사용자 응답으로 닫지만, 무효화된 요청의 늦은 동의는 실행하지 않는다.

hello는 `{self,members,leader,positions,trails,revision,followTarget,pendingFollow,followRequestId,followRequests}`다. `followTarget`은 수락된 대상 문자열 또는 null, `pendingFollow`는 대기 대상 문자열 또는 null, `followRequestId`는 해당 관계의 식별자다. `followRequests`는 나에게 온 대기 요청 객체 목록으로 requestId·requester·target·displayName을 담는다. 대상이 단절 유예 중이어도 서버가 요청을 유지하고 재접속 hello로 전달한다.

전체 `trails` SSE 방송은 제거했다. `trail {handle,points,revision}`은 수락된 팔로워가 추가될 때 **그 팔로워에게만 한 번** 보내며, 이후 `location`을 이어 붙인다. hello와 positions도 수신자의 followTarget 궤적만 포함한다. 무변경 follow 재요청은 기존 requestId·revision·accepted를 돌려주고 이벤트를 하나도 보내지 않는다. 현재 pending 대상이 이미 공유를 시작했다면 같은 ID로 수락 전환하며 이는 실제 변경이다.

앱의 `_serverRevision`은 SSE 전용 순번이며 첫 구독·`Reconnected`마다 연결 식별자 `_connectionId`를 증가시키고 0으로 초기화한다. HTTP follow POST·DELETE·respond는 이 순번을 올리지 않는다. 같은 연결에서 SSE 순번보다 작은 hello는 스냅샷 전체를 건너뛴다. 내 HTTP 완료 revision은 연결 식별자와 함께 `_myFollowRevision`에 별도로 기록하여 더 오래된 hello의 내 follow 필드(`followTarget`·`pendingFollow`·`followRequestId`·`trails`)만 막고 위치·멤버·수신 요청은 적용한다. 응답 완료한 수신 요청 ID도 연결별로 기억하여 늦은 hello에서 다시 표시하지 않는다. POST 결과보다 먼저 도착한 follow-response는 받은 연결 식별자를 붙여 보류하고 현재 연결·requestId·대상이 맞을 때만 적용한다. HTTP 대기 중 재접속하면 이전 연결의 완료 결과와 보류 응답을 버리고, 플래그 정리 후 새 연결에서 보류한 최신 hello의 follow 필드를 적용한다. 보류 기간의 위치·궤적 증분은 이어 붙이고, 보류 대상의 종료는 그 follow 필드를 비우며 사용자의 새 대상 선택은 보류 스냅샷을 폐기한다. 같은 연결에서는 HTTP 결과 다음에 보류 SSE 응답을 적용한다. 같은 대상 취소 후 재요청과 이미 수락된 A→B 전환도 같은 규칙이다. accepted 전에는 지도 없이 “따라가기 응답 대기 중”을 표시한다. `follow-request`의 requester가 멤버 캐시에 없어도 요청을 보관하고 비동기 `_refresh`를 시도한 뒤 모달을 표시한다. 조회 실패 시에도 이벤트 displayName(없으면 handle)을 사용한다. 재조회 중 취소는 이벤트 큐를 막지 않고 즉시 폐기한다. 멤버 조회는 시작 순번과 멤버 세대를 기록하며, 더 새로운 조회가 완료했거나 멤버 이벤트·스냅샷 적용으로 세대가 바뀌면 늦은 결과의 멤버·미디어·오류를 모두 버린다.

`follow-response.reason == requester-stale`는 현재 requestId에만 적용하고 “내 위치 수신이 끊겨 따라가기가 끝났습니다”를 표시한다.

**서버 규칙(리뷰 2차 G7, 2026-11-12).** 계정당 `left_at IS NULL` 멤버십은 하나다. 다른 방 생성·입장은 `409 ROOM_ACTIVE`, 같은 방 재입장은 멱등 `200`이며 첫 `joined_at`과 방 안 색상·순번을 보존한다. 초기화는 기존 중복 활성 멤버십을 `joined_at DESC, room_id DESC` 첫 기록만 남기고 닫은 뒤 부분 UNIQUE 인덱스 `room_members_active_user`를 만든다(인덱스가 있으면 재이관하지 않음). 로그아웃은 요청 토큰을 폐기하고 그 토큰의 SSE만 닫은 뒤 방마다 분기한다: 다른 기기의 SSE가 남아 있으면 공유·관계를 유지하고, SSE는 없지만 다른 유효 토큰이 있으면 기존 단절 유예(위치 수신 중이면 유지, 없으면 30초 뒤 정리, 끊기면 90초 stale)를 적용하며, 다른 유효 토큰도 없으면 즉시 `stopped`로 정리한다. 로그아웃은 방 멤버십을 끝내지 않는다. 요청자 본인의 위치가 stale이라 outgoing follow가 제거되면 요청자에게도 원래 requestId의 `follow-response {accepted:false, reason:"requester-stale"}`를 보내고, 대상의 stale은 기존 `stale`, 명시적 중지·퇴장 사유는 바꾸지 않는다.

**확인과 남은 결정.** Flutter 테스트는 NaverMap을 pump하지 않고 facade·브이월드·SDK 마커 생성 함수로 검사한다. 새 위젯 테스트는 고정 pump·30초 timeout·핸들러 밖 검증을 사용한다. M5a 작업에서 Flutter test/build는 실행하지 않으며 Fable이 별도 실행한다. 네이티브 지도·주야간 모드·로고 클릭·폰 회전·실차 음성/GPS는 기기 검증 대상이다.

표본이 없는 차량의 첫 따라가기 진입 제약은 M5a-c의 unknown 허용과 동의 후 최초 판정 검사로 해소한다. 따라가기만 중지하거나 상대 요청만 수락한 사람도 통화 방의 내 카드를 눌러 공유를 중지할 수 있다. 별도 텍스트 버튼은 추가하지 않는다.

## 16. 프로필·아바타(M5b)

**저장·프로토콜.** 계정의 `avatar_kind`는 null, `mascot-01`~`mascot-05`, `photo` 중 하나이고 `avatar_version`은 0에서 시작한다. 기존 SQLite에는 두 열을 추가해 null/0으로 초기화하며 반복 초기화는 기존 선택을 보존한다. 성공한 PUT/DELETE마다 version이 1 증가한다. 공개 사용자와 방 멤버에는 `avatar: {kind, version}`을 포함하며 비밀번호·내부 ID·사진 바이트는 포함하지 않는다.

사진은 기본 `server/data/avatars/<handle>-<avatar_version>.png`에 저장한다(리뷰 2차 G8b, 2026-11-12). `HDAPP_DB`로 DB 경로를 바꾸면 그 DB의 부모 데이터 폴더 아래 `avatars/`를 사용하며 디렉터리는 첫 업로드 때 만든다. 검사는 PNG 시그니처, 256×256 IHDR(8비트·RGB(2) 또는 RGBA(6)·압축 0·필터 방식 0·비인터레이스), 모든 청크의 CRC(`zlib.crc32`), 이어 붙인 IDAT 를 출력 상한(`height×(1+width×채널)`)을 둔 `inflateSync`로 풀어 정확한 길이와 모든 행의 필터 바이트 0~4, 최대 300×1024바이트까지이며 base64는 표준 패딩까지 엄격히 검사한다. 저장 순서는 새 버전 파일 쓰기·close → SQLite 트랜잭션으로 version 증가·COMMIT → 이전 버전 파일 삭제이고, COMMIT 전 실패는 ROLLBACK 하고 새 파일만 지워 이전 사진을 그대로 둔다. GET은 DB의 현재 version 파일만 읽으며 미커밋·고아 파일은 제공하지 않고 기동 시 정리도 하지 않는다. 옛 `<handle>.png`는 현재 version GET에서 한 번 새 이름으로 옮긴다. 마스코트 선택·삭제도 COMMIT 뒤에 사진 파일을 지우며 이전 사진 이력은 남기지 않는다. 앱은 사진 원본·EXIF를 올리지 않고 재인코딩한 PNG만 보낸다.

| 메서드·경로 | 본문·응답 | 규칙 |
|---|---|---|
| `PUT /v1/me/avatar` | `{kind:'mascot-03'}` 또는 `{kind:'photo',png:'<base64>'}` → `200 {user}` | 인증 필요. version 증가, 참여 중인 모든 방에 `member-updated {handle,avatar}` SSE |
| `GET /v1/users/:handle/avatar?v=<version>` | `image/png` | 인증 필요. 현재 사진 version과 정확히 일치할 때만 `Cache-Control: private, max-age=31536000, immutable`. 사진 없음·이전/누락 version은 404·no-store |
| `DELETE /v1/me/avatar` | `200 {user}` | null로 초기화, 사진 파일 삭제, version 증가와 같은 SSE |

업로드 경로에만 base64를 담을 수 있는 본문 한도를 적용한다. 다른 JSON API의 64KB 한도는 유지한다. 본문·사진·인증 헤더는 로그에 남기지 않는다. `/v1/me.user`, 연락처, 사용자 조회와 인증 응답에서도 최신 avatar를 직렬화한다. hello의 self·members와 방 조회·`/v1/me.room.members`에는 방 안 순번을 담는다. `/v1/me.user.order`는 현재 방 순번(미참여 시 null), `/v1/contacts[].order`는 조회자의 현재 방에 함께 참여한 연락처의 순번(아니면 null)이다.

**입장 순서·색.** 첫 `room_members.joined_at`을 보존하며 재입장은 `left_at`만 지운다. 방의 과거 참여 기록까지 포함해 joined_at 오름차순으로 0부터 order를 계산하고, 같은 시각은 참여 레코드 삽입 순서(rowid)로 결정한다. 중간 멤버가 나가도 뒤 멤버의 순번·색을 당기지 않는다. 기존 DB에서 이미 덮어써진 과거 시각은 복구할 수 없으므로 마이그레이션 당시 저장된 joined_at을 기준으로 이후부터 보존한다. 앱은 서버 order를 우선하고 누락된 경우 현재 멤버 목록의 인덱스를 사용한다.

`ui/member_colors.dart`의 순수 함수 `rainbowColor(order)`는 빨 `#FF4D4D`, 주 `#FF9A3C`, 노 `#FFD93C`, 초 `#4CD964`, 파 `#3C8CFF`, 남 `#4B5BD6`, 보 `#B36BFF`를 7명마다 반복한다. `MemberAvatar`는 3dp 테두리를 이 색으로 유지하고 발화는 바깥의 `UnavoColors.speaking` 글로우로 나타낸다. 02·05 마스코트만 원형 마스크 안에서 0.82배로 줄여 모자·콘을 보존한다. null의 기본 렌더와 사진 로딩 실패는 이름 첫 글자다. C-1에 따라 방 카드·전체 화면 인디케이터에서는 미설정(null)을 `mascot-01`로 표시한다. 카드의 사람 상태 아이콘은 제거하고 발화·연결·기기 아이콘만 유지한다. 좁은 카드에서도 아바타는 이름·아이디 영역의 왼쪽 세로 중앙이며 폰 이름 두 줄 규칙을 유지한다.

**프로필 편집.** 폰 로비와 차량 보조 패널의 톱니바퀴 → `SettingsScreen`의 프로필 아이콘으로 `ProfileScreen`을 연다(M8a). 차량에서는 주 패널의 중첩 내비게이터 안에서만 전환한다. 이전 `ProfileAvatarButton`은 제거한다. M9c 본문은 무지개 테두리 없는 미리보기 원 하나(폰 120dp·차량 160dp)이며, 우하단에 원 지름의 0.32인 원형 배지(`profile-edit-badge`, 폰 38.4dp·차량 51.2dp)를 겹친다. 배지 중심은 원을 감싸는 정사각형의 (0.86, 0.86)에 놓고, 금색(`UnavoColors.gold`) 채움에 `ink`색 `camera` 아이콘(배지 지름의 0.58)과 2dp 배경색 링(`Theme.of(context).scaffoldBackgroundColor`)을 사용한다. `Stack`은 `Clip.none`이며 원 밖 돌출분까지 버튼 영역에 포함해 원·배지 모두 같은 `profile-edit` 버튼으로 선택 UI를 연다. 폰은 프로필과 같은 내비게이터에 `ProfileSourcePage`(`profile-source-page`)를 push한다. 설정 화면과 같은 `ControlScale(car: false)` → `Scaffold` → `SafeArea` → 24dp 여백의 Column으로, 좌상단 `back`(`profile-source-back`), 24dp 간격 뒤 가로 꽉 찬 사진첩 `plus`, 다시 24dp 간격 뒤 기본 마스코트 5종의 Wrap(72dp)을 배치한다. 차량은 `showUnavoChoiceDialog<ProfileSourceChoice>(useRootNavigator: false)`로 주 패널 중첩 내비게이터 위에 기존 안내 카드와 같은 모달(`profile-source-dialog`)을 연다. 모달은 주 패널 가운데에 놓이고 배리어도 주 패널만 덮으며, 사진첩 `plus`·96dp 마스코트 5종·닫기 `check`와 80dp 조작부를 유지한다. 두 선택 UI는 현재 선택한 마스코트만 금색 테두리로 표시하며, `ProfileSourceChoice`의 `ProfileSourceMascot(kind)`·`ProfileSourceGallery`·null 결과를 `ProfileScreen._chooseSource()`에서 받아 분기한다. 마스코트는 선택 UI를 pop한 뒤 미리보기를 바꾸고 사진 초안을 지우며, 사진첩은 페이지·모달의 `route.completed`로 퇴장과 제거를 기다린 뒤 화면 컨텍스트로 연다. 폰의 되돌리기·시스템 back과 차량의 닫기·바깥 탭·시스템 back은 null을 반환해 변경하지 않으며, 사진첩 취소도 선택을 유지한다. 카카오의 「기본 이미지로 변경」은 미설정(null)의 기본 표시인 마스코트 1번과 같아 별도 항목으로 두지 않는다. 하단 `check`만 서버에 저장하고 `back`은 저장하지 않고 돌아가며, 선택 페이지·모달과 프로필 버튼에 글자를 표시하지 않는다. 저장·사진 처리 중에는 선택 UI를 열지 못하도록 편집을 비활성화하고 배지 채움을 `PanelButton` 비활성 배경과 같은 `UnavoColors.panel`로 바꾼다.

설치된 `image_picker 1.2.4`의 `pickImage(source: ImageSource.gallery,maxWidth:1024,maxHeight:1024,imageQuality:90)`를 사용한다. 설치된 Android 구현의 `useAndroidPhotoPicker`를 켜 Android 16 미만에서도 Photo Picker 계약을 사용하며 권한을 추가하지 않는다. 기존 image_picker의 설치된 전이 구현만 사용하고 pubspec 의존성은 추가하지 않는다. iOS Info.plist의 `NSPhotoLibraryUsageDescription`은 “프로필 사진으로 쓸 이미지를 고르기 위해 사진첩에 접근합니다”다.

`ui/avatar_images.dart`는 `ImageDescriptor`로 원본 비율을 읽고 `instantiateImageCodec(targetWidth/targetHeight)`로 긴 변 최대 1024px를 디코딩한다. `Canvas`·`PictureRecorder`로 중앙 정사각형을 256×256에 그린 뒤 `toByteData(png)`로 새 PNG를 만든다. 원본 경로·PNG는 앱 저장소에 쓰지 않는다. 크기·디코딩·네트워크 오류는 M4 `showNoticeDialog`로 표시하며 차량 모달에도 80dp 조작부를 전달한다. 저장·사진 처리 중 중복 조작을 막는다. 저장 성공은 로컬 세션 메타데이터와 내 방 카드에 즉시 반영되고, 다른 참여자는 SSE로 갱신된다. 늦은 HTTP/hello가 더 높은 avatar version을 덮지 않는다.

**마커·캐시.** M5b의 나 GPS 점·상대 36/48dp 규칙은 **§13 C2로 대체**한다. 나·상대 모두 사진/선택 마스코트/미설정 기본 마스코트(`mascot-01`)를 사용하며, 폰 28dp·차량 32dp다. 무지개 3dp 테두리, 내 alpha 1·상대 0.55와 내 최상위 순서를 유지한다. 프로필·이름표는 회전하지 않으며, 이동 방향은 별도 작은 삼각형으로 표시한다. 이름표 크기·anchor·방향 계산·지도 회전 보정·캐시 키는 §13을 따른다.

`ApiClient.avatarPhoto`는 인증 헤더를 포함한 version URL로 가져오며 서버 주소·로그인 토큰·handle·version별 메모리 캐시를 사용한다. 실패 시각·오류도 같은 키로 30초 보관해 추가 HTTP 없이 같은 오류를 반환하며 성공·실패를 합친 64개 상한을 유지한다. 30초가 지나거나 서버·토큰·버전이 바뀌면 다시 요청한다. 네이버 사진/마스코트는 `ui.Image`로 완전히 디코딩한 뒤 `RawImage`로 캡처한다. 로딩 실패 시 `RoomMarkerIconCache`가 기본 마스코트 캡처를 30초 재사용하고 만료 후 다음 sync에서 재시도하며, 성공하면 동일 버전이어도 즉시 아이콘을 교체한다. 방향·heading 변경은 프로필 비트맵을 다시 만들지 않는다. SDK alpha와 위젯 opacity를 중복 적용하지 않는다. 앱 수동 디스크 캐시는 없으며 SDK의 캡처용 임시 캐시는 §13과 같다. 브이월드도 facade로 전달된 avatar·order·API와 공통 프로필·방향 위젯을 사용한다.

**동의·검증.** M5b 당시 개인정보 `legalVersion='2'`, 위치 문서 `locationLegalVersion='1'`과 M6의 항목별 동의 저장을 유지했고 법률 Markdown은 변경하지 않았다. 이후 M7의 배경 전송 동의와 M10의 두 문서 버전 3·서버 동의 기록은 §12를 따른다. 추가 검증은 `member_colors_test.dart`, `member_avatar_test.dart`, `profile_screen_test.dart`, 지도 캐시 키·입장 색 테스트(C2에서 나·상대 프로필·방향·크기·카메라 회전 테스트로 갱신), 개인정보 버전 2 재동의 테스트, 서버 `avatars.test.ts`이다. 서버 테스트에는 마이그레이션, 300KB/PNG/IHDR 검사, 버전 증가·사진 삭제, 인증·캐시 헤더, 첫 입장 순서와 재입장, 공개 직렬화·참여 방 SSE를 포함한다. 새 테스트는 30초 timeout과 유한 pump를 사용하고 비동기 핸들러 밖에서 검증한다. 이 작업에서는 정적 분석·구문·포맷만 검사하며 테스트 실행과 빌드는 Fable이 담당한다. 실제 갤러리·네이티브 지도 캡처와 폰/차량 배치는 기기 확인 대상이다.

## 17. 차량 모드 주행 중 조작 잠금(M8b)

**기준·플랫폼.** `DeviceCapabilities`가 Android `FEATURE_AUTOMOTIVE`로 판별한 차량에서만 `DrivingState`가 `EventChannel('unavo/drive')`를 구독한다. 네이티브 `DriveChannel`은 `Car.createCar(context)`와 `CarUxRestrictionsManager`를 연결하고 구독 직후 현재 값, 이후 리스너 변경 값을 전송한다. 잠금 기준은 `CarUxRestrictions.isRequiresDistractionOptimization()`이며 `activeRestrictions` 비트 값이나 GPS 속도로 추정하지 않는다. 예를 들어 requiresDO가 true이면 비트 값이 0이어도 잠근다. 플랫폼은 기어가 P를 벗어난 정차(IDLING, 속도 0)에서도 requiresDO를 켜므로 신호 대기 중에도 잠기며, 이는 결정 21(11/12, A)로 확정한 의도된 동작이다(속도>0 조건으로 바꾸지 않는다). `CAR_SPEED`·`CAR_DRIVING_STATE` 권한은 요청하지 않는다. 기존 `distractionOptimized=true`를 유지하고 `android.car`는 optional uses-library와 compileSdk 37의 로컬 jar compileOnly로 연결한다. 새 Maven/pub 패키지는 없다.

**범위·수명.** `MaterialApp.builder`의 `DrivingLockOverlay`가 Navigator 위 Stack에 반투명 스크림, Tabler outline 핸들·자물쇠 아이콘, “주행 중에는 조작할 수 없습니다” 한 줄을 표시한다. `AbsorbPointer`는 주 패널·보조 패널·모든 route·다이얼로그를 포함한 앱 전체 터치를 차단한다. 초기 제한 상태를 포함하여 잠금 진입 시 post-frame에서 기존 포커스를 해제하고, Navigator 전체를 `ExcludeFocus`로 감싸 Enter 제출·Tab 이동·잠금 중 열린 다이얼로그의 포커스도 차단한다. 터치를 허용하는 버튼이나 화면 예외는 없다. 제한이 false가 되는 즉시 오버레이를 제거하며 기존 화면과 다이얼로그를 유지한다. 잠금 중 들어오는 따라가기 요청과 동의 모달은 기존 큐·내비게이터 흐름을 그대로 따르고 해제 뒤 응답할 수 있다. 통화·위치 공유·SSE와 세션에는 손대지 않는다. §12의 따라가기 시작 판정에도 이 잠금과 동일한 `DrivingState.restricted`를 전달한다. GPS 최초 이동 판정으로 따라가기를 취소하지 않는다.

**폰·사용 불가.** 폰은 이동 여부와 무관하게 주행 이벤트를 구독하지 않고 항상 `restricted=false`다. UI도 차량 모드를 재확인하므로 제한 상태를 잘못 전달해도 폰을 잠그지 않는다. 자동차가 아니거나 `android.car`가 없거나 Car 연결·조회에 실패하면 네이티브는 `{restricted:false, available:false}`를 한 번 보내고 스트림을 끝낸다. Flutter는 unavailable·잘못된 이벤트·채널 오류·스트림 종료 시 잠금을 해제한다. 구독 cancel과 Activity의 엔진 정리 경로에서 리스너와 Car 연결을 해제하고 `AppServices.dispose()`에서 Dart 구독도 해제한다.

**근거·검증.** [Pleos SDK 안내](https://document.pleos.ai/docs/pleos-only/vehicle-app-planning-guide/pleos-connect-sdk-api)는 차속·기어 등의 표준 데이터를 AAOS Car API로 안내한다. [Pleos 주행 규제 개발 가이드](https://document.pleos.ai/docs/pleos-only/vehicle-app-developer-guide/driving-restriction-development-guide)는 DO 선언 앱도 CarUxRestrictions와 ActiveRestrictions에 따라 UX 제한을 직접 적용하도록 한다. [Android CarUxRestrictionsManager](https://developer.android.com/reference/android/car/drivingstate/CarUxRestrictionsManager)의 현재 값·리스너 API를 사용한다. 로컬 근거는 `pleos-sdk-inventory.md` §0.3, `contest-recheck-2026-10-23.md` §4(h), `emulator-handson-modumoa.md` §4.1이다. 상태 파싱·오류·폰 미구독·구독 해제는 `driving_state_test.dart`, 전체 터치 차단·즉시 해제·폰 예외·다이얼로그 보존은 `driving_lock_test.dart`로 검사한다. Pleos 에뮬레이터의 Drive/40 km/h → Park/0 km/h 및 실제 기기의 터치·통화·위치 전송 유지는 별도 확인 대상이다.

## 18. 접수용 release 빌드(G9, 2026-11-13)

**release 서명.** `app/android/app/build.gradle.kts`는 Flutter 표준 위치 `app/android/key.properties`(gitignore 대상)가 있으면 release 빌드를 그 키로 서명하고, 없으면 지금처럼 debug 키로 서명한다(다른 개발자의 `flutter run --release`를 깨지 않기 위해). 파일은 `storeFile`·`storePassword`·`keyAlias`·`keyPassword` 네 키의 Properties 형식이며, `storeFile` 절대경로에 한글·공백이 들어갈 수 있어 ISO-8859-1인 `Properties.load(InputStream)` 대신 UTF-8 Reader로 읽는다. 파일이 있는데 네 값 중 하나라도 비면 debug로 넘어가지 않고 키 이름만 적은 오류로 빌드를 멈춘다. 키스토어와 비밀번호는 저장소 밖 개인 보관 폴더에 두고 저장소에는 심볼릭 링크도 커밋하지 않는다. 인증서 주체는 `CN=UnaVo, OU=UnaVo, O=UnaVo, C=KR`로 실명을 넣지 않았다(공개 APK에서 누구나 읽을 수 있는 값).

**빌드 때 기본 서버 주소.** `SessionStore`의 기본 주소는 생성자 인자 `defaultBaseUrl` > `--dart-define=UNAVO_SERVER_URL=<주소>`(앞뒤 공백 제거 후 비어 있지 않을 때) > 플랫폼 기본값(iOS `http://127.0.0.1:8787`, 그 외 `http://10.0.2.2:8787`) 순이다(`resolveDefaultBaseUrl`). 사용자가 설정에서 저장한 주소가 기본값보다 우선인 규칙은 그대로다. 접수 APK는 심사 환경에서 주소를 손으로 바꾸지 않도록 공개 테스트 서버를 이 값으로 넣어 빌드한다.

접수 빌드 명령(arm64-v8a·x86_64 포함, 약 134 MB라 GitHub 파일 한도 100 MB를 넘어 Releases에 올린다):

```sh
cd app
flutter build apk --release --no-pub --dart-define-from-file=<지도 키 JSON> --dart-define=UNAVO_SERVER_URL=<공개 테스트 서버 주소>
```

## 19. 차량 화면 가로 배치(C1·C1b·C3, 2026-11-13)

**지시 원문 요지·적용 범위.** 태곤 님의 “홈화면이면 좌측 패널이 주 패널이 되어 화면 전체를”, “보조패널은 설정창으로”, “첫실행부터 … 로그인 카드 섹션이 세로”라는 지시에 따라 차량 모드의 화면을 전체 폭과 가로 배치로 바꾼다. 기준은 Pleos Connect 2560×1440·160dpi, 앱 가용 영역 약 1706×1206dp다. 이 절은 §13·§15·§16·§17의 **차량 보조 패널과 차량 배치** 설명을 갱신한다. 폰의 화면·키·동작, §14의 동의 규칙, 지도:통화 7:3 결정은 유지한다.

| 구분 | 차량 화면 구조 |
|---|---|
| A. 공통 셸 | `CarShell`의 `secondary`와 3:2 분할, 단일 패널 720dp 제한을 제거한다. `car-primary`가 안전 영역과 바깥 여백을 뺀 전체 폭을 쓴다. 방 밖 머리줄의 “우나보 UNAVO” 오른쪽에 `open-settings` 톱니를 둔다. 설정이 열려 있으면 금색 선택 상태를 유지한 채 비활성화하며, 다시 눌러도 상세·프로필 선택 모달·포커스를 바꾸지 않는다(C1b). 통화 방에서는 머리줄 없이 기존 `room-home`으로 로비에 돌아온 뒤 설정을 연다. |
| B. 보조 기능 이동 | `_Companion`·`_CompanionState`·`car-secondary` 및 친구/마이크 보조 탭을 제거한다. 설정의 친구 상세에 기존 `FriendsScreen` 전체(아이디 추가·목록·삭제·새로고침·통화방 이동)를 넣는다. 마이크 상세에는 입력 레벨 `MicLevel`을 포함한 기존 `MicScreen`을 넣는다. 친구에서 방을 열면 설정을 닫고 기존 방 진입 콜백으로 연결한다. |
| C. 설정 | 왼쪽은 80dp 아이콘 메뉴의 세로 목록, 오른쪽 `car-settings-detail`은 선택한 항목의 내용이다. 처음에는 프로필이 선택된다. 메뉴는 프로필·친구·마이크·통화 음량·서버 주소·약관·동의 문서·지도 출처·로그아웃 순서다. 메뉴 선택은 내용만 바꾸며, 로그아웃은 오른쪽의 기존 `settings-logout` 버튼을 눌러야 실행한다. 차량 2단 설정은 머리줄 `settings-back` 하나로 로비에 돌아가며, 프로필·마이크·서버 주소·약관·동의 문서·지도 출처의 상세 뒤로 버튼은 표시하지 않는다(C1b). 프로필 저장은 오른쪽에, 서버 저장·문서 전환·라이선스 등 상세 고유 동작은 그대로 남긴다. |
| D. 로비 | `car-lobby-create` 왼쪽에 새 방 이름/만들기와 방 코드/입장을, `car-lobby-active` 오른쪽에 참여 중인 방 카드와 통화 상태를 둔다. 참여 중인 방이 없으면 `car-lobby-empty`에 테두리·채움 상자 없이 흐린 80dp 문 아이콘과 짧은 상태 문구를 표시한다(C1b). 입력·버튼·탭 동작이 없는 읽기 전용 상태다. 기존 `joinedRoomReason` 문구는 왼쪽에 한 번만 표시한다. 방 생성·입장 제한 및 복원 가능한 방 처리, 홈 이동 중 통화 유지 규칙은 그대로다. |
| E. 로그인·가입 | 넓은 카드 상단에 로그인/가입 전환과 서버 주소 아이콘을 둔다. 로그인은 아이디·비밀번호·시작, 가입은 아이디·비밀번호·표시 이름·만 14세 확인·시작을 한 줄로 놓고 시작 버튼을 오른쪽에 둔다. 입력·시작은 같이 고정하고 서버 주소와 오류는 아래에서 스크롤한다. 머리줄의 설정도 서버 주소 표시를 전환한다. 가입 검증·연령 확인·저장·요청 내용은 기존 경로를 쓴다. |
| F. 첫 동의 | 개인정보 처리방침(필수)과 위치정보 수집·이용 동의(선택)를 가로 두 열로 둔다. 각 열은 독립적으로 스크롤하고 기존 요약·체크·전문 펼치기 키와 본문을 유지한다. 미동의 `back`과 동의 `check`는 아래 오른쪽에 고정한다. 문서 로드·필수 항목 체크·항목별 저장·서버 기록·미동의 안내 흐름을 바꾸지 않는다. 필수 동의 전 머리줄의 설정은 비활성으로, 동의를 우회하지 않는다. |
| G. 통화 방 | 보조 패널 없이 전체 폭을 쓴다. 따라가기 중 왼쪽 지도 7, 오른쪽 통화 3의 `Expanded` 비율을 유지한다. 차량 도크는 마이크·통화 음량·홈·나가기 네 버튼을 실제 개수대로 배치하고 가로 스크롤을 제거한다. 기준 영역에서는 네 버튼이 한 줄에 모두 보인다. 더 좁은 창에서는 80dp 크기와 24dp 간격을 유지하며 여러 줄로 감싸고, 도크 높이만큼 참여자 목록 아래 여백도 늘린다. 지도 없는 넓은 방은 참여자 카드를 두 열로 배치한다. 음량 확장·자동 접기·퇴장·따라가기·지도 전체 화면 동작은 유지한다. |

**설정 상세와 내비게이션.** 대시보드의 기존 주 패널 Navigator 한 개를 유지하고 상세 영역에 별도 Navigator를 만들지 않는다. 프로필 사진 선택 모달도 전체 폭 주 패널의 Navigator를 사용하므로 오른쪽 상세 열 안에 갇히지 않는다. 동의·안내 모달은 기존 루트 Navigator에서 화면 가운데에 표시한다. `settings-profile`·`settings-mic`·`settings-server`·`settings-legal`·`settings-map` 등 기존 키를 유지하고, 새 메뉴 키는 `car-settings-menu-<항목>`이다. `settings-volume`·`settings-call-volume-slider`·`settings-logout`은 해당 상세 내용에서 유지한다.

C1b의 상세 뒤로 숨김은 공용 프로필·서버·문서·출처 화면의 `showBackButton`을 차량 설정 호출부에서만 끄는 방식이다. 마이크는 차량 상세에 `MicScreen`을 직접 넣으며 폰의 `_SettingsPage`와 `settings-mic-back`을 유지한다. 폰 단일 페이지와 독립적으로 연 화면의 뒤로 버튼 기본값·키·동작은 바꾸지 않는다. `CarDashboard`의 설정 열림 상태를 `CarShell.settingsSelected`로 전달하고 톱니의 콜백을 null로 만든다. 이 버튼만 `PanelButton.dimWhenDisabled: false`로 금색 선택 표시를 보존하며, 다른 비활성 버튼의 기존 색 규칙과 폰 동작은 유지한다.

**머리줄 접근성(C3).** 중첩 Navigator의 `MaterialPage`도 투명 `ModalBarrier`를 만든다. 이 장벽의 `BlockSemantics`는 가장 가까운 semantic container까지 이전에 그린 형제의 접근성을 차단하므로, C1의 머리줄 이동 후 로비·설정 route가 머리줄까지 지웠다. 설치된 Flutter의 `ModalRoute.buildModalBarrier` → `ModalBarrier.build` → 렌더러의 `isBlockingPreviousSibling` 전파 경로로 확인했다. `car-primary` 내부를 `Semantics(container: true, explicitChildNodes: true)`로 감싸 차단을 주 패널 안에 한정한다. 머리줄에도 같은 속성을 사용해 “우나보”·“UNAVO”와 “설정” 버튼을 각각 독립 노드로 유지한다. 설정 열림 중에는 버튼의 선택·비활성 상태와 tap action 없음이 그대로 노출된다. 첫 동의에서는 비선택·비활성, 로그인과 로비에서는 비선택·활성이다. 주 패널의 사진 선택 모달은 뒤의 설정 메뉴·프로필 편집을 계속 가리고, 루트 동의 안내 모달은 머리줄을 포함한 셸 전체를 가린다.

약관/동의 문서는 새 법률 내용을 만들지 않고 기존 정본 `privacy.md` / `location.md`를 재사용한다. “약관” 메뉴는 개인정보 처리방침을, “동의 문서” 메뉴는 위치정보 동의문을 먼저 열며, 두 화면 모두 기존 두 문서 전환과 읽기 전용 규칙을 유지한다. 서버 주소는 같은 출처이면 저장 후 차량 상세를 유지하고, 다른 출처이면 기존 서버에서 로그아웃·방/통화 정리를 마친 뒤 주소를 바꾸는 기존 경로를 사용한다. 오류이면 세션과 주소를 보존한다. 폰은 기존 서버 저장 후 뒤로 이동을 유지한다.

**키보드·조작부.** `CarShell`만 안전 영역과 하단 IME inset을 소비하며 중첩 화면에는 소비한 padding/viewPadding/viewInsets를 0으로 전달한다. 중첩 Scaffold가 키보드 높이를 다시 빼지 않게 한다. 차량 로그인/가입은 키보드로 높이가 줄어도 열 너비·입력/시작 위치를 유지하고, 설정의 서버 주소도 입력·저장을 가로 한 줄로 둔다. 차량 조작부는 `ControlScale.target` 80dp, 새 배치와 친구/마이크 조작부 간격은 `ControlScale.gap` 24dp를 사용한다. 폰의 기존 간격은 12dp다. 조작 버튼은 아이콘만 표시하고 접근성 라벨·선택 상태는 유지한다. 방 카드의 이름·코드 등 정보 표시를 제거하지 않는다.

C1b의 차량 `PanelField`는 바깥 영역뿐 아니라 `InputDecorator`가 실제 칠하는 상자도 80dp다. 접두 아이콘 영역의 높이를 `ControlScale.target`으로 제한하고 아이콘 자체는 36dp로 가운데 정렬한다. 입력·placeholder는 기존 본문 `UnavoType.body`(16sp·줄높이 1.4)에 맞추고 세로 가운데에 둔다. 차량 입력은 외부로 부푸는 `FocusRing` 대신 같은 상자에 그리는 3dp 금색 `focusedBorder`만 사용해 포커스 전후 크기·위치를 유지한다. 로그인·가입·로비·친구·서버 주소 모두 공용 입력을 쓰며 같은 줄 80dp 버튼과 중앙이 일치한다. 폰은 기존 56dp 입력 영역·48dp 보이는 상자·외부 포커스 링을 유지한다.

**폰과의 차이·보존 경계.** 폰의 로그인·가입·동의·로비·설정은 기존 세로 구조와 화면 이동을 유지한다. 폰의 방 도크는 가운데 홈과 작은 폭의 가로 스크롤을 유지한다. 차량에서만 설정 메뉴 선택이 오른쪽 내용을 바꾸고, 차량 도크의 홈은 네 버튼 중 세 번째에 놓인다. `DrivingLockOverlay`와 주행 이벤트, 미디어·위치·동의 서비스, 법률 원문, 패키지 및 네이티브 빌드 설정은 수정하지 않는다.

**검증 범위.** `auth_widget_test.dart`에 차량 1706×1206/1320×940 로그인·가입의 가로 정렬, 45% IME에서 입력/시작 노출, 서버 주소 유지와 가입 연령 확인을 추가한다. `f2_layout_test.dart`는 전체 폭 단일 패널과 IME, `home_settings_navigation_test.dart`는 설정 2단·첫 프로필 선택·친구/마이크 이동·로그아웃 2단계·로비의 활성/빈 상태·내비게이션과 통화 보존, `legal_consent_test.dart`는 동의 두 열과 모달 중앙, `room_consent_flow_test.dart`는 7:3 비율과 도크 네 버튼의 화면 내 노출을 검사한다. 이 작업에서는 Dart 포맷·정적 분석까지만 수행하며 Flutter 위젯 테스트 실행과 빌드, Pleos 실제 화면 확인은 메인이 담당한다.

C1b는 `panel_field_test.dart`와 `support/car_field_expectations.dart`에서 `InputDecorator.containerOf`로 실제 채움·테두리 영역의 80dp 높이, 버튼·입력·아이콘·placeholder의 세로 중앙, 포커스 전후 경계 일치, 일반/비밀번호/비활성 입력 및 폰 기존 표시를 검사한다. 로그인·가입·친구·로비·서버 주소 통합 검사에도 같은 실제 상자 검사를 적용한다. 설정 통합 검사는 차량 상세 뒤로 없음·폰 뒤로 유지·저장/문서 전환 유지, 빈 상태의 테두리/입력/버튼/탭 부재, 톱니의 금색 선택·비활성 접근성과 재탭 시 상세/모달 보존·닫은 뒤 재활성화를 포함한다. C1·C2 구현과 따라가기 마커는 유지한다.

C3는 `enterText` 후 기존 pump 도우미를 거쳐 포커스를 검사하고, 빈 로비·톱니 검사의 SemanticsHandle을 테스트 본문 `finally`에서 해제한다. `support/car_shell_expectations.dart`는 실제 semantics 트리에서 머리줄 문구·버튼을 찾고 `open-settings`의 노드와 같은지도 확인한다. 로그인·가입 2종×2크기, 로비·설정, 첫 동의와 루트 모달의 검사에서 주 패널의 입력·버튼·설정 메뉴 접근성과 모달 차단도 고정한다. §13의 C3 검사는 실제 painter의 채움 크기·흰 2dp 외곽선·옅은 대비선·프로필 2dp 간격·회전 시 잘림 없음·이름표 포함 56dp 상한, 네이버의 고정 프로필/각도 갱신 및 브이월드 폰·차량의 회전/정차 방향 유지를 포함한다. 실행은 메인의 `flutter test`에 맡기며 여기서는 Dart 정적 분석까지만 수행한다.

## 20. 출발 준비·하차 보호·계정당 한 기기 송신(D3·D4, 2026-11-13)

**출발 준비.** `RoomReadyStore`는 방·계정별 준비 여부를 메모리에만 보관한다. `PUT /v1/rooms/:code/ready {ready:boolean}`는 현재 송신 기기만 사용할 수 있고 `{handle, ready, revision}`을 반환하며 같은 데이터를 `ready-changed` SSE로 방에 알린다. `GET /v1/rooms/:code`, `GET /v1/me`의 방 멤버, SSE `hello.members`는 `ready`·`readyRevision`을 포함한다. 기본값은 false다. 준비 revision은 위치 revision과 별개이며 늦은 HTTP/hello가 이미 받은 새 준비 상태를 덮지 않는다. 방 퇴장, 기기 교체, 송신 토큰 로그아웃 시 준비를 취소하고 마지막 멤버 퇴장 시 방의 메모리 상태를 지운다. 방 상단의 체크 아이콘·준비 인원/전체 인원과 `room-ready-toggle`, 카드의 `member-ready-<handle>`을 통해 표시한다. 새 조작부는 모두 아이콘이며 접근성 라벨·선택 상태를 제공한다.

**화면 가독성(D4·D4b).** `RoomScreen`은 멤버 수(`room-member-count`)와 체크·준비 인원/전체 인원(`room-ready-summary`)을 폭이 허용하면 같은 줄에 놓는다. `ControlScale`에 따라 숫자는 차량 24sp·폰 18sp(w600, 줄높이 1.4), 아이콘은 차량 36dp·폰 24dp이며, 멤버 이름의 18sp보다 작지 않다. 한 명 이상이고 모두 준비되면 요약 숫자와 체크를 `UnavoColors.onCall`로 강조한다. 준비 토글은 줄 맨 오른쪽의 차량 80×80dp·폰 56×56dp 아이콘 버튼이며 기존 선택 색과 동작을 유지한다. 연결 상태(`room-connection-status`)는 토글 왼쪽에서 세로 중앙을 맞춘다. 요약 안쪽 가용 폭이 차량 440dp·폰 300dp 미만이면 연결 표시를 윗줄로 옮겨 토글과 가로 중심을 맞춘다. 멤버 수·준비 수 묶음과 토글이 함께 들어가지 않으면 `OverflowBar`가 토글을 다음 줄 오른쪽으로 옮기고, 숫자 묶음의 `Wrap`도 필요할 때 줄바꿈한다. 따라서 200dp 통화 패널에서도 숫자·연결 표시·토글을 모두 유지한다. 지도 옆의 좁은 통화 패널에서도 글자나 터치 영역을 줄이지 않는다. `MemberTile`의 준비 표시는 차량 36dp 원형 배지 안의 28dp 체크, 폰 24dp 배지 안의 18dp 체크다. 기존 `member-ready-<handle>` 키는 체크에 남으며 카드의 “출발 준비됨” 접근성 문구를 유지한다.

`room-vehicle-notice`는 배경·1dp 테두리가 있는 가로 배너다. 차량 36dp·폰 24dp 상태 아이콘과 차량 24sp·폰 18sp 안내(w500, 줄높이 1.4)를 나란히 놓고 오른쪽에 기존 재개/이어받기 버튼을 둔다. 차량 전체 방에서는 하차 문장이 한 줄로 보이며 좁은 패널·폰에서는 문구를 자르거나 축소하지 않고 줄바꿈한다. 하차 아이콘은 `micoff`, 기기 교체는 `mobile`, 그 밖의 차량 준비 안내는 `car`다. `room-exit-resume`은 기존 연결 표시의 `refresh`와 다른 Tabler outline `player-play`(`assets/icons/ui-player-play.svg`)를 사용하고, 접근성 라벨 “차량 마이크와 이전 위치 공유 다시 켜기”와 기존 재개 동작을 유지한다. 배너 안쪽과 준비 줄의 오른쪽 여백을 맞춰 두 버튼의 오른쪽 끝이 일치한다. 모든 버튼은 아이콘만 표시하며 준비·하차·기기 교체의 세션/채널/서버 처리는 변경하지 않는다.

**차량 신호.** 차량 모드에서만 `VehicleState`가 `unavo/vehicle`을 구독한다. Android `VehicleChannel`은 `FEATURE_AUTOMOTIVE`를 다시 확인한 뒤 Pleos `Vehicle:2.3.2`를 초기화한다. `checkDoorPositionCapabilities`가 돌려준 `DoorArea`들만 `registerDoorPosition`에 등록하고 각 영역의 초기 `getCurrentDoorPosition`도 받는다. 0은 닫힘, 양수는 열림이다. null·오류·범위 밖 값은 닫힘으로 간주하지 않는다. 초기 조회가 늦게 끝나도 이미 받은 리스너 값을 덮지 않는다. 운전석은 지원 영역 중 `ROW_1_LEFT`, 없으면 `ROW_1_RIGHT`가 포함된 앞문을 사용한다. 앞문이 없으면 하차를 추정하지 않는다. 구독 해제/엔진 정리 시 문·기어 리스너를 해제하며 진행 중인 capability/get 콜백이 끝난 뒤 `Vehicle.release()`를 호출한다. 콜백이 영원히 돌아오지 않으면 SDK 참조를 조기 해제하지 않고 프로세스 수명까지 보유할 수 있다.

기어는 기존 optional `android.car` 연결을 재사용하는 `CarPropertyManager.GEAR_SELECTION`(area 0, ONCHANGE)이다. `VehicleGear.GEAR_PARK`만 P로 인정하며 UNKNOWN·오류는 미지원이다. [Android VehiclePropertyIds](https://developer.android.com/reference/android/car/VehiclePropertyIds#GEAR_SELECTION)는 읽기에 normal `Car.PERMISSION_POWERTRAIN`을 명시하고, [AOSP Car manifest](https://android.googlesource.com/platform/packages/services/Car/+/refs/heads/master/service/AndroidManifest.xml)는 `android.car.permission.CAR_POWERTRAIN`을 normal로 선언한다. manifest에는 이 권한과 normal `pleos.car.permission.CAR_DOORS`만 추가한다. CAR_SPEED, CAR_DRIVING_STATE, 기어/문 런타임 권한 요청은 없다. 기존 UX restrictions 잠금은 그대로 적용한다.

지원 문 전부의 값과 기어를 받으면 모두 닫힘+P에서만 준비할 수 있다. 문이 열려 있으면 “문이 열려 있습니다”, P가 아니면 “P단에서 준비할 수 있습니다”를 표시한다. 준비 중 문 열림/P 이탈은 로컬에서 즉시 취소하고 준비 PUT을 직렬화해 서버에도 false를 보낸다. 이미 전송한 true가 늦게 끝나도 false를 뒤이어 전송하며, 취소 전송 실패는 2초 간격으로 재시도한다. 닫힘/P 복귀가 준비를 자동으로 켜지 않는다. 폰은 차량 채널을 구독하지 않고 수동 토글만 한다. 차량도 SDK·기어를 못 받으면 수동 토글로 대체하고 `unavo-vehicle`에 이유를 기록한다.

**음성.** 준비 취소는 화면 안내와 함께 “준비가 취소됐습니다”를 말한다. D2 `FollowVoiceGuidance`의 직렬 큐·10초 만료·세대별 취소·중복 억제를 재사용한다. `SpeechOutputCoordinator`는 따라가기와 준비 안내를 실제 TTS 하나에 직렬로 보내되 중지는 각 기능의 발화에만 적용한다. 하차로 위치 공유가 끝나며 따라가기 음성이 정리되어도 준비 취소 음성을 끊지 않는다. 새 준비/방 종료/기기 교체는 이전 준비 안내를 폐기한다. D2 공유 중지 문장은 화면과 같은 “○○ 님이 위치 공유를 중지했습니다”로 통일하며 지연 문장은 유지한다.

**하차 보호.** 차량 설정 `car-settings-menu-exit`에서 마이크+위치 중지(기본), 마이크만 끄기, 아무것도 안 함 중 하나를 고른다. 선택은 계정이 아닌 이 설치의 SharedPreferences `vehicle.exitProtection`에 저장하며 로그아웃 후에도 보존한다. 지원 앞문 열림+P 상태로 진입하면 고른 동작을 실행한다. 연속된 같은 상태는 중복 실행하지 않는다. 한 번 입장한 방은 SSE가 끊겨도 로컬 하차 보호와 준비 취소가 동작한다. 최초 hello 전에는 다른 기기의 스냅샷을 보고 준비 취소를 보내지 않는다. 첫 두 동작은 마이크를 음소거하고 기본 동작은 진행 중인 위치 시작/관찰/송신도 중단한다. 사실 안내와 `room-exit-resume` 아이콘을 표시한다. 문 닫힘·P 복귀·홈 복귀로 재개하지 않는다. 사용자가 재개 아이콘을 누르면 마이크를 켜고 보호 직전에 공유 중이던 위치만 다시 시작한다. 기존 따라가기 관계는 복원하지 않고 새 요청/동의를 거친다. 하차 자체는 수신 스피커/통화 연결을 유지한다.

**입장과 송신 기기.** 방 멤버십은 기존처럼 계정(handle) 하나다. 별도로 방·계정마다 송신 기기 하나를 `RoomEventHub` 메모리에 둔다. 기기 키는 인증 토큰 해시+`x-unavo-device` 헤더(앱 API 인스턴스에서 생성한 128비트 난수, 해당 인스턴스의 HTTP/SSE 재시도에 공통)다. 헤더가 없는 기존 클라이언트는 인증 토큰 해시를 사용한다. ID나 토큰을 SSE·멤버 응답에 공개하지 않는다.

명시적 입장은 방 생성 성공, `POST /join` 성공, 새 `GET /events` 연결이다. 기존 “참여 중” 카드로 `RoomSession.open`을 호출하면 새 이벤트 스트림을 열므로 폰이 직접 누른 시점에 송신 기기가 된다. 명시적 입장은 기존 송신자가 있어도 이 기기로 교체하며, 동일 기기의 중복 입장은 준비/위치/통화를 취소하지 않는다. SSE 내부 자동 재접속은 첫 요청 이후 반드시 `/events?resume=1`을 쓴다. 인증과 현재 방 멤버십을 확인한 뒤 **그 방·계정의 송신자가 없으면 이 기기를 등록하고, 같은 기기이면 유지하며, 다른 기기가 송신자일 때만 `409 DEVICE_REPLACED`로 거절한다**. 빈 자리는 서버 재시작으로 메모리가 사라졌거나 송신 토큰이 로그아웃한 경우에도 생긴다. 단순 소켓 단절은 송신자를 지우지 않으므로 이전 기기의 자동 복귀가 현재 기기를 밀어낼 수 없다. 멤버십까지 끝낸 퇴장은 resume으로 되살리지 않는다.

**자동 복구(D3b).** 서버 재시작 후에도 DB의 방·계정·멤버십·인증 토큰은 유지된다. SSE 재시도가 빈 송신 자리를 먼저 확보한 뒤 서버가 `hello`와 통화 시그널 백로그를 전달하고, 앱의 `ApiClient`는 성공한 재연결에서 `Reconnected`를 먼저 발생시킨다. 앱은 사용자의 재입장 없이 같은 방에서 멤버/스냅샷을 갱신하고 살아 있는 통화를 유지하며 누락된 peer 협상만 복구한다. `Reconnected`는 `/join`을 호출하지 않고, 다른 명시 입장을 덮을 수 있는 POST join의 HTTP 자동 재시도도 계속 금지한다. resume보다 먼저 도착한 HTTP 송신 요청은 소유권을 얻지 않으며 송신자가 비어 있으면 `503 SENDER_UNAVAILABLE`로 일시 실패한다. 이를 기기 교체로 처리해 자동 복구를 중단하지 않는다.

위치 공유는 기존 관찰을 유지하여 연결 회복 후 다음 표본부터 전송한다. 통신 단절 동안 서버에 남아 있는 따라가기·궤적은 hello에서 복원한다. 서버 재시작으로 소실된 위치·따라가기·궤적·준비는 빈 스냅샷/false가 정본이며, 기존처럼 따라가기를 몰래 재요청하거나 동의를 복원하지 않는다. 앱은 새 연결에서 위치 revision뿐 아니라 준비 revision의 비교 기준도 초기화하고 이전 연결의 진행 중인 준비 응답을 무시하여, 재시작 후 낮은 revision의 hello와 준비 이벤트를 적용한다. 로컬에서 필요한 준비 취소는 새 연결에서도 이어서 전송한다.

다른 기기가 명시적으로 입장하면 이전 기기에 `device-replaced {handle}`를 보낸 뒤 그 기기의 SSE를 닫는다. 준비, 위치, 따라가기 관계, 이전 기기로 오고 간 시그널 백로그와 위치 순번/속도 제한 기록을 정리한다. 다른 계정에는 `member-device-changed {handle}`를 보내 같은 계정의 이전 WebRTC peer를 닫고 새 협상을 시작하게 한다. 멤버를 추가하지 않으므로 같은 사람이 두 카드로 보이지 않는다. WebRTC `signal`은 송신 기기의 최신 소켓 하나로만 전달하며 같은 기기의 겹친 소켓에도 복제하지 않는다. 이전 기기의 signal·위치 POST, ready PUT, location/follow DELETE, follow 응답 및 leave는 `409 DEVICE_REPLACED`로 거절한다. 본문을 기다린 뒤 소유권과 인증을 다시 검사한다. 이전 기기의 늦은 위치 DELETE가 새 기기의 공유를 지울 수 없다.

반복 leave는 현재 멤버일 때만 송신 권한을 요구한다. 이미 나간 멤버도 자기 준비·구독·송신자·위치 잔여 상태와 과거 버전에서 남은 빈 방을 정리한 뒤 204를 반환한다. 참여 이력이 없는 계정은 계속 403이며 현재 다른 기기의 멤버십을 지울 수 없다.

앱은 `device-replaced`를 일반 이벤트 큐보다 먼저 처리해 마이크·수신 게인을 즉시 끄고 WebRTC/통화 서비스를 종료하며 위치 관찰·송신을 중지한다. 자동 재접속/통화 복구를 막고 “다른 기기에서 이어받았습니다”와 `room-take-back` 아이콘을 표시한다. SSE를 놓친 경우 `resume=1`의 409도 같은 종료 동작으로 연결한다. 사용자가 다시 가져오기를 누를 때에만 기존 정리를 기다린 뒤 새 이벤트 스트림으로 입장한다. 위치 공유는 재입장만으로 재개하지 않는다. 교체된 기기의 방 나가기는 해당 기기 화면만 정리하며 현재 송신 기기의 계정 멤버십을 지우지 않는다.

**설계 경계.** (1) 하차는 차량의 자기 송신만 제어하며 폰 자동 접속/통화 이전이나 자동 이전 승인 설정이 없다. (2) 하차 안내의 응답으로 통화를 넘기는 동작이 없고 재개 아이콘은 그 차량의 로컬 동작이다. (3) BLE·초음파·근거리 감지로 기기를 전환하지 않으며 다시 탈 때도 사용자가 직접 켠다. (4) 같은 계정의 나중 명시적 입장 기기만 시그널을 받아 통화에 참여하고 이전 기기는 수신까지 정리한다. (5) 음성 통화 범위를 유지하며 영상·차량 상담원·긴급 통화 연동을 추가하지 않는다.

**검증 분담.** 서버 `ready_devices.test.ts`, 변경된 `rooms.test.ts`·`api.test.ts`는 준비 수명, 여러 토큰/동일 토큰의 여러 기기, 단일 시그널 수신, 이전 송신 거절, 재가져오기, 본문 대기 중 교체를 검사한다. 앱의 `vehicle_state_test.dart`, `room_vehicle_session_test.dart`, `vehicle_widgets_test.dart`, `speech_coordinator_test.dart` 및 기존 SSE/음성/재접속 테스트를 갱신한다. 여기서는 Dart 정적 분석·포맷과 Node 구문 검사만 수행한다. 서버 테스트·Flutter 테스트·Gradle 빌드, Virtual Console에서 문/기어 조작, iPhone/시뮬레이터의 두 기기 통화 확인과 서버 배포는 메인이 수행한다.

D3b는 같은 SQLite 파일을 닫고 다시 여는 새 HTTP 서버의 resume·시그널 복구, 송신자 없는 동안의 일시적 HTTP 실패, 동일 기기 통신 복구의 상태 보존, 다른 기기 resume 거절과 송신 토큰 로그아웃 후 빈 자리 복구를 추가한다. `locations.test.ts`는 실제 join을 통한 follow 응답 권한과 반복 leave의 빈 방/메모리 정리를 검사한다. 앱은 join 없는 통화·시그널·준비 복구와 위치 관찰 유지/hello 기준 따라가기 복구를 검사한다. 위젯이 없는 음성 큐·차량 상태 검사는 `test()`와 `pumpEventQueue()`로 처리하고, 음성 만료 시각은 주입한 시계로 제어한다.

D4의 `vehicle_widgets_test.dart`는 실제 차량 셸을 포함한 1706×1206dp(2560×1440 Pleos 앱 영역 상당)·1320×940dp, 폰 412×915·320×568dp와 지도 통화 패널 상당의 차량 381dp·폰 274.5dp 폭을 검사한다. `getSize`·`closeTo`로 준비/재개 터치 영역, 체크/배지 크기, 멤버 수·준비 수·연결 상태·토글의 정렬과 비겹침, 배너 내부 및 패널 경계, 배너와 멤버/도크 분리를 고정한다. 전원 준비 시 색과 해제 시 복귀, 준비 취소가 붙은 긴 하차 문장의 한 줄 표시, 좁은 패널의 줄바꿈, `refresh`와 `player-play` 구별, 접근성 문구·아이콘 전용 버튼·문 닫힘 후 수동 재개를 확인한다. SemanticsHandle은 테스트 본문의 `finally`에서 해제한다. 새 SVG는 기존 `icons_smoke_test.dart`의 전체 등록·첫 진입/재진입 픽셀 검사 대상에 자동 포함된다. D4는 Dart 포맷·`dart analyze`까지만 실행하며 `flutter test`와 에뮬레이터 화면 확인은 메인이 수행한다.


## 따라가기 추천 경로 (Flutter)

`RoomSession.followRoute`가 수락된 `followRequestId`별 안내 상태를 메모리에 소유한다. 지도/패널 재생성은 상태를 초기화하지 않는다. `RoomMap.following`은 기존 카메라 추적 값이다. 기본 A 「따라가기」는 양쪽 유효 위치와 서버 동의 기록이 준비될 때 마지막 송신 성공 원점과 앞차 최신 표본 P0를 한 번 고정한다. B 「합류 후 따라가기」는 연속된 궤적 선분에 투영한 위치에서 궤적을 따라 60 m 앞의 J를 선택한다. J는 양끝 `(stream,seq)`와 비율로 식별한다. 모드 전환은 follow 관계를 해제하지 않으며 주행 제한은 UI와 컨트롤러 양쪽에서 검사한다.

`POST /v1/rooms/:code/follow-route`는 schemaVersion 1 계약을 사용한다. 앱은 hello의 `followRoute.enabled`, `provider: naver`, `routeOption: traoptimal`을 확인하고 Naver `traoptimal` 결과만 받아 「추천 경로」로 표시한다. 기능 메타데이터가 없거나 문서의 제공처와 다르면 비활성화한다. HTTP 상한은 8초이며 요청별 연결을 취소하므로 위치 송신·SSE·통화 연결을 닫지 않는다. 방·계정 세션·기기·관계·모드·세대·계산·HTTP 시도·기준점이 달라진 늦은 성공과 실패를 버린다. 신규 계산의 입력 검증은 즉시 요청하고 서버의 외부 호출 제한을 따른다. 일시 오류는 같은 입력으로 30초 이상 간격, 최대 2회 재시도한다. 입력 유효 창은 최대 120초다. 응답/형상은 현재 안내 메모리 외에 저장하지 않는다.

지도는 청록색 윤곽선 추천 경로와 금색 실제 궤적을 별도로 그린다. P0/J 이전 구간은 활성 궤적에서 제외하며 누락 seq·stream 변경·시간 역전·10초 초과 공백·불량 정확도·비정상 도약에서는 선을 끊는다. 실패를 직선으로 대신하지 않는다. 기준점 25 m 및 연결선 끝 25 m 접근 뒤 같은 가지에서 거리 25 m, 방향 차 60도, 서로 다른 3표본/2초/10 m 전진을 모두 확인하면 연결선과 표식을 제거한다. 차량 음성은 합류 회차당 “앞차가 지나간 경로를 따라갑니다” 한 번이다. B는 실제 재합류 때만 새 회차를 시작한다. A는 지속 이탈 때 자동 계산하지 않고 B는 60 m 초과, 5초/3표본 및 30초 간격을 검사한다. 가지 모호성의 구현 초깃값은 진행거리 차 40 m 초과인 다른 투영점이 25 m 안에 있고 최근접 거리 차가 5 m 이내인 경우 보류다. 현재 진행 구간 탐색은 저장된 진행도에서 최대 3 m 뒤부터 `max(120 m, 이번 이동거리 + 50 m)` 앞까지로 제한한다. 이는 리허설 초깃값이며 평행 도로·고가/지하를 구별하는 맵매칭 보장이 아니다.

자기 위치는 송신 성공 표본의 원래 로컬 수집 시점부터 단조 시계로 나이를 잰다. 상대 위치는 hello/위치 SSE의 `serverNowMs`와 원래 `receivedAt`·`at`로 수신 당시 나이를 계산한 뒤 단조 시계 경과를 더한다. 중복 참조/같은 측정 시각은 새 측정이 아니다. 서버 시각이 없는 스냅샷은 신선도를 추정하지 않고 보류한다. 10초 안내 보류는 기존 90초 stale/30초 sweep 관계 종료와 별개다. 서버 재시작의 관계 소실은 안내만 지우며 독립적인 자기 위치 공유는 유지한다. 프로세스가 옛 기준점을 잃은 수락 관계는 명시 재설정을 요구한다.

개인정보·위치 동의는 버전 4다. 송수신 대화상자는 동의 저장 성공을 기다리며, 서버는 앞차·뒷차 양쪽 실제 기록을 검사해야 한다. 제공처는 네이버 클라우드 플랫폼 Maps(Directions 5), 항목은 뒷차 출발·앞차 기준점 좌표, 시점은 안내 시작·B 재계산이다. 방의 상태 문구는 양쪽에 이 제공 조건을 알린다. 제공처의 보유 조건은 공급자 정책을 따르며 임의 기간을 명시하지 않는다. 운영자는 기존 계정 범위·외부 처리 조건을 확인할 때까지 `ROUTE_PROVIDER=disabled`를 유지한다.

이번 제출 범위는 앱 지도 위의 두 경로 방식과 합류 상태 안내까지로 한다. 선택한 합류점을 차량 내장 내비에 전달하는 부분은 후속 구현으로 남기며, 제출 시연에서는 구현된 기능으로 설명하지 않는다.
