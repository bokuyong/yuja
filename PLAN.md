# YUJA (유자) — HWP/HWPX → Markdown/DOCX/PDF 변환기 for Mac
## Claude Code 작업 계획서 v0.1

> 이 문서는 Claude Code에 그대로 넘기는 작업 지시서임. 프로젝트 루트에 `PLAN.md`로 두고, 아래 "CLAUDE.md 초안"을 `CLAUDE.md`로 분리해서 저장할 것.
> 프로젝트명 "Yuja"는 가칭(Tangerine 오마주). 바꿔도 됨.

---

## 0. 한 줄 정의

Finder에서 HWP/HWPX 파일을 집어서 Shift를 누르면 원형 메뉴가 뜨고, 로컬에서 Markdown·TXT·DOCX·PDF로 변환해 원본 옆에 떨어뜨리는 무료·오픈소스 맥 앱.

핵심 차별점: **레이아웃 재현이 아니라 구조 추출**. LLM 입력용 Markdown이 1순위 출력.

---

## 1. 결정사항 (바꾸려면 먼저 물어볼 것)

| 항목 | 결정 | 이유 |
|---|---|---|
| 언어/프레임워크 | Swift 5.9+, SwiftUI + AppKit 혼합, macOS 13+ (Apple Silicon 우선, Intel은 가능하면) | 네이티브 번들 하나로 배포. Python/JVM 번들 회피 |
| 파서 구현 | HWPX: 자체 구현(Swift). HWP 5.0: 자체 구현(Swift) 또는 Rust 크레이트 FFI — Phase 3에서 결정 | 라이선스·번들 단순화 |
| 아키텍처 | 3개 타깃: `YujaCore`(파서+변환, SwiftPM 라이브러리) / `yuja`(CLI) / `Yuja.app`(GUI) | CLI 먼저 → 테스트 자동화 → GUI는 껍데기 |
| 배포 | GitHub Releases(DMG, 노타라이즈) + Homebrew Cask. App Store는 Phase 6 선택 | 전역 이벤트 모니터가 샌드박스 밖에서 더 단순 |
| 라이선스 | MIT | 무료·오픈소스 확정 |
| 의존성 정책 | AGPL 코드 사용 금지(pyhwp 등). 참고는 스펙 문서와 MIT/Apache 코드만 | 배포 리스크 제거 |
| 출력 우선순위 | Markdown > TXT > DOCX > PDF | PDF 충실 렌더링은 비목표 |

### 비목표 (하지 말 것)
- 원본 레이아웃 픽셀 단위 재현
- HWP 쓰기(변환 결과를 HWP로 저장)
- 글상자·수식·OLE 개체의 시각 재현 (텍스트만 추출)
- 암호화된 HWP 복호화

---

## 2. 사전 조사: 포맷 구조 요약

### HWPX (신형, 권장 1순위)
- 실체 = ZIP 컨테이너 + XML (OWPML, 국가표준 KS X 6101)
- 주요 엔트리: `Contents/content.hpf`(매니페스트), `Contents/header.xml`(스타일·글꼴·문단모양), `Contents/section0.xml` …(본문), `BinData/`(이미지)
- 본문 요소 핵심: `hp:p`(문단) > `hp:run` > `hp:t`(텍스트), `hp:tbl`(표) > `hp:tr`/`hp:tc`(셀, `colSpan`/`rowSpan`), `hp:pic`(이미지), `hp:secPr`(구역 설정)
- 문단 스타일 id → `header.xml`의 `hh:style`/`hh:paraPr` 참조로 제목 레벨·목록 여부 판별

### HWP 5.0 (구형 바이너리)
- 실체 = CFB(OLE2 Compound File) 컨테이너
- 스트림: `FileHeader`(버전·압축·암호 플래그), `DocInfo`(글꼴·스타일), `BodyText/Section0` …, `BinData/`
- 각 스트림은 레코드 나열: 4바이트 헤더(tagID 10bit | level 10bit | size 12bit, size=0xFFF면 다음 4바이트가 실제 크기)
- 압축 플래그 켜져 있으면 스트림 전체가 raw deflate(zlib, wbits=-15)
- 텍스트는 UTF-16LE, 문단 레코드(HWPTAG_PARA_TEXT)에 인라인 제어문자(표·그림 등은 제어문자 + 별도 레코드)
- 스펙: 한컴 공개 "한글 문서 파일 형식 5.0" PDF — 작업 시작 전 Claude Code가 WebSearch로 최신판 확보해서 `docs/spec/`에 요약 저장

### 참고 오픈소스 (라이선스 반드시 재확인 후 사용)
| 프로젝트 | 언어 | 라이선스(기억상, 확인 필요) | 용도 |
|---|---|---|---|
| hahnlee/hwp.js | TS | MIT | HWP 5.0 레코드 파싱 로직 참고 |
| hahnlee/hwp-rs | Rust | MIT | HWP 5.0 파서. FFI 후보 |
| neolord0/hwplib, hwpxlib | Java | Apache 2.0 | 구조 참고 + 테스트 픽스처 생성용 |
| pyhwp | Python | AGPL | **참고만, 코드 복사 금지** |

---

## 3. 저장소 구조

```
yuja/
├── CLAUDE.md
├── PLAN.md                  ← 이 문서
├── Package.swift            # YujaCore + yuja(CLI)
├── Sources/
│   ├── YujaCore/
│   │   ├── Model/           # Document, Section, Paragraph, Run, Table, Image …
│   │   ├── HWPX/            # ZIP 열기, XML 파서, 스타일 해석
│   │   ├── HWP5/            # CFB 리더, 레코드 파서, DocInfo/BodyText
│   │   ├── Export/          # MarkdownExporter, TextExporter, DocxExporter, PdfExporter
│   │   └── Detect.swift     # 확장자/매직넘버로 포맷 판별
│   └── yuja/                # CLI (swift-argument-parser)
├── App/
│   └── Yuja/                # Xcode 프로젝트 (GUI)
│       ├── DragMonitor/     # 전역 Shift+드래그 감지
│       ├── RadialMenu/      # 원형 메뉴 뷰
│       └── Settings/
├── Tests/
│   ├── YujaCoreTests/
│   └── Fixtures/            # 샘플 hwp/hwpx + 기대 출력(.md)
├── docs/spec/               # 포맷 스펙 요약 노트
└── scripts/                 # 빌드·노타라이즈·릴리즈
```

### 중간 표현(IR) 모델 — 모든 파서가 이걸로 변환하고, 모든 익스포터가 이걸 소비
```swift
struct Document { var meta: Meta; var sections: [Section] }
struct Section { var blocks: [Block] }
enum Block {
  case heading(level: Int, runs: [Run])
  case paragraph(runs: [Run], align: Align?)
  case list(items: [[Block]], ordered: Bool)
  case table(Table)
  case image(ImageRef)
  case pageBreak
  case raw(String)          // 해석 못한 것. 유실 없이 보존
}
struct Run { var text: String; var bold: Bool; var italic: Bool; var underline: Bool; var strike: Bool }
struct Table { var rows: [[Cell]] }
struct Cell { var blocks: [Block]; var colSpan: Int; var rowSpan: Int }
```

---

## 4. 단계별 계획

### Phase 0 — 부트스트랩 (0.5일)
- [x] `swift package init` → YujaCore(lib) + yuja(executable) 타깃
- [x] 의존성: `swift-argument-parser`, ZIP은 `ZIPFoundation`(MIT) 또는 Foundation `Archive` — 선택 후 기록
- [x] CI: GitHub Actions macOS 러너에서 `swift build && swift test`
- [x] `Tests/Fixtures/`에 샘플 파일 수집 — **사용자가 제공**: 정부과제 공고문 HWP 2~3개, 표 많은 HWPX 2~3개, 이미지 포함 1개, 목록 포함 1개. 없으면 hwpxlib로 생성 (Phase 0에서 사용자에게 요청)
- 완료 기준: `swift test` 통과(빈 테스트), CI 녹색

### Phase 1 — HWPX → Markdown/TXT (CLI) (3~5일)
- [x] ZIP 열기 → `content.hpf` 파싱 → section 순서 확보
- [x] `header.xml` 파싱: paraPr/charPr/style 테이블 구축 (제목 스타일명 "개요 1~7", "제목" 등 → heading 레벨 매핑; 글머리표/번호 매기기 → list)
- [x] `sectionN.xml` 스트리밍 파싱(XMLParser 델리게이트) → IR
  - 문단/런/텍스트, 줄바꿈(`hp:lineBreak`), 탭
  - 표: colSpan/rowSpan 보존, 셀 내 중첩 문단
  - 이미지: BinData 추출 → `<출력파일명>_assets/img_N.png` 저장, IR에 경로
  - 해석 불가 요소는 `.raw`로 텍스트만 보존 (유실 0 원칙)
- [x] MarkdownExporter
  - heading → `#`, 표 → GFM 표 (병합 셀은 `colSpan` 시 빈 셀 채움 + 셀 텍스트에 `(↔2)` 같은 표기 옵션), 목록 → `-`/`1.`
  - 옵션: `--flat-tables`(병합 무시) / `--html-tables`(병합 셀을 HTML `<table>`로)
  - → 구현: 기본이 평탄화(GFM), `--table-style html`, `--span-marks`로 정리함
- [x] TextExporter: 서식 제거, 표는 탭 구분
- [x] CLI: `yuja convert in.hwpx --to md [--out path] [--assets-dir]`, `yuja inspect in.hwpx`(구조 덤프)
- [x] 골든 테스트: 픽스처마다 기대 `.md` 저장, diff로 회귀 검출
- 완료 기준: 픽스처 전부 변환 성공, 텍스트 유실 0 (원본 텍스트 전수 추출 후 출력에 포함 여부 검사하는 테스트 추가)

### Phase 2 — DOCX 출력 (2~3일)
- [x] OOXML 직접 생성(`document.xml`, `styles.xml`, `[Content_Types].xml`, `_rels`) — 외부 라이브러리 없이 ZIP 쓰기
- [x] heading 스타일 매핑(Heading1~6), 표(gridSpan/vMerge로 병합 재현), 이미지 삽입(`word/media`)
  - 원본 셀 폭(hp:cellSz)·그림 표시 크기(hp:curSz)를 IR에 추가해 열 폭·그림 크기 재현
- [ ] 검증: Word·Pages·LibreOffice에서 열림 확인 (스크린샷 수동, 사용자 확인 필요)
  - 2026-10-24 Word(Mac)에서 실양식 2종 열기·PDF 저장 확인. 호환성 모드·빈 쪽 문제 수정. Pages·LibreOffice는 미확인
- 완료 기준: 픽스처 전부 DOCX 생성, LibreOffice headless로 PDF 변환이 에러 없이 됨(구조 유효성 대용)

### Phase 3 — HWP 5.0 바이너리 (5~8일)
결정 지점: **먼저 hwp-rs(MIT) 상태 확인** → 유지보수·표 파싱 수준이 충분하면 Rust 정적 라이브러리 + C FFI로 붙이고, 아니면 Swift 자체 구현.
자체 구현 시:
- [ ] CFB 리더: 헤더, FAT/DIFAT/miniFAT, 디렉터리 엔트리, 스트림 읽기 (스펙: MS-CFB 공개 문서)
- [ ] `FileHeader`: 버전, 압축·암호 플래그(암호면 명확한 에러)
- [ ] 레코드 파서(태그/레벨/크기, 확장 크기 처리)
- [ ] `DocInfo`: 글꼴·charShape·paraShape·style → heading/list 판별 근거
- [ ] `BodyText/SectionN`: PARA_HEADER/PARA_TEXT/PARA_CHAR_SHAPE/CTRL_HEADER(표 `tbl `, 그림 `gso `)/TABLE/LIST_HEADER
- [ ] 제어문자 처리(0x0A 줄바꿈, 0x0D 문단, 0x09 탭, 0x0B/0x0F~ 확장 제어 등 — 스펙 표로 확인)
- [ ] BinData 스트림(압축 여부 개별) → 이미지 추출
- [ ] HWPX와 **동일 IR**로 수렴 → 익스포터 재사용
- 완료 기준: 동일 문서의 HWP/HWPX 버전이 같은 Markdown을 내는 교차 테스트

### Phase 4 — PDF 출력 (단순 렌더) (2일)
- [ ] IR → NSAttributedString → `NSPrintOperation`/`CGPDFContext`로 페이징. 글꼴은 시스템 Apple SD Gothic Neo 고정
- [ ] 표는 NSTextTable 사용. 레이아웃 재현 목표 아님, "읽을 수 있는 PDF"만
- 완료 기준: 모든 픽스처가 열리는 PDF 생성

### Phase 5 — GUI: Shift-드래그 원형 메뉴 (5~7일)
- [ ] 메뉴바 상주 앱(LSUIElement). 설정: 출력 포맷 기본값, 출력 위치(원본 옆/지정 폴더), 자산 폴더 생성 여부
- [ ] 전역 이벤트 모니터: `NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .flagsChanged])` → 드래그 중 Shift 감지
  - 권한: 손쉬운 사용(Accessibility) + 입력 모니터링. 최초 실행 온보딩 화면에서 안내
- [ ] 드래그 중인 파일 식별: `NSPasteboard(name: .drag)`에서 `fileURL` 읽기. 실패 시 폴백: Finder 선택 항목을 AppleScript/ScriptingBridge로 조회
- [ ] 원형 메뉴: 투명 `NSPanel`(nonactivating, 커서 위치), SwiftUI 뷰. 섹터 = 해당 파일에 가능한 출력 포맷만. 키보드: 방향키/Enter/Esc. 마우스: 섹터 위에서 드롭
- [ ] 드래그 종료 시점 처리: 사용자가 섹터에 놓으면 변환 실행, 다른 곳에 놓으면 Finder 기본 동작 유지(드래그를 가로채지 않음이 핵심 — 가로채면 Finder 이동이 일어날 수 있음. 설계상 "메뉴 위에 드롭"일 때만 소비)
- [ ] 진행 표시 + 완료 알림(UNUserNotification), 실패 시 로그 열기
- [ ] Finder 빠른 동작(Quick Action, App Extension)도 추가 — 권한 없이 쓰는 대안 경로
- 완료 기준: 실기기에서 10회 연속 드래그 변환 성공, Finder 파일 이동 오발동 0회

### Phase 6 — 배포 (1~2일)
- [ ] 코드서명 + 노타라이즈 스크립트(`scripts/release.sh`). Developer ID 인증서 필요 → **Apple Developer 등록(린체인 938A952Y6Z) 완료 후 진행**. 그 전엔 미서명 빌드 + "우클릭 → 열기" 안내
- [ ] DMG 생성(create-dmg), GitHub Release, Homebrew Cask 탭(`linchain/homebrew-tap`)
- [ ] Sparkle로 자동 업데이트(선택)
- [ ] README(한/영), 데모 GIF, 지원 포맷 매트릭스

---

## 5. 일정 요약

| Phase | 내용 | 기간(추정) | 누적 |
|---|---|---|---|
| 0 | 부트스트랩·픽스처 | 0.5일 | 0.5일 |
| 1 | HWPX→MD/TXT CLI | 3~5일 | ~5일 |
| 2 | DOCX | 2~3일 | ~8일 |
| 3 | HWP 5.0 | 5~8일 | ~15일 |
| 4 | PDF | 2일 | ~17일 |
| 5 | GUI 원형 메뉴 | 5~7일 | ~23일 |
| 6 | 배포 | 1~2일 | ~25일 |

Phase 1 끝나면 이미 본인 업무에 쓸 수 있음(CLI). Phase 3·5는 순서 바꿔도 됨(HWP 5.0 수요가 더 급하면 3 먼저).

---

## 6. 리스크와 대응

| 리스크 | 대응 |
|---|---|
| HWP 5.0 스펙 세부(제어문자·레코드 변형)가 문서와 다름 | 실파일 기반 TDD. `yuja inspect`로 레코드 덤프 → 픽스처마다 확인 |
| 병합 셀을 GFM 표가 표현 못함 | 기본은 평탄화 + 옵션으로 HTML 표. 사용자가 선택 |
| 전역 이벤트 모니터가 Finder 드래그를 방해 | 드래그 이벤트를 소비하지 않고 관찰만. 드롭 판정은 메뉴 패널의 자체 드롭 타깃으로 |
| 노타라이즈 불가(개발자 계정 대기) | 미서명 배포로 먼저 공개. 계정 활성화 후 재배포 |
| 구버전 HWP 3.x / 암호화 파일 | 명확히 "미지원" 에러. 범위 밖 |
| 배치 변환 시 메모리 | XML은 스트리밍 파서, 섹션 단위 처리. 대용량 BinData는 디스크 직행 |

---

## 7. CLAUDE.md 초안 (별도 파일로 저장)

```markdown
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

## 막히면
- 포맷 스펙 불명확 → yuja inspect로 실파일 덤프를 먼저 보고 판단.
- 결정이 필요하면 추측 실행 말고 멈춰서 사용자에게 묻는다(사용자 최우선 지침).
```

---

## 8. 사용자가 준비할 것 (Claude Code 시작 전)
1. 샘플 HWP(5.0) 3개 + HWPX 3개 — 표·이미지·목록 포함, 민감정보 없는 것 (정부과제 공고문이 적합)
2. Xcode 설치 확인, `xcode-select -p` 정상
3. 프로젝트명 확정 (Yuja / 다른 이름)
4. GitHub 저장소 생성 위치 결정 (linchaindev 조직 vs 개인)
5. hwp-rs 사용 여부는 Phase 3 진입 시 Claude Code가 조사 후 보고 → 결정

---

## 9. Claude Code 첫 프롬프트 (복붙용)

```
PLAN.md와 CLAUDE.md를 읽고 Phase 0을 시작해. 
Tests/Fixtures에 넣을 샘플 파일은 내가 제공할 테니 먼저 필요한 파일 종류와 개수를 정리해서 알려주고, 
그동안 Package.swift와 IR 모델, CI 설정까지 만들어. 
Phase 0 완료 기준 충족하면 보고하고 멈춰.
```
