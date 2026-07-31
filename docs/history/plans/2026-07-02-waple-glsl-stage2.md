# GLSL Stage 2 + 버그 정리 — 실행 계획

설계: specs/2026-07-02-waple-glsl-stage2-design.md. 브랜치 `feat/glsl-stage2`, 태스크별 TDD 커밋, ff-merge.

1. **전처리기: 비정수 #define 텍스트 치환** — `#define AMOUNT 0.5` 본문 치환. (ShaderPreprocessorTests)
2. **precision 한정자 제거** — highp/mediump/lowp + `precision` 문. (GLSLTranslatorTests)
3. **엔진 심볼 상시 매핑** — 본문 출현 기반 매핑(g_Time/mvp/audio/texRes/a_*/gl_FragCoord), usesAudio 본문 스캔. (GLSLTranslatorTests + MSL 컴파일)
4. **파일 스코프 const 방출** — MSL `constant` 전역. (GLSLTranslatorTests)
5. **헬퍼 함수 방출 + 캡처** — 파싱(word-bound main 포함), 시그니처 변환, 캡처 승격(머티리얼/엔진/varying/텍스처+smp/오디오), 전이 폐쇄, 호출부 재작성. (GLSLTranslatorTests 다수 + MSL 컴파일 + PNG 오라클 1)
6. **premult 규약 전환(원자 커밋)** — f_main premult 1회 / opacity·pulse straight / 번역기 주입 제거 + gl_FragColor 로컬변수 방식. 체인 오라클 0.7×0.7→0.49. (EffectShaders/Translated/Audio render tests 갱신)
7. **dialect 추가** — atan2/ddx/ddy/texSample2DLod. (GLSLTranslatorTests)
8. **vertex 오디오** — assemble vertex audio 파라미터 + SceneRenderer vertex 바인드. (MSL 컴파일 + SceneAudioRenderTests)
9. **texRes per-slot dims** — aux 실제 dims. (render test)
10. **파티클 z-순서 인터리브** — SceneDocument 순서 보존 + 렌더러 병합 드로우 + PNG 오라클.
11. **최종 검증/머지** — 전체 스위트, 릴리스 빌드, PNG 셀프리뷰, main ff-merge, 메모리 갱신.
