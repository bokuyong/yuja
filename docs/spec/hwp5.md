# HWP 5.0 — 구현 방식 조사 (2026-10-24)

## hwp-rs (hahnlee/hwp-rs) 상태

| 항목 | 내용 |
|---|---|
| 라이선스 | **Apache-2.0** (계획서의 "MIT"는 잘못된 기억). MIT 프로젝트에 넣을 수는 있으나 NOTICE·저작권 고지 필요 |
| 활동 | 마지막 커밋 2022-11-11, crate `hwp` 0.2.0 (2022-11). 약 4년간 정지 |
| 규모 | 약 7,500줄. 레코드·DocInfo·표·도형·수식·각주·머리말 등 구조는 폭넓게 파싱 |
| 견고성 | 진입점 `HWP::from_bytes(&[u8]) -> Self` — **Result가 아님**. `unwrap()` 551곳 → 예상 밖 입력에서 panic |
| 열린 이슈 | #97 실문서에서 `doc_info/style.rs` unwrap panic, #98 금융위원회 공개 문서(배포용 추정)에서 복호화 panic — 둘 다 미해결 |
| 연동 비용 | Rust 툴체인(로컬·CI) 추가, arm64+x86_64 정적 라이브러리, C ABI, FFI 경계 `catch_unwind`, Rust 구조체 → 우리 IR 변환 코드는 어차피 별도로 작성 |

## 로컬 표본 조사 (`hwpprobe.py`, 표준 라이브러리 80줄 시제품)

| 파일(가명) | 버전 | 압축 | 배포용 | 특징 |
|---|---|---|---|---|
| common-form | 5.0.5.0 | O | X | 표 56, 양식 개체(form) 23 |
| startup-form | 5.0.5.0 | O | X | 표 14 |
| schedule | 5.1.1.0 | O | X | 표 2, 쪽 번호 |
| exam | 5.1.0.1 | O | X | 수식(eqed) 115 |
| worksheet | 5.1.0.1 | O | X | 그림(gso) 5, 수식 13, 머리말/꼬리말, BinData 1 |

CFB → FileHeader → BodyText 레코드(태그/레벨/크기, 0xFFF 확장 크기) → raw deflate 해제까지
시제품이 5개 전부 문제없이 통과했다. 컨테이너·레코드 계층은 작고 명확하다.

## 결론: Swift 자체 구현 (권장)

- 실패해도 앱이 죽지 않고 `YujaError`(한국어 메시지)로 끝나야 한다 → hwp-rs는 이 원칙과 정면으로 맞지 않음
- 정지된 상류 + 미해결 panic → 쓰려면 사실상 포크 유지보수
- 어느 쪽이든 IR 변환은 우리가 작성. HWPX에서 만든 문단모양/글자모양/표 병합 처리를 그대로 재사용 가능
- hwp-rs는 Apache-2.0이므로 **레코드 레이아웃 참고 자료**로 쓴다 (코드를 옮길 경우 고지 추가)

## 기준 문서

- 한컴 공개 「한글문서파일형식 5.0 revision 1.3」(2018-11-08): https://cdn.hancom.com/link/docs/한글문서파일형식_5.0_revision1.3.pdf
- MS-CFB (Compound File Binary) 공개 명세

## 결정 (2026-10-24)

- Swift 자체 구현. 배포용 문서 복호화 포함.
- 같은 문서의 HWP/HWPX 쌍 픽스처(Phase 3 완료 기준 교차 테스트용)는 아직 없음

---

# 형식 요약 (구현 기준)

출처: 한컴 「한글문서파일형식 5.0 revision 1.3」(이하 "스펙", 표 번호는 스펙의 것).
**스펙과 실파일이 다른 곳은 ⚠로 표시** — 로컬 표본 5종(5.0.5.0 ~ 5.1.1.0)으로 확인했다.

## 컨테이너 (CFB, MS-CFB)

```
FileHeader            256B, 무압축
DocInfo               레코드 스트림
BodyText/Section0..N  레코드 스트림 (배포용이면 비어 있고 ViewText/SectionN에 암호화본)
BinData/BIN0001.png   그림 등. 이름 = "BIN%04X.<ext>" (DocInfo BIN_DATA의 저장 아이디, 16진 4자리)
PrvText, PrvImage, DocOptions/*, Scripts/*  (사용 안 함)
```

- 4096바이트 미만 스트림은 mini stream(64B 섹터)에 있다. 실파일의 FileHeader는 항상 mini stream.

## FileHeader (표 3)

| 오프셋 | 내용 |
|---|---|
| 0 | `"HWP Document File"` (32B) |
| 32 | 버전 UINT32 `0xMMnnPPrr` |
| 36 | 속성 UINT32 — bit0 압축, bit1 암호, bit2 배포용, bit4 DRM, bit8 공인인증서 암호화 |

- 압축이면 DocInfo·BodyText·(BinData 기본값) 스트림 전체가 **raw deflate** (zlib 헤더 없음)
- 암호(bit1)·DRM(bit4, bit10)·공인인증서 암호화(bit8)는 지원하지 않음 → 명확한 에러

## 레코드 (4.1)

헤더 UINT32 = TagID(하위 10bit) | Level(다음 10bit) | Size(상위 12bit). Size가 0xFFF면 다음 UINT32가 실제 크기.
TagID는 `HWPTAG_BEGIN(0x10) + n`. Level이 계층 깊이 — 자식은 "다음에 오는, 레벨이 더 큰 레코드들".

## DocInfo에서 쓰는 레코드

| Tag | 값 | 사용 |
|---|---|---|
| BIN_DATA | 18 | 속성 UINT16(bit0-3 유형: 0 LINK, 1 EMBEDDING, 2 STORAGE / bit4-5 압축: 0 문서 기본, 0x10 압축, 0x20 무압축). EMBEDDING이면 저장 아이디 UINT16 + 확장자(WORD 길이 + WCHAR[]). 문서 내 순서(1부터)가 그림이 참조하는 번호 |
| CHAR_SHAPE | 21 | 속성 UINT32 @46: bit0 기울임, bit1 진하게, bit2-3 밑줄 종류(≠0), bit18-20 취소선(≠0). 레코드 순서 = 글자모양 ID |
| PARA_SHAPE | 25 | 속성1 UINT32 @0: bit2-4 정렬(0 양쪽, 1 왼쪽, 2 오른쪽, 3 가운데, 4 배분, 5 나눔), bit23-24 머리 모양(0 없음, 1 개요, 2 번호, 3 글머리표), bit25-27 수준(0부터). 레코드 순서 = 문단모양 ID |
| DISTRIBUTE_DOC_DATA | 28 | 배포용 문서 데이터 256B |

## BodyText 레코드

| Tag | 값 | 내용 |
|---|---|---|
| PARA_HEADER | 66 | nchars UINT32(최상위 비트 무시), 컨트롤 마스크 UINT32, 문단모양 ID UINT16 @8, 스타일 UINT8, 나누기 종류 UINT8 @11(0x01 구역, 0x04 **쪽**, 0x08 단) |
| PARA_TEXT | 67 | UTF-16LE. 아래 제어 문자 참고. 끝의 13(문단 끝)은 버린다 |
| PARA_CHAR_SHAPE | 68 | (시작 위치 UINT32, 글자모양 ID UINT32) × n. 위치는 PARA_TEXT의 **WCHAR 단위**(제어 문자 8칸 포함) |
| CTRL_HEADER | 71 | 컨트롤 ID(4바이트, 리틀엔디언 정수 = MAKE_4CHID) + 컨트롤별 데이터. 개체 컨트롤이면 공통 속성(표 69): 폭 @16, 높이 @20 (HWPUNIT) |
| LIST_HEADER | 72 | ⚠ 문단 수가 스펙엔 INT16이나 **실제 UINT32**. 속성 UINT32 @4. 셀이면 @8부터 셀 속성(표 80): 열, 행, 열 병합, 행 병합 (UINT16), 폭, 높이 (HWPUNIT) |
| TABLE | 77 | 표 속성 (행·열 수 등). 셀은 형제 LIST_HEADER들 |
| SHAPE_COMPONENT | 76 | 그리기 개체 요소. 묶음이면 자식에 다시 SHAPE_COMPONENT |
| SHAPE_COMPONENT_PICTURE | 85 | ⚠ BinData 번호 UINT16 @71 (테두리 12 + 좌표 32 + 자르기 16 + 여백 8 + 밝기·대비·효과 3) |
| EQEDIT | 88 | 속성 UINT32, 스크립트 길이 WORD @4, 스크립트 WCHAR[] @6 |
| FORM_OBJECT | 91 | 앞 12바이트(유형 4CC 두 번 + 길이) 뒤 UTF-16 속성 문자열. 유형 `+cbt` 체크박스 / `+rbt` 라디오. `Caption:wstring:N:…`, `Value:int:1` = 선택 |

### 문단 안 제어 문자 (표 6)

| 코드 | 형식 | 크기(WCHAR) | 뜻 |
|---|---|---|---|
| 0, 10, 13, 24–31 | char | 1 | 10 줄바꿈, 13 문단 끝, 24 하이픈, 30 묶음 빈칸, 31 고정폭 빈칸 |
| 4–9, 19, 20 | inline | 8 | 9 탭, 4 필드 끝 |
| 1–3, 11, 12, 14–18, 21–23 | extended | 8 | 11 표·그리기 개체, 15 숨은 설명, 16 머리말/꼬리말, 17 각주/미주, 3 필드 시작, 2 구역/단 정의 … |

- inline·extended는 `[코드][4CC 2칸][4칸][코드]` 8칸. extended 컨트롤마다 **같은 순서로** CTRL_HEADER 자식이 하나씩 있다
- 필드(누름틀·계산식 등)의 표시 내용은 필드 시작(3)과 끝(4) 사이의 일반 텍스트

### 컨트롤별 하위 구조 (실파일 확인)

```
CTRL_HEADER 'tbl '            (L)
  TABLE                       (L+1)
  LIST_HEADER (셀 속성 포함)   (L+1)
  PARA_HEADER …               (L+1)  ← 셀 문단, 다음 LIST_HEADER 전까지
  LIST_HEADER …
CTRL_HEADER 'gso '
  SHAPE_COMPONENT
    SHAPE_COMPONENT_PICTURE   (그림) / LIST_HEADER + PARA_HEADER … (글상자) / SHAPE_COMPONENT … (묶음)
CTRL_HEADER 'eqed' → EQEDIT
CTRL_HEADER 'head' | 'foot' | 'fn  ' | 'en  ' | 'tcmt' → LIST_HEADER + PARA_HEADER …
CTRL_HEADER 'form' → FORM_OBJECT
```

## 배포용 문서 (스펙 밖 — hwp-rs(Apache-2.0) 구현 참고)

FileHeader bit2가 켜지면 본문이 `ViewText/SectionN`에 있다. 각 스트림:

1. 첫 레코드 = DISTRIBUTE_DOC_DATA(태그 28, 256B)
2. seed = 앞 4바이트 UINT32 LE. MSVC `rand()` LCG (`state = state*214013 + 2531011; r = (state>>16) & 0x7FFF`)
3. 256바이트 마스크 생성: `fill = rand() & 0xFF`, `n = (rand() & 0xF) + 1` → fill을 n번 채우기 반복
4. 데이터 ⊕ 마스크 → 오프셋 `4 + (seed & 0xF)`부터 16바이트가 AES-128 키
5. 레코드 뒤 나머지 바이트를 AES-128-ECB 복호화 (16의 배수만큼; 나머지는 버림) → 압축이면 raw deflate 해제 → 일반 섹션과 동일

DocInfo는 배포용이어도 평문이다 (hwp-rs 기준. 실제 배포용 표본으로는 아직 확인하지 못함).

## 구현 메모

- 수식(`eqed` / `hp:equation`)은 블록이 아니라 문장 안의 **수식 런**(`Run.equation`)으로 둔다. Markdown에서는 인라인 코드.
  HWPX 파서도 같게 바꿔 두 형식의 출력이 일치한다.
- 테스트용 HWP 작성기(`Tests/YujaCoreTests/Support/HWPFixture.swift`, `CFBWriter.swift`)로 HWPX 픽스처와 같은 내용을 만들어
  출력이 같은지 교차 검사한다. 배포용 암호화·비압축·손상 입력(잘림·비트 뒤집기)도 같은 작성기로 검사.
- 실문서 텍스트 유실 검사는 PrvText(한컴 미리보기 텍스트, 문서 앞부분)를 기준으로 한다. PrvText에는 수식이 빠져 있어서
  낱말 순서 비교를 쓴다.

## 아직 확인 못 한 것

- 실제 배포용 문서 표본 (알고리즘은 hwp-rs 기준, 왕복 테스트로만 확인)
- 취소선: 표본 `startup-form`의 "<별첨 3>" 등에 취소선 비트(18–20)=1, 모양=15("3D 단선")가 켜져 있어 그대로 취소선으로 낸다.
  같은 사업의 HWPX 양식에도 `strikeout shape="3D"`가 있어 두 형식이 일치하지만, 한컴에서 실제로 줄이 그어져 보이는지는 미확인
- 머리말·꼬리말은 그것이 정의된 문단 뒤에 한 번만 나온다 (HWPX와 동일)
