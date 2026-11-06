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
| `POST /v1/auth/signup` | `{handle, password, displayName}` | `201 {user, token}` | 중복 아이디 `409` |
| `POST /v1/auth/login` | `{handle, password}` | `200 {user, token}` | 실패 `401` |
| `POST /v1/auth/logout` | — | `204` | 토큰 폐기. 그 토큰으로 열린 SSE 연결도 즉시 닫는다(다른 기기의 토큰은 유지) |
| `GET /v1/me` | — | `{user, room: null 또는 {code, name, createdBy, createdAt, members}}` | `left_at IS NULL`인 방 중 `joined_at`이 가장 최근인 하나(동률은 방 ID 내림차순) |
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

Dart는 인증·서버 주소·HTTP/SSE·방 세션·미디어 엔진 인터페이스 및 화면 상태를 소유한다. 상태 관리는 ChangeNotifier, 화면 이동은 기본 Navigator다. HTTP/SSE는 dart:io HttpClient, 영속 저장은 shared_preferences, SVG 아이콘은 flutter_svg를 사용한다.

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
