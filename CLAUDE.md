# Yuja — HWP/HWPX → MD/TXT/DOCX/PDF 변환기 (macOS, Swift, MIT)

## 원칙
- 텍스트 유실 0. 해석 못하는 요소는 .raw 블록으로 보존한다.
- 모든 파서는 YujaCore/Model의 IR로 변환하고, 익스포터는 IR만 본다. 파서가 Markdown을 직접 만들지 않는다.
- AGPL 코드(pyhwp 등) 복사·참조 금지. MIT/Apache/공개 스펙만.
- 레이아웃 재현은 비목표. "구조 정확도"가 품질 기준.
- 기능 추가 전 Tests/Fixtures에 골든 테스트부터 추가.

## 작업 순서
PLAN.md의 Phase 순서를 따른다. Phase를 넘어가기 전에 완료 기준을 확인하고 사용자에게 보고한다.

## 빌드/테스트
- swift build / swift test (YujaCore, CLI)
- App/Yuja는 xcodebuild -scheme Yuja
- 테스트 픽스처 변경 시 기대 .md도 같이 갱신하고 diff를 PR 설명에 남긴다.

## 코드 규칙
- Swift 5.9, macOS 13+. 외부 의존성 추가는 사유를 CLAUDE.md에 기록.
- 바이너리 파싱은 Data + 명시적 리틀엔디언 읽기 헬퍼 사용. 오프셋 가정 금지, 레코드 크기로 이동.
- 에러는 YujaError enum, 사용자 메시지는 한국어.

## 외부 의존성 기록
| 패키지 | 버전 | 라이선스 | 사유 |
|---|---|---|---|
| apple/swift-argument-parser | 1.8.x | Apache 2.0 | CLI 인자 파싱 표준 |
| weichsel/ZIPFoundation | 0.9.20 | MIT | HWPX(ZIP) 읽기 + DOCX(ZIP) 쓰기. Foundation엔 ZIP API가 없음 (AppleArchive는 ZIP 아님) |

## 막히면
- 포맷 스펙 불명확 → yuja inspect로 실파일 덤프를 먼저 보고 판단.
- 결정이 필요하면 추측 실행 말고 멈춰서 사용자에게 묻는다(사용자 최우선 지침).
