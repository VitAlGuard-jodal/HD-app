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

Dart는 인증·서버 주소·HTTP/SSE·방 세션·미디어 엔진 인터페이스 및 화면 상태를 소유한다. 상태 관리는 ChangeNotifier, 화면 이동은 기본 Navigator다. HTTP/SSE는 dart:io HttpClient, 영속 저장은 shared_preferences, SVG 아이콘은 flutter_svg를 사용한다. 일반 요청·아바타 다운로드는 `ApiClient` 수명의 HttpClient 하나를 재사용하고 타임아웃은 해당 요청만 abort하거나 본문 구독을 취소하며, SSE는 구독 시도마다 별도 클라이언트를 쓰고 `AppServices.dispose/logout`은 `api.close()`로 공유 클라이언트를 정리한다.

**화면 구성(M8a).** 통화·방은 앱 수준의 `AppServices.rooms`·`calls`가 소유하며 화면 수명과 분리된다. `RoomScreen.onHome`은 폰에서는 방 route와 그 아래 설정 route를 루트까지 pop하고 홈 탭을 로비로 돌리며, 차량에서는 `_carRoomVisible=false`로 바꾼다. 방 나가기·통화 종료는 호출하지 않는다. 로비의 참여 중인 방 카드와 통화 중 상태 칩을 유지하고 카드에서 기존 `_openRoom`으로 복귀한다. 폰은 새 방 route를 push하고 차량은 `_carRoomVisible=true`로 전환한다.

폰 로비 우상단과 차량 보조 패널 우상단의 `settings` 톱니바퀴가 공용 `SettingsScreen`을 연다. 위에서부터 프로필(`ProfileScreen`), 통화 음량(`RoomSession.setCallVolume`·기존 저장/미디어 경로), 마이크(`MicScreen`), 서버 주소, 약관·동의 문서, 지도 출처(`MapCreditsScreen`), 로그아웃을 둔다. 서버 주소는 현재 `store.baseUrl`을 표시하고 `AuthScreen(serverSettingsOnly: true)`의 기존 서버 필드·주소 검증·저장 경로로 연결한다. 이 경로에서는 로그인/가입을 제출하지 않는다. 약관은 `legal_consent.dart`의 `LegalDocumentsScreen`에서 같은 번들 Markdown 렌더러로 읽으며 동의 값을 변경하지 않는다. 로그아웃은 로비에 있던 `services.logout()`과 오류 처리를 그대로 이동한다. 로비에는 프로필·로그아웃·지도 출처 버튼을 두지 않는다. 모든 조작 버튼은 아이콘이고 `ControlScale`로 폰/차량 크기를 맞춘다.

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

**복귀 정책(태곤 님 결정 11/9).** 프로세스가 살아 있는 채 통신만 끊겼다 돌아오면(터널) 같은 방에 자동 재입장하고 통화를 잇는다(위 reconcile). 앱을 **새로 켠 경우**(사용자가 끈 것이든 시스템이 죽인 것이든)는 메인 화면에 머물고 마이크·통화를 자동으로 켜지 않는다. `restoreSession` 은 `/v1/me` 만 읽어 `RoomSession.restorableRoom` 에 두고, 폰 방 목록·차 대시보드가 "참여 중인 방" 카드(방 이름·코드 + 입장 아이콘) 한 장을 보여 준다. 카드 탭 → 기존 입장 경로(`open` → hello → 자동 통화). `AppServices.initialize()` 의 네이티브 통화 상태 기반 자동 open 도 제거했다.

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

**배경 전송(M7, 결정 18-A).** 사용자가 기능별 동의 후 화면에서 공유를 켠 동안에는 잠금·앱 전환 뒤에도 위치 전송을 이어 간다. iOS는 “앱 사용 중” 권한으로 시작한 스트림에 `allowBackgroundLocationUpdates: true`, `showBackgroundLocationIndicator: true`, `pauseLocationUpdatesAutomatically: false`를 적용한다. Info.plist의 `UIBackgroundModes`는 기존 `audio`와 `location`이며 “항상 허용” 권한을 요구하지 않는다. 시스템 위치 표시기를 켜고 Xcode 프로젝트 파일은 변경하지 않는다.

Android는 공유 스트림에만 `ForegroundNotificationConfig`를 전달한다. 위치용 포그라운드 서비스와 “우나보 위치 공유 중” 알림을 사용하며 본문은 “같은 방 참여자에게 내 위치를 보내고 있습니다”다. `setOngoing: true`, `enableWakeLock: true`, 기존 `drawable/ic_notification_small` 아이콘을 사용한다. targetSdk 34용 `FOREGROUND_SERVICE_LOCATION`과 wake lock용 `WAKE_LOCK`을 선언하고, 기존 `POST_NOTIFICATIONS` 권한 흐름을 유지하며 `ACCESS_BACKGROUND_LOCATION`은 추가하지 않는다. geolocator_android 5.2.1의 서비스 타입은 `location`, 알림 ID/채널은 `75415`/`geolocator_channel_01`이다. 통화 서비스의 `microphone`, `1`/`call`과 분리되어 통화·공유 동시 실행 시 알림도 각각 게시된다. 실제 알림 표시와 Pleos 차량 UI는 기기 확인 대상이다.

위치 스트림은 `LocationShare.start()`에서만 열고 `stop()`에서 구독을 취소한다. 공유 중지·방 나가기 때 네이티브 위치 갱신과 iOS 표시기·Android 포그라운드 알림·wake lock도 종료하는 경로를 사용한다. 앱 재실행이나 저장된 동의만으로 배경 공유를 시작하지 않는다.

**공유 중지·삭제 재시도.** stop은 로컬 GPS·보류 타이머·과거 위치 오류를 즉시 지운다. 삭제 작업은 `(code,handle,generation)`으로 보존하고 진행 중 위치 POST 뒤에 DELETE를 보낸다. 실패 시 1·2·4·8·16·32·60초(이후 최대 60초) 간격으로 재시도한다. 같은 방을 떠나거나 인증/멤버/방이 없어진 401·403·404이면 재시도를 중단한다. 새 공유는 이미 전송된 이전 DELETE 완료를 기다린 뒤 오래된 작업과 타이머를 폐기하므로 이전 세대 삭제가 새 공유 뒤에 실행되지 않는다. 삭제 대기는 `deletionPending`/`deletionStatus`의 “위치 삭제 대기 중”으로 표시하며 `LocationShare.error`와 분리한다. 방 변경도 과거 오류를 지운다.

`leave()`/`forget()`은 `mediaEngine.leave()`와 `callService.stop()`을 먼저 호출하고 UI를 통화 종료 상태로 전환한다. 위치 POST→DELETE 완료는 그 뒤 기다리므로 위치 네트워크 지연이 마이크·오디오 종료를 늦추지 않는다. 같은 프로세스의 SSE 복귀는 hello의 수락 대상·pending 대상·수신 요청·revision으로 복원한다. 진행 중 follow POST와 오래된 hello, 먼저 도착한 SSE 응답의 순서 조정은 §15를 따른다.

**정차 규칙(M5a-c).** `LocationShare.motionState`는 `unknown`·`moving`·`stationary`의 3상태다. 최근 3초 관찰 창의 표본 중 speed ≥ 0.5m/s 또는 창의 첫 표본에서 3m 이상 이동한 표본이 있으면 즉시 moving이다. 이동 조건 없이 3초 관찰을 마치면 stationary이며, 속도가 없는 표본은 이동 거리로 판단한다. 표본 없음·초기 관찰 중·표본 단절 3초 이상·위치 스트림 오류·공유 중지는 unknown이다. 차량은 moving일 때만 동의 모달 진입과 따라가기 시작을 막고 “정차 후 설정할 수 있습니다”를 표시한다. unknown과 stationary는 허용하므로 위치 공유 전에도 동의 모달을 열 수 있다.

동의 후 `start()`가 완료되면 다시 검사한다. unknown에서 follow POST를 보낸 경우에도 최초 moving/stationary 판정 때 한 번 더 확인한다. 첫 판정이 moving이면 followTarget을 비우고 같은 문구를 표시하며, 이미 보낸 POST 뒤에 follow DELETE를 직렬화해 관계를 정리한다. 내 위치 공유는 유지한다. 첫 stationary 판정 이후에는 이동 중에도 따라가기를 유지하며 중지는 언제나 가능하다. 첫 판정 대기는 해당 따라가기 시도에만 적용하고 중지·거절·대상 변경·방 변경 후 늦은 표본으로 이전 시도를 되살리지 않는다. 폰에는 이 제한과 최초 판정 취소를 적용하지 않는다.

**동의 체계(결정 16-A·M7).** 이 설치의 첫 로그인·회원가입·저장 세션 복원 시 개인정보 처리방침만 필수로 받는다. 위치정보 수집·이용 동의는 선택이며 미체크 상태로도 음성 통화·방 목록에 진입할 수 있다. `legal.consent.v1`에는 `{privacy:{accepted,version},location:{accepted,version}}` JSON을 저장한다. 개인정보 `legalVersion = '2'`를 유지하고 위치 문서는 배경 전송·시스템 표시 안내를 추가해 `locationLegalVersion = '2'`, 시행일 2026-11-12로 올린다. 위치 버전 1의 기존 동의는 현재 위치 동의로 인정하지 않으며 다음 공유 시작 모달에서 다시 동의받고 버전 2를 저장한다. 따라가기 시작·요청 수락 모달에는 “화면이 꺼져 있어도 공유 중에는 위치를 보냅니다”를 표시한다. 법률 문구는 초안이며 별도 검토가 필요하다. 이전 버전 문자열 또는 현재 개인정보 동의가 없는 저장값은 전체 동의 화면을 다시 표시한다. 로그아웃해도 설치의 문서 동의는 보존한다. 개인정보 미동의는 기존 안내·로그아웃 경로이며 알림의 방 열기도 필수 동의 완료까지 보류한다.

위치 항목을 체크하지 않았어도 §15의 따라가기·요청 수락 모달에서 기능별 동의를 받으면 그때 위치 항목의 동의 여부·버전을 저장한다. 저장 성공 후에만 권한 요청으로 진행한다. 선택 동의의 저장은 자동 공유 허가가 아니며 매 새 기능 시작의 모달과 취소 토큰 규칙을 유지한다. `app/assets/legal/location.md`의 “동의하지 않을 권리” 문단은 변경하지 않는다.

## 13. 지도 화면(M2·M3·M5a)

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

브이월드 WMTS 경로는 **tileMatrix/tileRow/tileCol = z/y/x** 순서다. 키와 레이어만 치환하고 좌표 치환은 flutter_map에 맡긴다. User-Agent 패키지 이름은 `kr.modumoa.hdapp`이다. 키 없음·타일 오류 시 테마에 맞춘 단색 위에 차 아이콘·궤적을 유지한다. 실패 로그는 프로세스당 한 번만 남기고 키가 포함된 URL·예외 본문을 출력하지 않는다.

**타일 이용 규칙.** M2 지시문의 브이월드 2026-10-30 약관 기준으로 원본 타일을 표시한다. 위성 레이어, 색 필터, 블렌드, 재스타일, 타일 Opacity를 사용하지 않으며 `TileDisplay.instantaneous()`로 타일 페이드도 끈다. 시스템 `MediaQuery.platformBrightness`가 바뀌면 제공 레이어 Base/midnight만 바꾼다. 지도 우하단 출처는 접기·숨기기 기능 없는 텍스트이며 키가 없어도 표시한다.

공급자는 기본 클래스 `NetworkTileProvider`이고 추가 캐시 패키지·수동 저장은 없다. **8.3.2에서는 이 공급자도 디스크 캐시가 기본으로 켜져 있으므로 `cachingProvider: const DisabledMapCachingProvider()`를 명시한다.** Flutter 이미지 메모리 캐시만 사용한다. 설치된 패키지 소스와 [공식 캐시 문서](https://docs.fleaflet.dev/layers/raster-tile-layer/caching.md)로 기본 동작을 확인했다. 대상은 Android/iOS 앱이며 브라우저 자체 캐시 정책을 다루는 웹 배포는 이번 범위가 아니다.

**네이버 표시·약관(M3).** 고정된 flutter_naver_map 1.4.4의 `NMapType.navi`와 `nightModeEnable`을 사용한다. 회전·기울임 제스처, 최대 기울임 63도, 건물 레이어를 켜고 축척·위치 버튼·실내 지도는 끈다. 첫 카메라는 내 위치 → 따라가는 대상 → 첫 참여자 → 서울시청 순서로 정하며 줌은 16이다. 설치 소스에서 옵션은 `didUpdateWidget`이 아니라 `NaverMap.build → _updateOptionsIfNeeded → controller._updateOptions`로 갱신됨을 확인했다. 밝기 변경 시 야간 옵션만 갱신하고 지도를 재생성하지 않는다.

NAVER 로고는 왼쪽 아래에 상시 유지하고 플로팅 바 여백을 확보한다. `logoClickEnable: true`로 SDK의 법적 고지·오픈소스 화면을 그대로 연다. 로고를 숨기거나 다른 UI로 덮지 않으며, 네이버 지도 위에 별도의 출처 텍스트는 붙이지 않는다. 타일 색 필터·변형·커스텀 스타일을 추가하지 않는다. 위의 디스크 캐시 금지는 브이월드 타일 규칙이며, 네이버 SDK 자체 지도 캐시는 SDK가 관리한다. 마커의 `NOverlayImage.fromWidget`은 SDK 내부 임시 이미지 캐시를 사용한다.

**교체 경계·표시.** `app/lib/map/room_map.dart`는 얇은 `RoomMap` facade와 `abstract class RoomMapController`를 제공한다. `RoomMapController.create(provider)`가 `NaverRoomMapController` / `VworldRoomMapController`를 만들고 facade가 대응하는 지도 구현을 선택한다. 기존 무인자 컨트롤러와 facade의 기본값은 브이월드로 유지한다. 컨트롤러는 `moveTo(latitude, longitude, zoom:)`, `follow()`, `recenter()`, `alignHeading(bool)`을 제공한다. facade 입력은 positions/trail/targetHandle/selfHandle/following/brightness/onInteraction/tiles와 car/fullscreen/onFullscreen/onStopSharing이다. 공통 지도 버튼은 facade 내부에 표시한다. positions는 표시 이름과 LocationFix를 담은 `RoomMapPosition`이다. RoomScreen은 서비스의 공급원·오류 상태를 전달하고 공급원별 SDK 카메라·좌표 타입은 사용하지 않는다. 브이월드 구현은 `vworld_room_map.dart`에 유지한다.

두 구현은 `room_map_geometry.dart`의 전방점·거리 계산과 `room_map_widgets.dart`의 GPS/차량 마커·거리 라벨·원형 버튼을 공유한다. 내 마커는 파란 GPS 점·흰 테두리·옅은 바깥 원이며 heading이 있을 때만 부채꼴을 그린다. 상대는 폰 32dp·차량 44dp 차 아이콘과 작은 표시 이름, 불투명도 0.55다. 네이버는 `NOverlayImage.fromWidget`을 `(handle, 표시 이름, 나 여부, heading 유무, brightness, car)`별로 캐시하고, car SVG는 먼저 디코딩한다. 위치·방위는 `setPosition`/`setAngle`, 스타일은 `setIcon`/`setSize`/`setAlpha`로 갱신한다. `NMarker(alpha:)`를 써 위젯과 SDK에서 alpha를 이중 적용하지 않는다. `setGlobalZIndex(300000)`으로 내 마커를 상대(200000) 위에 둔다. 네이버는 중심 anchor·`isFlat: true`이고 캡처 위젯에는 heading을 다시 적용하지 않는다. 브이월드는 내 마커를 MarkerLayer의 마지막에 배치한다.

네이버 궤적은 금색 폭 8·테마 대비색 외곽선 폭 2의 `NPathOverlay`이며 2점 미만이면 생략한다. 이후 `setCoords`로 갱신한다. 브이월드는 기존 금색 폭 6의 둥근 Polyline이다. 지도에는 `trailOf(followTarget)`만 전달한다. 세션은 위치·궤적이 바뀔 때만 새 불변 스냅샷을 만들고 그 사이에는 같은 객체를 돌려주므로 네이버의 `listEquals`는 identical로 단락되고 브이월드는 궤적 참조가 바뀔 때만 투영한 `LatLng` 목록을 다시 만든다.

**따라가기 공통 규칙.** `roomForwardPoint()`는 heading이 있으면 전방 반평면의 가장 가까운 점을, 없으면 최근접 꼭짓점 다음 점을 고른다. 적절한 점이 없으면 따라가는 대상의 현재 위치를 쓴다. 직선 거리는 `350 m` / `1.2 km` 형식이며 좌상단에 표시한다. 사용자 터치가 끝날 때까지 자동 이동을 멈추고 마지막 제스처/카메라 정지 뒤 5초 후 따라가기가 켜진 경우에만 재개한다. 따라가기 꺼짐에서는 새 표본·테마 변경으로 카메라를 자동 이동하지 않는다.

`naverFollowCamera()`는 SDK와 무관하게 내 위치 중심·tilt 50·진행 방향·거리 줌을 계산한다. 방위는 내 heading → 전방점 방위 → 현재 방위 순서다. 대상까지 거리 `<200m: 17`, `<600m: 16`, `<1.5km: 15`, `<4km: 14`, 나머지 13을 쓴다. 상대 위치가 없으면 내 위치·줌 16이다. 네이버는 최대 초당 1회 최신 표본으로 `NCameraUpdate.withParams`에 linear·800ms를 설정한다. 브이월드도 같은 중심·거리 줌을 쓰며 2D 공급원이라 tilt는 적용하지 않는다.

수동 제스처 중에는 자동 이동을 멈추고 마지막 조작 종료·카메라 정지 후 5초 뒤 재개한다. 내 위치 버튼은 줌을 유지한 채 내 위치로 이동한다. 방향 정렬은 따라가기 여부와 무관하게 즉시 heading 기준으로 회전하고 이후 heading 갱신을 반영한다. 다시 누르면 북쪽 위(0도)를 유지한다. 네이버 `withParams`에서 생략한 줌·tilt는 유지하고, 브이월드는 카메라 rotation에 반대 부호를 사용한다. 따라가기 해제는 보류 카메라 요청과 진행 중 전환을 취소한다.

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

## 15. 방 화면 UX(M5a)

**입장·따라가기.** 입장 시 지도 없이 멤버 카드와 음성·방 관리 바를 표시한다. 방 화면의 “우나보 UNAVO” 상단 제목만 제거하고 메인 화면의 제목·기존 워드마크는 유지한다. `MemberAvatar`는 표시 이름 첫 글자의 원형 아바타이며 이후 사진으로 바꿀 경계다. 공유 중인 내 카드 탭은 아래의 공유 중지 모달을 열고, 공유 중이 아니면 무동작이다. 다른 카드 탭은 `showConsentDialog(title: '따라가기')`를 열고 표시 이름, “○○ 님의 위치를 따라갑니다”, “내 위치도 같은 방 참여자에게 보입니다”, “방을 나가거나 위치 공유를 중지하면 공유가 끝납니다”, “위치는 방이 있는 동안만 서버(국내)에 남습니다”를 표시한다. 이것이 요청자의 위치 공유 동의다. 동의 → 꺼져 있으면 `LocationShare.start(token:, stillValid:)` → 성공 및 차량 moving 아님을 확인 → follow POST → pending 대기 → 수락 확인 → 지도 표시 순서다. 이미 공유 중인 대상은 POST 응답에서 즉시 수락된다. 차량의 표본 없는 unknown도 모달과 POST를 허용하며, 동의 후 최초 이동 판정 시 취소·공유 유지 규칙은 §12를 따른다. 미동의는 “동의하지 않아 따라가기 기능을 사용할 수 없습니다” 안내다.

대상은 follow-request를 받으면 “따라가기 요청” 모달로 요청자 이름·공유 범위·종료 조건·보관 기간을 확인한다. 수락은 `start()` 성공 후 accepted:true, 미동의나 권한 실패는 accepted:false를 보낸다. 이미 공유 중이면 추가 모달 없이 수락한다. 서버도 현재 fix 또는 이전 수락으로 공유 중임을 아는 대상은 즉시 수락한다. 요청자의 거절 안내는 “○○ 님이 위치 공유에 동의하지 않았습니다”이며 followTarget과 지도를 해제한다. 대기 중 취소·방 변경·퇴장 뒤의 늦은 응답은 적용하지 않는다.

같은 대상 카드를 다시 탭하면 “따라가기 중지” 모달이다. check 선택 시 follow DELETE·지도 닫힘이며 내 공유는 계속한다. 공유 중인 내 카드와 지도 안 locationoff 버튼은 동일한 `showConsentDialog(title: '위치 공유 중지', lines: ['내 위치 공유를 중지합니다'])`를 연다. 선택 인자 `note`로 본문 아래에 “위치 공유를 중단하게 되면 그룹 안에 있는 파트너와 연결이 끊기게 됩니다. 그래도 하시겠습니까?”를 `UnavoType.caption` 회색 보조 스타일로 표시한다. check 선택은 내 공유·따라가기와 지도를 닫고, 나를 따르던 팔로워는 서버 종료 이벤트로 해제한다. back 선택은 상태를 유지한다. 방을 나가면 모두 종료한다. 동의 모달은 가운데·차단형·아이콘 버튼만 사용하는 M4 규칙을 유지한다.

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

앱은 POST 진행 중 사용자의 대상 의도를 보존하고 완료 후 반환된 revision을 기록한다. 작은 revision의 hello는 따라가기 상태를 덮지 않는다. POST 결과보다 먼저 도착한 follow-response는 보류했다가 현재 requestId가 맞을 때만 적용한다. 같은 대상 취소 후 재요청과 이미 수락된 A→B 전환도 같은 규칙이다. accepted 전에는 지도 없이 “따라가기 응답 대기 중”을 표시한다. `follow-request`의 requester가 멤버 캐시에 없어도 요청을 보관하고 비동기 `_refresh`를 시도한 뒤 모달을 표시한다. 조회 실패 시에도 이벤트 displayName(없으면 handle)을 사용한다. 재조회 중 취소는 이벤트 큐를 막지 않고 즉시 폐기한다.

**확인과 남은 결정.** Flutter 테스트는 NaverMap을 pump하지 않고 facade·브이월드·SDK 마커 생성 함수로 검사한다. 새 위젯 테스트는 고정 pump·30초 timeout·핸들러 밖 검증을 사용한다. M5a 작업에서 Flutter test/build는 실행하지 않으며 Fable이 별도 실행한다. 네이티브 지도·주야간 모드·로고 클릭·폰 회전·실차 음성/GPS는 기기 검증 대상이다.

표본이 없는 차량의 첫 따라가기 진입 제약은 M5a-c의 unknown 허용과 동의 후 최초 판정 검사로 해소한다. 따라가기만 중지하거나 상대 요청만 수락한 사람도 통화 방의 내 카드를 눌러 공유를 중지할 수 있다. 별도 텍스트 버튼은 추가하지 않는다.

## 16. 프로필·아바타(M5b)

**저장·프로토콜.** 계정의 `avatar_kind`는 null, `mascot-01`~`mascot-05`, `photo` 중 하나이고 `avatar_version`은 0에서 시작한다. 기존 SQLite에는 두 열을 추가해 null/0으로 초기화하며 반복 초기화는 기존 선택을 보존한다. 성공한 PUT/DELETE마다 version이 1 증가한다. 공개 사용자와 방 멤버에는 `avatar: {kind, version}`을 포함하며 비밀번호·내부 ID·사진 바이트는 포함하지 않는다.

사진은 기본 `server/data/avatars/<handle>.png`에 저장한다. `HDAPP_DB`로 DB 경로를 바꾸면 그 DB의 부모 데이터 폴더 아래 `avatars/`를 사용하며 디렉터리는 첫 업로드 때 만든다. PNG 시그니처, 첫 IHDR 길이·256×256 크기, 청크 경계·IDAT/IEND와 최대 300×1024바이트를 검사한다. base64는 표준 패딩까지 엄격히 검사한다. 마스코트 선택·삭제 시 사진 파일을 지우며 교체 시 이전 사진 이력은 남기지 않는다. 파일 변경·SQLite 변경은 동기 작업으로 처리하고 저장 실패 시 이전 바이트를 복원한다. 앱은 사진 원본·EXIF를 올리지 않고 재인코딩한 PNG만 보낸다.

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

**마커·캐시.** 이 절의 규칙이 §13·§15의 이전 파란 점/차 아이콘 크기를 갱신한다. 상대는 같은 `MemberAvatar`를 사용하며, 프로필 미설정(null)이면 카드와 같은 기본 마스코트 1번(`mascot-01`)을 표시한다. 폰 36dp·차량 48dp, 3dp 입장 순서 무지개 테두리, alpha 0.55와 이름 배지를 유지한다. 나는 프로필 유무와 무관하게 GPS 점·흰 테두리·heading 부채꼴이며 색만 내 입장 색으로 바뀐다. 내 alpha 1과 최상위 z-index를 유지한다. 상대 마커는 기본 마스코트를 포함해 heading 회전이 없으며 이름표도 회전하지 않는다. 네이버 사진 로드 실패의 임시 차 아이콘도 angle 0을 유지한다.

`ApiClient.avatarPhoto`는 인증 헤더를 포함한 version URL로 가져오며 서버 주소·로그인 토큰·handle·version별 메모리 캐시를 사용한다. 새 버전은 재요청하고 실패한 요청은 캐시에서 제거한다. 네이버 `NOverlayImage.fromWidget` 키에는 handle·표시 이름·나 여부·heading 유무·밝기·차량 여부와 avatar kind·version·색을 포함한다. 사진/마스코트는 `ui.Image`로 완전히 디코딩한 후 `RawImage`로 캡처하므로 비어 있는 첫 프레임을 저장하지 않는다. 로딩 실패 시 임시 차 마커를 사용하고 이후 성공하면 동일 버전이어도 아이콘을 교체한다. SDK alpha와 위젯 opacity를 중복 적용하지 않는다. 앱 수동 디스크 캐시는 없으며 SDK의 캡처용 임시 캐시는 §13과 같다. 브이월드도 facade로 전달된 avatar·order·API와 공통 마커 위젯을 사용한다.

**동의·검증.** M5b 당시 개인정보 `legalVersion='2'`, 위치 문서 `locationLegalVersion='1'`과 M6의 항목별 동의 저장을 유지했고 법률 Markdown은 변경하지 않았다. 이후 M7의 위치 문서 버전 2·배경 전송 동의는 §12를 따른다. 추가 검증은 `member_colors_test.dart`, `member_avatar_test.dart`, `profile_screen_test.dart`, 지도 캐시 키·내 GPS 색 테스트, 개인정보 버전 2 재동의 테스트, 서버 `avatars.test.ts`이다. 서버 테스트에는 마이그레이션, 300KB/PNG/IHDR 검사, 버전 증가·사진 삭제, 인증·캐시 헤더, 첫 입장 순서와 재입장, 공개 직렬화·참여 방 SSE를 포함한다. 새 테스트는 30초 timeout과 유한 pump를 사용하고 비동기 핸들러 밖에서 검증한다. 이 작업에서는 정적 분석·구문·포맷만 검사하며 테스트 실행과 빌드는 Fable이 담당한다. 실제 갤러리·네이티브 지도 캡처와 폰/차량 배치는 기기 확인 대상이다.

## 17. 차량 모드 주행 중 조작 잠금(M8b)

**기준·플랫폼.** `DeviceCapabilities`가 Android `FEATURE_AUTOMOTIVE`로 판별한 차량에서만 `DrivingState`가 `EventChannel('unavo/drive')`를 구독한다. 네이티브 `DriveChannel`은 `Car.createCar(context)`와 `CarUxRestrictionsManager`를 연결하고 구독 직후 현재 값, 이후 리스너 변경 값을 전송한다. 잠금 기준은 `CarUxRestrictions.isRequiresDistractionOptimization()`이며 `activeRestrictions` 비트 값이나 GPS 속도로 추정하지 않는다. 예를 들어 requiresDO가 true이면 비트 값이 0이어도 잠근다. 플랫폼은 기어가 P를 벗어난 정차(IDLING, 속도 0)에서도 requiresDO를 켜므로 신호 대기 중에도 잠기며, 이는 결정 21(11/12, A)로 확정한 의도된 동작이다(속도>0 조건으로 바꾸지 않는다). `CAR_SPEED`·`CAR_DRIVING_STATE` 권한은 요청하지 않는다. 기존 `distractionOptimized=true`를 유지하고 `android.car`는 optional uses-library와 compileSdk 37의 로컬 jar compileOnly로 연결한다. 새 Maven/pub 패키지는 없다.

**범위·수명.** `MaterialApp.builder`의 `DrivingLockOverlay`가 Navigator 위 Stack에 반투명 스크림, Tabler outline 핸들·자물쇠 아이콘, “주행 중에는 조작할 수 없습니다” 한 줄을 표시한다. `AbsorbPointer`는 주 패널·보조 패널·모든 route·다이얼로그를 포함한 앱 전체 터치를 차단한다. 터치를 허용하는 버튼이나 화면 예외는 없다. 제한이 false가 되는 즉시 오버레이를 제거하며 기존 화면과 다이얼로그를 유지한다. 잠금 중 들어오는 따라가기 요청과 동의 모달은 기존 큐·내비게이터 흐름을 그대로 따르고 해제 뒤 응답할 수 있다. 통화·위치 공유·SSE와 세션에는 손대지 않는다. §12의 위치 공유 최초 이동 판정은 기존 기능 내부 규칙으로 유지하며 전역 잠금의 입력으로 사용하지 않는다.

**폰·사용 불가.** 폰은 이동 여부와 무관하게 주행 이벤트를 구독하지 않고 항상 `restricted=false`다. UI도 차량 모드를 재확인하므로 제한 상태를 잘못 전달해도 폰을 잠그지 않는다. 자동차가 아니거나 `android.car`가 없거나 Car 연결·조회에 실패하면 네이티브는 `{restricted:false, available:false}`를 한 번 보내고 스트림을 끝낸다. Flutter는 unavailable·잘못된 이벤트·채널 오류·스트림 종료 시 잠금을 해제한다. 구독 cancel과 Activity의 엔진 정리 경로에서 리스너와 Car 연결을 해제하고 `AppServices.dispose()`에서 Dart 구독도 해제한다.

**근거·검증.** [Pleos SDK 안내](https://document.pleos.ai/docs/pleos-only/vehicle-app-planning-guide/pleos-connect-sdk-api)는 차속·기어 등의 표준 데이터를 AAOS Car API로 안내한다. [Pleos 주행 규제 개발 가이드](https://document.pleos.ai/docs/pleos-only/vehicle-app-developer-guide/driving-restriction-development-guide)는 DO 선언 앱도 CarUxRestrictions와 ActiveRestrictions에 따라 UX 제한을 직접 적용하도록 한다. [Android CarUxRestrictionsManager](https://developer.android.com/reference/android/car/drivingstate/CarUxRestrictionsManager)의 현재 값·리스너 API를 사용한다. 로컬 근거는 `pleos-sdk-inventory.md` §0.3, `contest-recheck-2026-10-23.md` §4(h), `emulator-handson-modumoa.md` §4.1이다. 상태 파싱·오류·폰 미구독·구독 해제는 `driving_state_test.dart`, 전체 터치 차단·즉시 해제·폰 예외·다이얼로그 보존은 `driving_lock_test.dart`로 검사한다. Pleos 에뮬레이터의 Drive/40 km/h → Park/0 km/h 및 실제 기기의 터치·통화·위치 전송 유지는 별도 확인 대상이다.
