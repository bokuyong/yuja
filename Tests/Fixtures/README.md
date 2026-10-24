# 테스트 픽스처

## hwpx/

HWPX를 **풀어 놓은 형태**로 둔다. 테스트가 실행될 때 ZIP으로 묶는다 (`Support/Fixtures.swift`).

- `_common/` — 모든 픽스처에 공통인 mimetype, container.xml, content.hpf, header.xml
- `<이름>/` — 픽스처별 파일. `_common`의 같은 경로 파일을 덮어쓴다 (보통 `Contents/section0.xml`, `BinData/*`)
- `<이름>.expected.md`, `<이름>.expected.txt` — 골든 출력

`_common/Contents/header.xml`의 id 표:

| charPr | 뜻 | paraPr | 뜻 |
|---|---|---|---|
| 0 | 보통 | 0 | 바탕글 |
| 1 | 굵게 | 1 | 개요 1 → `#` |
| 2 | 기울임 | 2 | 개요 2 → `##` |
| 3 | 굵게+밑줄 | 3 | 글머리표 1수준 |
| 4 | 취소선 | 4 | 글머리표 2수준 |
|   |   | 5 | 문단 번호 1수준 |
|   |   | 6 | 가운데 정렬 |

기대 출력 갱신:

```bash
YUJA_UPDATE_GOLDEN=1 swift test --filter GoldenTests
```

갱신 후 `git diff Tests/Fixtures`로 바뀐 부분을 반드시 눈으로 확인한다.

## 실문서

민감정보가 없는 공개 문서만 저장소에 넣는다. 넣을 수 없는 문서는 로컬 폴더에 두고
텍스트 유실 검사만 돌린다:

```bash
YUJA_CORPUS_DIR=~/yuja-corpus swift test --filter NoTextLossTests
```
