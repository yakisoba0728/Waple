# macOS 세션 프롬프트 — 임베디드 mip 체인 복원 검증

아래를 그대로 맥의 AI 에이전트에게 주면 된다.

---

## 배경 (그대로 전달)

Waple 저장소의 `feat/we-engine-port-design` 브랜치에 커밋 4개가 올라가 있다.
**윈도우에는 Swift 툴체인이 없어 아무것도 빌드·실행하지 못했다.** 네가 처음 실행하는 사람이다.

핵심 변경 하나:
Wallpaper Engine 의 `.tex` 컨테이너는 임베디드 PNG/JPEG 에도 축소본을 레벨마다
**독립 PNG/JPEG 파일**로 넣어 둔다. Waple 은 "인코딩 이미지는 저장 mip 이 없다" 는
**거짓 전제 주석**을 근거로 그 체인을 버리고 있었다. 코퍼스 4,991개 전수 측정 결과:

- 임베디드 텍스처 796개(PNG 766 · JPEG 30) 중 **701개가 mipCount>1**
- level>0 페이로드 **2,432개 전부** 시그니처 정상 + 치수가 정확히 `(imgW>>L, imgH>>L)`
- 불일치 0 · LZ4 해제 실패 0 · mip0 치수 불일치 0
- 영향: **워크샵 씬 146종** + 설치 assets 7개

증상은 축소 렌더 시 지글거림(에일리어싱)이다. 샘플러(`QuadShaders` / `GLSLTranslator`)는
이미 `mip_filter::linear` 이고 업로더(`makeMipmappedTexture`)도 이미 있다 —
파스가 체인을 넘기고 디코더가 레벨별로 디코드하기만 하면 그 자리에서 샘플된다.

**이 변경은 의도적으로 픽셀을 바꾼다.** 그래서 검증 질문이 평소와 다르다:
"안 바뀌었는가" 가 아니라 **"바뀌어야 할 씬만 바뀌었는가"** 다.

## 준비

1. 저장소를 바탕화면에 클론(또는 이미 있으면 fetch)하고 브랜치를 체크아웃한다.

```bash
cd ~/Desktop
git clone <repo-url> Waple 2>/dev/null || true
cd ~/Desktop/Waple
git fetch origin
git checkout feat/we-engine-port-design
git pull --ff-only
git log --oneline -4     # eb5976f / 924ffe6 / d2670e1 / 53b69ac 가 보여야 한다
```

2. 실물 코퍼스가 있어야 한다(없으면 관련 테스트가 skip 되고 검증이 성립하지 않는다).

```bash
export WAPLE_DEV_ROOT=~/Downloads/wallpaper_dev
export WAPLE_REAL_PKGS=$WAPLE_DEV_ROOT/backgrounds
export WAPLE_BASE_ASSETS=$WAPLE_DEV_ROOT/assets
ls "$WAPLE_REAL_PKGS" | head -3      # 워크샵 ID 디렉터리들이 보여야 한다
```

3. `pip3 install pillow` (골든 픽셀 대조에 필요)

## 0단계 — **구현 전 기준선을 먼저 뜬다** (이걸 건너뛰면 5단계가 무의미하다)

커밋된 `spec/golden/snapshot/baseline-81098bb` 는 **debug** 캡처다.
release 캡처와는 **코드 변경이 없어도 30종이 다르다**(실측). 그래서 대조에 쓸 수 없다.
필요한 것은 **이 변경 직전 커밋(`eaaee0c`)의 release 캡처**다.

```bash
cd ~/Desktop/Waple
git checkout eaaee0c              # 변경 직전
swift run -c release WapleCompat --capture ~/Downloads/waple-pre --label pre "$WAPLE_DEV_ROOT"
git checkout feat/we-engine-port-design
export WAPLE_PRE_BASELINE=~/Downloads/waple-pre/pre
ls "$WAPLE_PRE_BASELINE/thumbs" | wc -l    # 0 이 아니어야 한다
```

캡처는 release 로 10분 안팎 걸린다(debug 는 28분이라 반드시 `-c release`).

## 1단계 — 검증 스크립트 실행

```bash
cd ~/Desktop/Waple
bash scripts/mac-session/verify-embedded-mips.sh 2>&1 | tee ~/Downloads/verify-mips-output.txt
```

스크립트가 6가지를 본다: 빌드 / 신규·변경 테스트 / **실물 코퍼스 프로브** / 전 스위트
무회귀 / 골든 캡처 / **기대 집합 대조**.

## 보고해야 할 것

번호 순서대로, 숫자를 그대로:

1. **빌드** 성공/실패. 실패면 컴파일 에러 전문. (윈도우에서 컴파일 검증을 못 했으니
   여기서 깨질 가능성이 실제로 있다. 특히
   `Tests/WapleRenderTests/TexMipChainDecodeTests.swift` 의 신규 헬퍼 `solidPNG` 와
   `Sources/WapleRender/TexDecoder.swift` 의 `rgbaLevels` encoded 분기.)

2. **`[mipchain-probe]` 로그 한 줄 전체.** `found=` `decoded=` `embedded=` `failures=`.
   - `embedded` 가 **701 근처**여야 한다. 0 이면 코퍼스가 안 붙은 것이고 그러면
     통과해도 아무것도 증명하지 못한다.
   - `decoded != found` 면 실패한 텍스처 목록.

3. **전 스위트** 결과 — Executed 합과 실패 수. (종전 기준 2,138)

4. **골든 대조 3숫자**: `기대 집합 안` / `기대 집합 밖` / `안 바뀐 기대 씬`.
   - **`기대 집합 밖` 이 0 이 아니면 그 씬 ID 전부**. 이 커밋이 건드릴 이유가 없는
     씬이 바뀐 것이므로 가장 중요한 신호다.
   - `기대 집합 안` 이 0 이어도 문제다 — 화면에 아무 영향이 없다면 배선이 끊긴 것이다.

5. 눈으로 본 인상: 아래 씬의 before/after 썸네일을 열어 **지글거림이 줄었는지**.
   `~/Downloads/waple-pre/pre/thumbs/<id>.png` 대 `~/Downloads/waple-verify-mips/mips-*/thumbs/<id>.png`

   ```
   2902406982  2867182492  3113287126  2188368235  2844219893
   ```

## 하지 말 것

- 실패를 우회하려고 테스트를 고치지 마라. 실패는 그대로 보고한다.
- `기대 집합 밖` 변화를 "아마 무해" 로 넘기지 마라. ID 를 그대로 보고한다.
- 골든 기준선을 새로 커밋하지 마라(재베이스라인 판단은 이쪽에서 한다).
