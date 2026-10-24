# HWPX 구조 노트 (실파일 관찰 기반)

관찰 대상: 한컴오피스가 저장한 공공 양식 HWPX 3종 (빈 서식, 저장소에는 포함하지 않음).

## 패키지
- `mimetype` = `application/hwp+zip` (첫 엔트리, 무압축)
- `META-INF/container.xml` → rootfile `Contents/content.hpf`
- `Contents/content.hpf` (OPF)
  - `opf:metadata`: `opf:title`, `opf:meta name="creator"` 등
  - `opf:manifest/opf:item id href media-type` — 이미지도 여기 등록됨 (`id="image1" href="BinData/image1.bmp"`)
  - `opf:spine/opf:itemref idref` — header, section0 … 순서
- `Contents/header.xml`, `Contents/section0.xml` …, `BinData/*`, `Preview/PrvText.txt`(미리보기 텍스트, 사용 안 함)

## header.xml (`hh:`)
- `hh:charProperties/hh:charPr id` — 자식 `hh:bold`, `hh:italic` 존재 여부, `hh:underline type≠NONE`, `hh:strikeout shape≠NONE`
- `hh:paraProperties/hh:paraPr id`
  - `hh:align horizontal` = JUSTIFY | LEFT | CENTER | RIGHT | DISTRIBUTE
  - `hh:heading type level` — type = NONE | OUTLINE | NUMBER | BULLET, level 0부터
  - "개요 1~10" 스타일은 OUTLINE paraPr을 가리킴 → 문단의 `paraPrIDRef`만 보면 됨
- `hh:styles/hh:style` — 이름 참고용. 판별은 paraPr로 한다.
- `hp:switch/hp:case/hp:default` — 같은 값의 호환용 이중 표기. `default`는 건너뜀.

## section XML (`hs:sec` > `hp:p`)
- `hp:p paraPrIDRef styleIDRef pageBreak` > `hp:run charPrIDRef` > `hp:t`
- `hp:t`는 혼합 콘텐츠: 텍스트 사이에 `hp:lineBreak`, `hp:tab`, `hp:nbSpace`, `hp:fwSpace`, `hp:hyphen`
- 표·그림·컨트롤은 **run 안의 인라인 개체**. 한 문단에 텍스트 + 표가 섞일 수 있음 → 순서 보존 필요
- 표: `hp:tbl rowCnt colCnt` > `hp:tr` > `hp:tc` > `hp:subList` > `hp:p`…, 그리고 subList **뒤에** `hp:cellAddr colAddr rowAddr`, `hp:cellSpan colSpan rowSpan`
  - `tr`에는 실제 셀만 있음 (병합으로 덮인 칸은 없음)
  - 셀 안에 표가 중첩될 수 있음
  - 제목 상자로 1×1 표를 자주 씀
- 그림: `hp:pic` … `hc:img binaryItemIDRef="image1"` → manifest id. `hp:container`(묶음 개체) 안에 들어있기도 함. BMP가 흔함 → PNG 변환
- `hp:shapeComment` — "그림입니다. 원본 그림의 이름…" 같은 자동 설명. 본문 텍스트 아님
- 필드: `hp:ctrl/hp:fieldBegin type=FORMULA` … `hp:t`(계산 결과) … `hp:fieldEnd`. 표시값은 `hp:t`에 있음. `hp:parameters` 안의 문자열은 본문 아님
- 양식 개체: `hp:checkBtn value=CHECKED|UNCHECKED caption`, `hp:radioBtn`
- 구역 설정: 첫 문단 run 안의 `hp:secPr`, `hp:ctrl/hp:colPr`
- 글상자: `hp:rect` 등 > `hp:drawText` > `hp:subList`
- 각주/미주/머리말/꼬리말/메모: 컨트롤 안의 `hp:subList`
- 수식: `hp:equation` > `hp:script` (한컴 수식 스크립트)

## 아직 처리 안 하는 것
- 개요·번호 문단의 자동 번호 텍스트("1.", "가.")는 `hp:t`에 없고 numbering 정의로 생성됨 → 현재 출력에 안 나옴
- 한컴 PUA 문자(예: U+F03C5 체크박스 모양)는 그대로 둠
