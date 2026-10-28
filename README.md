# HD-app — 「우나보(Unavo)」 Pleos Connect 앱
구 이름: 모두모아(아이디어 심사 문서에서는 이 이름으로 표기)

현대자동차 차량용 앱 개발 공모전 출품작의 코드 저장소입니다. 차량(Pleos Connect, Android Automotive API 34)과 폰에서 같이 도는 앱과, 회원가입·친구·통화 방을 담당하는 서버로 이루어집니다.

## 핵심 원칙

1. **사람은 전화번호가 아니라 아이디로 식별한다.** 회원가입 때 정한 아이디가 친구 추가·통화 방 초대·통화 중 발화자 표시의 유일한 식별자다. 전화번호는 어디에도 저장하지 않는다.
2. **통화는 앱 안의 데이터망 음성(WebRTC)으로 한다.** 일반 전화망으로는 제3자 앱이 디스코드식 그룹통화를 만들 수 없다는 조사 결론(2026-10-27 STORM)에 따른다. 미디어 엔진(libwebrtc)은 설치 승인(Q-4) 뒤 붙이며, 그 전까지는 `MediaEngine` 인터페이스 뒤의 빈 구현으로 둔다.
3. **차량에서 돌면 차량 마이크를 쓴다.** 앱이 자동차 기기(`FEATURE_AUTOMOTIVE`)임을 감지하면 입력 장치 중 차량 내장 마이크를 골라 통화 입력으로 잡고, 폰이면 헤드셋·내장 마이크 순으로 고른다. 사용자가 손으로 바꿀 수 있다.

## 구성

| 경로 | 내용 | 실행 |
|---|---|---|
| `server/` | 회원가입·로그인·친구·통화 방·시그널링 서버. Node 24 내장 모듈만 사용(의존성 0). | `cd server && node src/main.ts` |
| `app/` | Flutter 단일 앱: 폰 기본·차량 모드·iOS. F1은 폰 UI와 Android 플랫폼 채널, 차량 UI·iOS 오디오는 후속 라운드. | `cd app && flutter pub get && flutter run` |
| `android/` | Compose 차량 앱(F2 완료 후 archive 예정). | Android Studio 또는 `./gradlew :app:assembleDebug` |
| `docs/` | 설계 문서. `ARCHITECTURE.md` 가 정본. | — |

조사 보고서(그룹통화 통신 방식 STORM, 아키텍처 다이어그램)는 저장소 밖 `~/dist/modumoa-group-call-voip/` 에 있습니다.

## 서체와 라이선스

앱은 OFL(SIL Open Font License 1.1) 서체 두 종을 `android/app/src/main/res/font/` 에 번들합니다. 각 서체의 라이선스 원문은 `licenses/fonts/<서체>/OFL.txt` 에 있습니다. 배경 포스터의 블랙레터 「Una Vox」는 Pirata One(OFL)으로 그린 뒤 PNG 로 구웠으며 서체 파일은 번들하지 않습니다. Flutter 앱은 같은 서체를 `app/assets/fonts/`에 복사해 사용하며 동일한 라이선스를 참조합니다.

| 서체 | 용도 | 출처 |
|---|---|---|
| Rye | 영문 레터링 「UNAVO」, 번호 | github.com/google/fonts/tree/main/ofl/rye |
| Black Han Sans | 한글 「우나보」, 방 코드 | github.com/google/fonts/tree/main/ofl/blackhansans |

배경 포스터(`res/drawable-nodpi/unavo_western_{night,day}.png`)는 직접 제작한 SVG 를 래스터화한 것입니다. 현대 엠블럼은 자리표시자이며 공식 파일과 사용 권한을 받은 뒤 교체합니다.
