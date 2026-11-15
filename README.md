# 우나보(Unavo)

같이 달리는 차들이 한 방에서 통화하며 앞차가 지나간 길을 따라가거나 합류 지점에서 모여 함께 가는, 차량 화면(Pleos Connect)과 폰을 같은 계정으로 쓰는 동행 앱입니다.

현대자동차그룹 차량용 앱 개발 공모전 출품작(팀 UnaVo)의 소스 저장소입니다.

## 주요 기능

- **통화 방** — 방 코드로 입장하면 바로 그룹 음성 통화가 연결됩니다(WebRTC 풀 메시, 먼저 입장한 4명까지). 사람은 전화번호가 아니라 가입 때 정한 아이디로 식별합니다.
- **앞차 따라가기** — 멤버 카드를 눌러 요청하고 상대가 동의하면, 동의한 순간 앞차가 있던 곳(기준 지점)까지 추천 경로를 그리고, 그곳을 지나면 앞차가 실제로 지나간 길(궤적)을 따라 안내합니다. 위치 공유는 켤 때마다 동의를 받습니다.
- **합류 지점 따라가기** — 그룹장이 목적지와 합류 지점을 지도·주소로 정하고, 각 차의 추천 경로가 겹치는 구간을 기준으로 합류 지점을 추천받습니다(최단 만남을 보장하는 계산은 아님). 먼저 온 차는 「합류 지점에서 기다리기」 또는 「먼저 목적지까지 가기」를 따르고, 함께 출발하면 그룹장이 지나간 길을 따라갑니다.
- **길 벗어남** — 다시 합류할 길을 회색 반투명 경로로 안내합니다. 경로를 받지 못하면 30초 뒤 다시 찾고, 원래 길로 돌아오면 자동으로 다시 따라갑니다.
- **차량 모드** — Android Automotive 기기를 자동으로 판별해 2560×1440 가로 배치와 큰 아이콘 버튼으로 바뀌고, 주행 중에는 화면 조작을 잠급니다(CarUxRestrictions). 통화와 따라가기는 잠긴 동안에도 계속됩니다.
- **Pleos SDK** — 위치 공유 중지·위치 갱신 지연을 음성으로 안내(TextToSpeech, ON_DEVICE)하고, 차량 위치(FusedLocation)를 따라가기 입력으로 쓰며, 문 상태(Vehicle)와 기어로 「출발 준비」와 하차 보호(차량 마이크·위치 보내기 멈춤)를 합니다.
- **폰 이어받기** — 같은 계정으로 폰 앱을 열면 로비의 「참여 중」 카드로 같은 방에 들어가고, 차는 「다른 기기에서 이어받았습니다」로 바뀝니다. 한 계정은 한 기기에서만 마이크·위치를 보냅니다.

## APK 파일 위치

- GitHub Release: <https://github.com/VitAlGuard-jodal/HD-app/releases/tag/v0.2.0> — `UnaVo_Unavo_release.apk` (이전 판 v0.1.0 도 Releases 에 남아 있습니다)
- release 키로 서명했고 arm64-v8a·x86_64 네이티브 라이브러리를 함께 담아 약 146 MB입니다. 저장소 파일 한도(100 MB)를 넘어 Releases에 올렸으며, [`apk/README.md`](apk/README.md)에 같은 링크와 SHA-256이 있습니다.
- 공개 테스트 서버가 기본 주소로 들어 있어 설치 뒤 설정 없이 가입·로그인할 수 있습니다.

## 실행 방법

### APK로 실행(권장)

1. 아래 규격의 Pleos Connect 에뮬레이터를 Cold boot로 켭니다.
2. APK를 설치합니다: `adb install -r UnaVo_Unavo_release.apk`
3. 앱 목록에서 「우나보」를 엽니다 → 가입(아이디·비밀번호·표시 이름, 만 14세 이상 확인) → 첫 로그인 동의 → 로비.
4. 방 이름을 넣어 방을 만들면 방 코드가 생깁니다. 다른 기기(폰 앱 또는 두 번째 에뮬레이터)에서 같은 코드로 입장하면 통화가 연결됩니다.
5. 상대의 멤버 카드를 눌러 따라가기를 요청합니다(양쪽 모두 위치 공유 동의 필요). 에뮬레이터 위치는 Extended Controls → Location에서 지정합니다.
   - 합류 지점 따라가기: 따라오는 차가 있는 그룹장 지도에서 위쪽 지도 버튼 → ＋ → 목적지(지도 길게 누르기 또는 주소) → ☆ 추천 → 기다리기/먼저 가기 → 확정. 따라오는 차는 지도 오른쪽 경로 버튼으로 참여합니다.
6. 주행 잠금은 에뮬레이터 차량 신호(Virtual Console)에서 기어 D·차속을 주면 걸리고, P로 바꾸면 풀립니다.

### 소스에서 빌드

필요한 것: Flutter 3.47(stable), Android SDK Platform 37(`android.car` 컴파일용), JDK 17, Node.js 24 이상.

앱:

```sh
cd app
flutter pub get
flutter build apk --release --dart-define-from-file=<지도 키 JSON> --dart-define=UNAVO_SERVER_URL=<서버 주소>
```

- 지도 키 JSON 형식: `{"NAVER_CLIENT_ID": "<네이버 지도 클라이언트 ID>", "UNAVO_TILE_KEY": "<브이월드 키>"}`. 네이버 키가 없으면 브이월드 타일을, 둘 다 없으면 타일 없는 단색 바탕을 씁니다(궤적·마커는 그대로 그립니다).
- `UNAVO_SERVER_URL`을 빼면 앱 기본 주소는 Android 에뮬레이터 `http://10.0.2.2:8787`, iOS `http://127.0.0.1:8787`입니다. 앱 설정에서 바꿀 수도 있습니다.
- `app/android/key.properties`가 없으면 debug 키로 서명됩니다(release 서명 규칙은 `docs/ARCHITECTURE.md` §18).

서버:

```sh
cd server
node src/main.ts
```

- Node.js 내장 모듈만 써서 패키지 설치가 없습니다. 기본 포트 8787, DB `server/data/hdapp.sqlite`.
- 환경변수: `PORT`, `HDAPP_DB`(DB 경로), `TURN_SECRET`·`TURN_URIS`·`TURN_REALM`·`TURN_TTL_SECONDS`(coturn 공유 비밀 방식 TURN 자격 발급). TURN을 설정하지 않으면 공개 STUN만 안내합니다.
- 경로·주소 검색(네이버 클라우드 플랫폼 Maps): `ROUTE_PROVIDER=naver`, `NAVER_DIRECTIONS_KEY_ID`, `NAVER_DIRECTIONS_KEY`(Directions 5), `GEOCODING_ENABLED=true`(Geocoding, 같은 키). 설정하지 않으면 추천 경로·합류 지점 추천·주소 검색을 쓸 수 없습니다.

테스트:

```sh
cd app && flutter test
cd server && node --test "test/unit/*.test.ts" "test/http/*.test.ts"
```

## 테스트 환경과 필요한 설정

- 서버: 공개 테스트 서버 `https://unavo-dev.kimtaegon.kr`(APK 기본값). AWS 서울 리전(Lightsail)에서 Caddy(HTTPS)와 coturn(TURN)으로 운영합니다.
- 권한: 마이크(통화), 위치(따라가기, 켤 때마다 동의), 알림(통화·위치 공유 유지 알림).
- 차량/폰 판별: 앱 시작 때 `android.hardware.type.automotive` 기능 유무로 정합니다. 같은 APK를 폰에 설치하면 폰 화면으로 동작합니다.
- 검증한 기기: Pleos Connect 에뮬레이터 두 대(아래 규격, GPS 재생)와 iPhone 12(같은 코드의 iOS 빌드). 따라가기 두 방식과 회색 재합류는 에뮬레이터 두 대로 확인했습니다.
- 자동 테스트: 앱 969건, 서버 420건.

## 개발에 사용한 Pleos Connect 에뮬레이터 버전과 화면 규격

| 항목 | 값 |
|---|---|
| AVD | `Pleos_Connect_v2_1_0` (Automotive, Cold boot) |
| 시스템 이미지 | Pleos Connect v2.1.0 APIs arm64 System Image (`RELEASE.release_connect_v2.1.0`) |
| Android | 14 (API 34) |
| 화면 | 2560 × 1440, 160 dpi |
| RAM | 4096 MB |
| Android Emulator | 36.5.11 (macOS arm64) |

## 저장소 구성

| 경로 | 내용 |
|---|---|
| `app/` | Flutter 앱(차량·폰 공용). `lib/` 화면·통화·위치, `android/` Kotlin 플랫폼 채널(기기 판별·오디오 경로·통화 유지 서비스·주행 상태·차량 위치·TTS·차량 문/기어, Pleos SDK TextToSpeech 3.3.1·FusedLocation 1.1.3·Vehicle 2.3.2), `ios/` |
| `server/` | Node.js 서버: 계정·친구·통화 방·동의 기록, SSE 시그널링·위치·합류 계획 이벤트, TURN 자격 발급, 네이버 경로·주소 검색 중계(호출 수 제한, 응답 저장 안 함) |
| `docs/ARCHITECTURE.md` | 설계 문서(정본) |
| `apk/` | APK 안내(Release 링크·SHA-256) |
| `licenses/` | 번들한 서체·라이브러리 라이선스 |
| `android/` | 초기 Compose 시제품(현재 앱에서 쓰지 않음) |

## 서체와 라이선스

- 앱은 OFL(SIL Open Font License 1.1) 서체 두 종을 `app/assets/fonts/`에 번들합니다. 라이선스 원문은 `licenses/fonts/<서체>/OFL.txt`에 있습니다.

| 서체 | 용도 | 출처 |
|---|---|---|
| Rye | 영문 레터링 「UNAVO」, 번호 | github.com/google/fonts/tree/main/ofl/rye |
| Black Han Sans | 한글 「우나보」, 방 코드 | github.com/google/fonts/tree/main/ofl/blackhansans |

- 배경 그림의 「Una Vox」 글자는 Pirata One(OFL)으로 그린 뒤 그림으로 구웠으며 서체 파일은 번들하지 않습니다.
- 잡음 제거 실험 플러그인(`app/packages/unavo_noise`, 기본 꺼짐)은 RNNoise를 포함하며 라이선스는 `licenses/rnnoise/`에 있습니다.
- 그 밖의 Flutter 패키지는 `app/pubspec.yaml`을 따릅니다.
