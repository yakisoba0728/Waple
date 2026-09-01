import Foundation

/// effect.json 매니페스트(실물 스키마): 멀티패스 + 이름 있는 FBO(다운스케일 타깃).
/// bind.name "previous" = 효과 입력(레이어 베이스 또는 이전 효과 출력), 그 외 = fbos 의 이름.
/// target 부재 = 효과 출력에 기록.
///
/// ## AJ-B2 스키마 전수 (2026-08-21)
///
/// **원본 파서는 `0x1401e7170`–`0x1401e8a9d` 하나뿐이다**(`.pdata` 단일 조각 — `merged()` 도
/// 같은 범위). 그 함수가 `Json::Value::find`/`operator[]` 로 부르는 키 **전부**를 떠 보면:
///
/// | 층 | 키 | 비고 |
/// | --- | --- | --- |
/// | 루트 | `fbos` `passes` `functions` | 그 외 루트 키는 이 함수가 **한 번도 안 본다** |
/// | `fbos[]` | `name` `format` `scale` `fit` `width` `height` `uvs` `unique` `clear` `conditions` | `name`/`format` 둘 다 문자열이라야 선언이 산다(`0x1401e7440`) |
/// | `passes[]` | `material` `command` `source` `target` `bind` `compose` `conditions` | |
/// | `bind[]` | `name` `index` `conditions` | 원소가 태그 7 이라야 하고(`0x1401e7e8b`), `name` 은 태그 4, `index` 는 태그 1/2/3(`0x1401e7ea3` `dec`+`cmp 2`+`ja`). `conditions` 는 **파스 시점에 평가**해 거짓이면 그 bind 를 아예 안 만든다(`0x1401e7ed6`) |
/// | `functions.<이름>` | `action` `fbos` | |
///
/// 파서가 아는 **문자열 값**도 닫혀 있다:
/// `command` = `"copy"`(`0x1401e7ba1`, 길이 4 `memcmp`) → 1 · `"swap"`(`0x1401e7bcf`) → 2 ·
/// 그 외 전부 **0 = 보통 셰이더 패스**(에러가 아니다). `uvs` = `"repeat"` 만.
/// `format` 은 `rgba_backbuffer`/`rgb_backbuffer` 선처리 후 19종 해시맵(§Format).
/// `action` 은 `"clear"` 뿐.
///
/// ### 이 파서가 **안 읽는** effect.json 키 — 동봉/설치본 전수
///
/// (동봉 `Sources/WapleRender/Resources/WEAssets` effect.json **128개** ·
///  설치본 `wallpaper_engine` effect.json **135개**. 관대 파서 필요분 각 27개 = `//` 주석·후행 콤마.)
///
/// | 키 | 동봉 파일 | 설치본 파일 | wallpaper64.exe 에서 |
/// | --- | ---: | ---: | --- |
/// | `dependencies` | **128 (100%)** | **135 (100%)** | **동명이키다 — effect.json 쪽은 엔진이 안 읽는다.** 문자열 `0x140490248` 의 리더는 씬 오브젝트 베이스 ctor `0x1401ddbb0`–`0x1401de19b` 하나뿐이고(`find` `0x1401dddb2`), 원소마다 `0x1401dde9d` `isUInt64`(`0x140088800` — 태그1 은 `int64>=0`, 태그2 는 true, 태그3 은 `0≤d<2^64 && frac==0`, 그 외 false)로 **정수인지 먼저 거른다**. 아니면 `0x1401ddea4 je 0x1401de0c6` 로 그 원소를 건너뛴다. effect.json 의 `dependencies` 는 **자산 경로 문자열 배열**이라 전건 탈락 → 집합이 빈다. 정수 갈래(= 씬 `objects[].dependencies`)는 우리도 읽는다(`SceneDocument.swift:2079`·`:2499`) |
/// | `group` | 128 | 135 | 문자열 `0x140474dfc` 는 있으나 xref 4곳이 전부 `0x140021e50`–`0x14002e6e0`(프로퍼티/UI 스키마)이고 이펙트 파서가 아니다 |
/// | `name` | 127 | 134 | 이펙트 파서 미참조(에디터 표시명) |
/// | `description` | 125 | 132 | 정본 판정과 동일 — 리더 0(`docs/re/unimplemented-json-keys.md` §5.2 #2) |
/// | `preview` | 99 | 106 | 문자열 `0x140489ca8` xref 6곳 전부 `0x14011d3b0`/`0x14011d7d0`(project 프리뷰 이미지) |
/// | `version` | 69 | 75 | 정본 판정과 동일 — 자산 스키마 리더 없음(§5.2 #1) |
/// | `replacementkey` | 68 | 68 | **바이너리에 문자열 자체가 없다**(ASCII·UTF-16 전수 0). 우리는 파스한다 — 셰이더 관례 경로 폴백용(아래 `replacementKey`)이라 원본보다 넓은 쪽이고 무해하다 |
/// | `gizmos` `performance` `editable` | 21 · 12 · 2 | 21 · 12 · 2 | **셋 다 바이너리에 문자열 없음** → 에디터 전용. 안 읽는 게 맞다 |
///
/// 즉 **effect.json 루트 키 중 엔진이 런타임에 읽는 것은 `fbos`/`passes`/`functions` 셋뿐**이고
/// 나머지는 전부 에디터·패키징 메타다. 우리 파서가 추가로 읽는 `replacementkey` 는 원본보다
/// 넓은 쪽(셰이더 관례 경로 폴백)이라 무해하다.
///
/// **동명이키 주의** — `dependencies` 는 두 스키마에 같은 이름으로 있고 **타입이 다르다**:
/// 씬 `objects[].dependencies` 는 **정수 배열**(오브젝트 id, 우리도 읽는다)이고
/// effect.json 의 것은 **문자열 배열**(자산 경로)이다. 원본의 유일한 리더가 `isUInt64` 게이트를
/// 걸어 문자열을 통째로 버리므로 후자는 엔진에서도 죽은 키다.
///
/// ### `passes[].combos` 는 effect.json 이 아니라 **씬 쪽**이다
///
/// 파서가 `"combos"`(`0x14048b4c4`)를 부르는 자리는 `0x1401e7319` 하나이고, 대상이 루트 문서
/// (`[rbp+0xc0]`, `fbos`/`passes` 를 읽는 그 객체)가 **아니라** 호출자가 넘긴 씬 이펙트 인스턴스
/// (`rsi`)다. 실제로 동봉·설치본 effect.json 전 263개에 `passes[].combos` 는 **0건**이고
/// (`passes[].shader` 도 0건 — effect.json 은 전건 `material` 로만 셰이더를 가리킨다),
/// `constantshadervalues` 는 머티리얼 JSON 쪽 키다(`docs/re/material-blend.md` §1, 107파일).
public struct EffectManifest: Equatable {
    /// X-⑪(G-A5-07/G-B2-05): `conditions` — fbo·pass·bind 를 콤보 값으로 켜고 끄는 게이트.
    ///
    /// 형태는 **배열 안의 객체들**이고, 객체의 각 키가 콤보 이름이다:
    /// ```json
    ///   "conditions": [ { "LIGHTING": 1 } ]                       // 맨몸 = 등호
    ///   "conditions": [ { "POINTEMITTER": { "op": "ge", "value": 1 } } ]
    /// ```
    ///
    /// 원본 평가기 `0x1401e63b0`(1,478 B) 실측 규약 — 놀라운 게 셋이다:
    ///
    /// ① **맨몸 `{"LIGHTING": 1}` 은 `!=0` 도 `>=` 도 아니라 정확히 `==` 다**
    ///    (`0x1401e68c3` `cmp edx, r14d` + `0x1401e68ca` `cmove`). 이게 중요한 이유:
    ///    `RENDERING` 은 0/1/2/3 옵션 콤보라, `>=` 였다면 1·2 에서도 켜졌을 것이다.
    /// ② **명명 연산자는 `ge`/`gt`/`le`/`lt` 4종뿐이고, 미지·부재 op 는 false 고정이 아니라
    ///    등호 폴백**이다(`0x1401e67b7`). 문자열 길이가 정확히 2 가 아니면 비교 자체를 시도하지 않는다.
    /// ③ **fail-open 이다.** 배열이 아니면 true(`0x1401e63d1` 의 `cmp byte [rcx+8], 6` + `jne`).
    ///    빈 배열도 true — 다만 그건 전용 검사가 아니라 **루프 종료 분기**(`0x1401e6412`)와
    ///    같은 명령이다(begin==end 면 한 바퀴도 안 돌고 그대로 true 로 나간다). 키 부재도 true.
    ///    객체가 아닌 배열 원소는 `0x1401e641c` 에서 이터레이터 증가로 직행해 누산기 검사
    ///    (`0x1401e68e3`)를 아예 건너뛴다 — 그래서 결과에 영향을 못 준다.
    ///
    /// 누산은 전부 AND — 객체 안의 키끼리도, 배열 원소끼리도. OR 는 어디에도 없다
    /// (누산 6지점이 전건 `cmov`-to-zero: `0x1401e66e2`/`6725`/`6768`/`67a8`/`67c3`/`68ca`).
    ///
    /// **좌우가 비대칭이다** — 이게 마지막 함정이다.
    ///   · 우변(조건 값)이 string/bool/array/null 이면 조건을 **통째로 건너뛴다**
    ///     (`0x1401e65fe` `cmp eax, 7` + `jne 0x1401e6808` = 누산기 무변경 재적재).
    ///   · 좌변(콤보 값)이 같은 타입이면 건너뛰지 않고 **0 으로 읽힌다**
    ///     (`0x1401e6546` 의 `xor r14d, r14d` 가 끝까지 안 덮인다). 키 부재도 같은 자리로 온다.
    /// 즉 `{"combos": {"A": "1"}}` 의 좌변은 1 이 아니라 **0** 이다. `comboValue(_:)` 참조.
    public struct Condition: Equatable {
        public enum Op: Equatable {
            case eq          // 맨몸 값, 또는 미지/부재 op 의 폴백
            case ge, gt, le, lt
        }
        public let combo: String
        public let op: Op
        public let value: Int
        public init(combo: String, op: Op, value: Int) {
            self.combo = combo; self.op = op; self.value = value
        }
        public func holds(combos: [String: Int]) -> Bool {
            let lhs = combos[combo] ?? 0
            switch op {
            case .eq: return lhs == value
            case .ge: return lhs >= value
            case .gt: return lhs > value
            case .le: return lhs <= value
            case .lt: return lhs < value
            }
        }
    }

    /// X-⑪ 좌변 리더 — `conditions` 가 읽는 **콤보 값**의 타입 규약.
    ///
    /// 씬의 다른 정수 필드는 `lenientInt` 로 관대하게 읽는다(실물 씬이 `id`/`parent` 를 `"35"`
    /// 문자열로 싣는 사례가 있어서). **여기서는 그러면 안 된다.** 원본의 좌변 적재
    /// (`0x1401e6555`-`0x1401e65ac`)는 태그 1/2/3(int/uint/real)만 받고, 나머지는 `0x1401e6546`
    /// 의 `xor r14d, r14d` 를 그대로 남긴다 — 즉 **0** 이다. `"1"` 도, `true` 도 0 이다.
    ///
    /// 관대하게 읽으면 `{"combos": {"LIGHTING": "1"}}` 에서 우리만 조건이 켜진다.
    /// 이 맵은 오직 `conditions` 의 좌변으로만 쓰이므로 여기서 규약을 좁히는 게 안전하다.
    public static func comboValue(_ v: Any?) -> Int? {
        if isJSONBool(v) { return nil }          // 태그 5 — 좌변에서 0(= 키 부재와 동치)
        if let i = v as? Int { return i }        // 태그 1/2
        if let d = v as? Double { return safeInt(d) }   // 태그 3 — cvttsd2si(0 방향 절삭)
        return nil                               // 태그 0/4/6/7 → 0
    }

    /// `conditions` 한 벌. nil = 키 부재/비배열 → 항상 true.
    /// 바깥 배열의 원소끼리도, 안쪽 그룹의 조건끼리도 전부 AND 다.
    public typealias Conditions = [[Condition]]

    /// 조건 평가. nil·빈 배열·빈 그룹은 전부 true(fail-open).
    public static func evaluate(_ conditions: Conditions?, combos: [String: Int]) -> Bool {
        guard let conditions else { return true }
        for group in conditions {
            // 원소마다 누산기를 1 로 초기화한다(`0x1401e6426`). 빈 그룹 = true.
            if !group.allSatisfy({ $0.holds(combos: combos) }) { return false }
        }
        return true
    }

    public struct Bind: Equatable {
        public let name: String
        public let index: Int
        /// X-⑪: 이 bind 만의 조건. 거짓이면 **그 슬롯만 언바인드**되고 패스는 정상 실행된다.
        public let conditions: Conditions?
        public init(name: String, index: Int, conditions: Conditions? = nil) {
            self.name = name; self.index = index; self.conditions = conditions
        }
    }
    public struct Pass: Equatable {
        public let material: String?   // materials/....json (일반)
        public let shader: String?     // 직지정 스타일(passes[0].shader)
        public let target: String?     // fbo 이름 | nil(효과 출력)
        public let binds: [Bind]
        public let command: String?    // "copy" 등 셰이더 없는 명령 패스(실물 motionblur 의 buffer 지속)
        public let source: String?     // command=copy 의 원본 fbo 이름
        /// X-⑪: 거짓이면 이 패스를 통째로 건너뛴다. **단 씬 오버라이드 인덱스는 그대로 증가한다**
        /// (원본도 `0x1401e7a04` → `0x1401e814e` 로 인덱스만 올리고 continue 한다).
        public let conditions: Conditions?
        /// T09-D2: `passes[].compose` — **원본이 실제로 소비한다**(선행 스윕의 "안 읽는다" 는 틀렸다).
        ///
        /// 세 군데가 이 값을 쓴다:
        ///  ① 파스 `0x1401e7d96`–`0x1401e7dcf` — 타입 태그 **5(boolean)** 일 때만 읽는다
        ///     (`0x1401e7dac` `cmp byte [rax+8], 5`; 값 추출은 jsoncpp `asBool` `0x140086300`).
        ///     참이면 패스 플래그 워드(pass 레코드 +0x14)에 **비트 0x2** 를 세우고(`0x1401e7dc3`),
        ///     이펙트의 compose 개수(effect+0x140)를 하나 올린다(`0x1401e7dc7`).
        ///     **숫자 1 은 안 받는다** — `fbos[].unique` 와 같은 규약이라 `isJSONBool` 로 가른다.
        ///  ② 렌더 타깃 풀 산정 `0x1401e6300`–`0x1401e63a6` — 켜진 이펙트마다
        ///     `composeCount + 1` 을 누산하고(`0x1401e633f`·`0x1401e6345`) 캐시값(+0x320)과
        ///     다르면 재할당 가상호출(`0x1401e639b`)로 간다. 즉 **compose 패스 하나당 중간 렌더
        ///     타깃이 하나 더 필요하다**.
        ///  ③ 이펙트 체인 루프 `0x1401e9b8f`–`0x1401e9bf0` — 패스를 그린 직후 플래그의 비트 0x2 를
        ///     보고(`shr eax, 1` + `test al, 1`), 뒤에 패스가 더 남아 있으면 핑퐁 렌더 타깃 쌍
        ///     (`effect+0x2c8` 2칸)에서 **반대쪽으로 갈아탄다**. 꺼진 패스는 같은 타깃에 계속 그린다.
        ///
        /// 동봉 자산 도달은 2건 — `effects/refraction/effect.json` 과 그 preview 사본
        /// `effects/refraction/preview/effects/refract/effect.json`. 둘 다 `passes[0].compose = true`.
        public let compose: Bool
        public init(material: String?, shader: String?, target: String?, binds: [Bind],
                    command: String? = nil, source: String? = nil, conditions: Conditions? = nil,
                    compose: Bool = false) {
            self.material = material; self.shader = shader; self.target = target; self.binds = binds
            self.command = command; self.source = source; self.conditions = conditions
            self.compose = compose
        }
    }

    public struct FBO: Equatable {
        /// X-⑧(G-A5-06/G-B2-02): `fbos[].format` — 렌더 타깃 픽셀 포맷.
        ///
        /// 동봉 자산 실측으로 **fbo 선언 55/55 전건이 이 키를 갖고, 그중 27건이 rgba8 이 아니다**.
        /// 종전엔 키 자체를 파스하지 않아 전부 rgba8Unorm 으로 할당됐다 — `fluidsimulation` 의
        /// 속도장(rg1616f)·압력장(r16f)은 부호와 1.0 초과를 모두 잃어(unorm 은 [0,1] 클램프 +
        /// 8비트 양자화) **원리적으로 못 돈다**. glitter 타일 아틀라스(r8)는 채널 3개를 낭비한다.
        ///
        /// **표는 원본 `wallpaper64.exe` 에서 그대로 떴다.** `0x1401e53a0` 은 데이터 테이블이 아니라
        /// FNV-1a 해시맵을 magic-static 으로 만드는 **함수**이고(소멸자 루프 `mov ebx, 0x13` =
        /// 19회, 엔트리 stride 0x28), initializer_list 크기 760 = 19 × 40 으로 개수가 확정된다.
        /// 동봉 자산에 나오는 5종만 넣으면 워크샵 저작이 쓰는 나머지를 조용히 rgba8 로 떨어뜨리므로
        /// **19종 전부** 싣는다. enum 값은 원본 값 그대로다(3·5·16·22~27 은 문자열 이름이 없는
        /// 내부 depth/R32F 값이라 여기 없다).
        ///
        /// 이름으로 추론하면 틀리는 것이 둘 있다 — `rgb565` 와 `rgba8888s` 는 이름과 달리 실제
        /// DXGI 가 **R8G8B8A8_UNORM** 이다(B5G6R5 도 SNORM 도 아니다). 그래서 GPU 포맷 해석은
        /// 이름이 아니라 `0x1400d2a20` 의 28-way 점프 테이블(enum → DXGI 상수)에서 가져왔다.
        ///
        /// **sRGB 경로는 어디에도 없다** — 28개 arm 중 `_SRGB` DXGI 값(29/72/75/78/99)이 0건이다.
        /// 즉 `rgba8888` 은 `.rgba8Unorm_srgb` 가 아니라 선형 `.rgba8Unorm` 이다.
        ///
        /// 미지 문자열은 **에러가 아니라 rgba8888 폴백**이다(`0x1401e546a` 가 miss 시 0 반환).
        /// 여기서는 nil 로 두고 소비처가 같은 폴백을 한다.
        public enum Format: String, Equatable, CaseIterable {
            /// enum 0 · DXGI 28 R8G8B8A8_UNORM(선형). 동봉 자산 최다(28/55).
            case rgba8888
            /// enum 1 · DXGI 28 — 24비트 포맷이 없어 RGBA8 로 승격된다.
            case rgb888
            /// enum 8 · DXGI 49 R8G8_UNORM.
            case rg88
            /// enum 9 · DXGI 61 R8_UNORM. glitter 타일 마스크.
            case r8
            /// enum 2 · **DXGI 28** — 이름과 달리 B5G6R5(85)가 아니라 RGBA8 로 떨어진다.
            case rgb565
            /// enum 12 · DXGI 98 BC7_UNORM — 블록압축이라 렌더 타깃이 될 수 없다(소비처 주석 참조).
            case bc7
            /// enum 4 · DXGI 77 BC3_UNORM.
            case dxt5
            /// enum 6 · DXGI 74 BC2_UNORM.
            case dxt3
            /// enum 7 · DXGI 71 BC1_UNORM.
            case dxt1
            /// enum 14 · DXGI 10 R16G16B16A16_FLOAT.
            case rgba16161616f
            /// enum 15 · DXGI 10 — RGB→RGBA 승격.
            case rgb161616f
            /// enum 10 · DXGI 34 R16G16_FLOAT. 유체 속도장(부호 필수).
            case rg1616f
            /// enum 11 · DXGI 54 R16_FLOAT. 유체 압력/발산/컬.
            case r16f
            /// enum 17 · DXGI 11 R16G16B16A16_UNORM.
            case rgba16161616
            /// enum 18 · DXGI 11 — RGB→RGBA 승격.
            case rgb161616
            /// enum 19 · DXGI 13 R16G16B16A16_SNORM. **철자 주의: 대문자 S**(원본 .rdata 확인).
            case rgba16161616S = "rgba16161616S"
            /// enum 20 · DXGI 13 — RGB→RGBA 승격. **대문자 S**.
            case rgb161616S = "rgb161616S"
            /// enum 21 · **DXGI 28** — 이름과 달리 SNORM(31)이 아니라 UNORM 이다. **소문자 s**.
            case rgba8888s = "rgba8888s"
            /// enum 13 · DXGI 24 R10G10B10A2_UNORM.
            case rgba1010102

            /// 해시맵에 **없는** 두 문자열. 파서가 맵 조회 전에 `strcmp` 로 선처리해서
            /// 백버퍼 포맷으로 치환한다(`0x1401e7562` / `0x1401e759e`):
            ///   `rgba_backbuffer` → HDR ? enum 14(rgba16161616f) : enum 0(rgba8888)
            ///   `rgb_backbuffer`  → HDR ? enum 15(rgb161616f)   : enum 1(rgb888)
            /// 최종 DXGI 는 두 쌍이 각각 같다(10 / 28). 고정 포맷이 아니므로 별도 case 로 둔다 —
            /// 소비처가 씬의 HDR 여부로 해석한다.
            case rgbaBackbuffer = "rgba_backbuffer"
            case rgbBackbuffer = "rgb_backbuffer"
        }

        public let name: String
        /// 해상도 나눗수(4 = 1/4). **원본에서 `fit`/`width`/`height` 와 배타가 아니다** —
        /// 아래 `fittedBox` 주석의 W-FIT-4 참조(렌더타깃 ctor `0x1400d2c9b`–`0x1400d2ce4` 가
        /// `fit`/`width`/`height` 로 정해진 "full" 크기를 **그 뒤에** scale 로 나눈다).
        /// 동봉·설치본 전수에서 동시 선언은 0건이라 이 리포의 실측 도달은 없다.
        public let scale: Int
        /// X-①: `width` / `height` — dst 비례 대신 **절대 픽셀**. 실물 glitter `_rt_GlitterTiles`
        /// 256×256 한 건뿐(동봉+설치 4파일). nil 이면 그 축은 dst 크기가 그대로 들어간다.
        public let declaredWidth: Int?
        public let declaredHeight: Int?
        /// **W-FIT (2026-08-21 정정): `fit:N` 은 N×N 정사각이 아니다.**
        /// "긴 변을 N 에 맞추고 종횡비를 보존하며 확대하지 않는다" — 1920×1080 에서 `fit:256`
        /// 은 **256×144** 다. 근거 VA 와 전문은 `fittedBox(baseWidth:baseHeight:)` 주석.
        /// 이 값은 **봉투(envelope) 한 변**일 뿐 치수가 아니므로 **직접 쓰지 마라** —
        /// 치수는 반드시 `fittedBox` 로 풀어야 한다(dst 를 알아야 풀린다).
        public let fit: Int?
        /// 하위호환 표현. `fit` 만 있는 FBO 에서는 **정사각 봉투**를 돌려주므로
        /// 실제 치수가 아니다 — `fit != nil` 이면 `fittedBox` 를 먼저 보라.
        /// (종전 소비처·테스트가 이 이름으로 `width`/`height` 선언을 읽는다.)
        public var fixedWidth: Int? { declaredWidth ?? fit }
        public var fixedHeight: Int? { declaredHeight ?? fit }
        /// X-①: `uvs:"repeat"` — 텍셀 랩(실물 glitter 타일 아틀라스). 기본 false(=clamp, 기존 bind-slot 관례).
        public let uvsRepeat: Bool
        /// X-⑧: `format` — nil = 미지/미선언(소비처가 rgba8 기본값). 위 `Format` 주석 참조.
        public let format: Format?
        /// X-⑧(G-A5-05/G-B2-03): `unique:true` — 이 FBO 는 **프레임 풀에서 재활용하지 않고**
        /// 이펙트 인스턴스 전용으로 프레임을 넘어 유지된다. 동봉 자산 실측 19건 전건이 true 이고,
        /// `clear` 를 가진 12건은 **전건이 동시에 unique** 다(교집합이 우연이 아니다 — 프레임을
        /// 넘겨 누적하는 버퍼만 시작값을 정의할 필요가 있다).
        ///
        /// 왜 짝이어야 하나: `fluidsimulation` 의 속도/압력/염료는 `command:"swap"` 더블버퍼로
        /// **직전 프레임의 자기 출력을 읽는다**. 지금은 fbo 텍스처 배열이 프레임 로컬이라 swap 이
        /// 매 프레임 리셋되고, 풀 체크아웃 순서가 바뀌면 같은 이름이 다른 텍스처를 받는다.
        /// 즉 `unique` 없이는 시뮬레이션 상태가 프레임 간에 존재하지 않는다.
        public let unique: Bool
        /// X-⑧: `clear` — 생성 시 1회 채울 RGBA. 동봉 자산은 전건 `"0 0 0 0"`(공백 구분 4수).
        /// nil = 미선언. **매 프레임이 아니라 생성 1회**인 이유는 소비처 주석 참조.
        public let clearColor: SIMD4<Float>?
        /// X-⑪: 거짓이면 이 FBO 를 **아예 만들지 않는다**. 참조는 전부 이름 기반이라 벡터가 압축돼도
        /// 어긋나지 않는다(실물 `fluidsimulation` 의 `_rt_SmokeNormal` 이 `LIGHTING==1` 조건부이고,
        /// 그것을 쓰는 패스·바인드가 **같은 조건**이라 함께 사라진다).
        public let conditions: Conditions?
        public init(name: String, scale: Int, declaredWidth: Int? = nil, declaredHeight: Int? = nil,
                    fit: Int? = nil,
                    uvsRepeat: Bool = false, format: Format? = nil, unique: Bool = false,
                    clearColor: SIMD4<Float>? = nil, conditions: Conditions? = nil) {
            self.name = name; self.scale = scale
            self.declaredWidth = declaredWidth; self.declaredHeight = declaredHeight
            self.fit = fit; self.uvsRepeat = uvsRepeat
            self.format = format; self.unique = unique; self.clearColor = clearColor
            self.conditions = conditions
        }

        /// **W-FIT 정본 — `fit` 이 만드는 실제 텍스처 치수.** `fit` 미선언이면 `nil` 을 돌려
        /// 소비처가 **종전 경로**(`fixedWidth ?? dst/scale`)를 그대로 타게 한다. 무회귀가 목적이다.
        ///
        /// 원본 전문(함수 `0x1401ea500`–`0x1401ebbb6`, `.pdata` 조각 둘이 인접해 한 몸이다.
        /// FBO 루프는 `0x1401eb280` 부터, 크기 계산은 `0x1401eb2cc`–`0x1401eb381`):
        ///
        /// ```
        /// W0 = max(4, dstW); H0 = max(4, dstH)              # 0x1401ea5e4 · 0x1401ea606 (cmovg)
        /// W  = (width_u16  <= 0x1000) ? width_u16  : W0     # 0x1401eb2cc–0x1401eb2e3
        /// H  = (height_u16 <= 0x1000) ? height_u16 : H0     # 0x1401eb2d7–0x1401eb2f4
        /// if (fit_u16 <= 0x1000) {                          # 0x1401eb2f8 cmp ax,0x1000 / ja
        ///     if (W >= H) {                                 # 0x1401eb30c cmp r9d,ecx / jb  ← 긴 변이 major
        ///         W' = min(fit, W)                          # 0x1401eb311 cmp / 0x1401eb316 cmova (확대 금지)
        ///         H' = (int)((float)H / (float)W * (float)W')   # 0x1401eb31e–0x1401eb33b
        ///     } else {
        ///         H' = min(fit, H)                          # 0x1401eb349 cmp / 0x1401eb34c cmova
        ///         W' = (int)((float)W / (float)H * (float)H')   # 0x1401eb353–0x1401eb372
        ///     }
        /// } else { W' = W; H' = H; }                        # 0x1401eb37d
        /// tex = (max(2, W'/scale), max(2, H'/scale))        # ctor 0x1400d2c9b–0x1400d2ce4
        /// ```
        ///
        /// 확정한 다섯 가지(과제 W-FIT-1..5):
        ///
        /// * **W-FIT-1 반올림** — 파생되는 짧은 변만 부동소수를 거치고 `cvttss2si`(`0x1401eb33b` ·
        ///   `0x1401eb372`)로 **0 방향 절단**한다. 긴 변은 정수 `min` 이라 오차가 없다.
        ///   하한은 이 산술에 없고 **렌더타깃 생성자**가 축마다 `max(2, ·)` 로 건다
        ///   (`0x1400d2cac`/`0x1400d2ccc`, 리사이즈 경로 `0x140161f83`–`0x140161f9e` 도 같은 2).
        ///   float32 를 그대로 흉내 낸다 — `H*W'/W` 를 정수로 계산하면 비율이 float32 로
        ///   반올림되며 정수 경계 아래로 떨어지는 경우를 재현하지 못한다.
        /// * **W-FIT-2 major** — **긴 변**이다(너비 고정이 아니다). `W == H` 는 너비 분기로 가지만
        ///   두 분기의 답이 같다. `width`/`height` 가 선언돼 있으면 그 값이 **비교 대상 자체**를
        ///   갈아치우므로(`0x1401eb2e3`/`0x1401eb2f4`) major 판정도 그 값들로 한다.
        /// * **W-FIT-3 확대 금지** — 명시 클램프(`cmova`)는 **major 한쪽에만** 있다. 짧은 변은
        ///   `minor × major'/major` 이고 `major' <= major` 이므로 결과적으로 양쪽 다 원본을
        ///   넘지 않는다(수학적 귀결이지 별도 클램프가 아니다).
        /// * **W-FIT-4 `scale` 과의 관계 — 경쟁이 아니라 합성이다.** 크기 계산은 `scale` 을 전혀
        ///   보지 않고, `scale` 바이트는 렌더타깃 생성 호출의 **4번째 인자로 따로** 실린다
        ///   (`0x1401eb97d` 로드 → `0x1401eb9d4` 적재 → `0x1401eba0b` 호출). 생성자가 그때
        ///   "full" 크기를 `+0x18/+0x1a` 에 그대로 보관하고 텍스처 치수를 `max(2, full/scale)`
        ///   로 만든다(`0x1400d2c9b`–`0x1400d2ce4`). 즉 `fit:256, scale:2` = 긴 변 128.
        ///   동봉+설치본 FBO 선언 112건(동봉 55 + 설치본 57) 중 `fit`+`scale` 동시 선언은 **0건**,
        ///   `width|height`+`scale` 도 **0건** — 실측 도달이 없다.
        /// * **W-FIT-5 입력** — 화면 해상도가 아니라 **이 이펙트의 dst 서피스 크기**다. 같은
        ///   `(W0,H0)` 가 이펙트 자신의 핑퐁 렌더타깃(`this+0x2c8`/`+0x2d0`)을 만드는 데 쓰이고
        ///   (`0x1401eb0dd` → `0x1401eb0e5`, scale 인자 1), 그 값은 이펙트 객체의 가상 호출
        ///   `[vtable+0x128]`(`0x1401ea5b1`)이 채운다. Waple 의 대응값은 `effW/effH`
        ///   (레이어 크기, `isFrameBuffer` 면 프로젝션 크기)와 프레임 시점의 `dst` 크기다.
        ///
        /// **의도적 편차 하나** — 하한을 2 가 아니라 1 로 둔다. 2 로 올리면 `fit` 미선언 FBO 의
        /// 종전 `max(1, dst/scale)` 까지 같이 움직여야 하는데(무회귀 규약 위반), 두 값이 갈리는
        /// 구간은 "한 축이 1 이하로 떨어지는 dst" 뿐이고 동봉·설치 코퍼스 도달이 0이다.
        /// 0/음수가 Metal 텍스처 생성에 가지 않는다는 목적은 1 로도 똑같이 달성된다.
        ///
        /// **2026-08-21 도달 재확인(전수).** 갈리는 필요충분조건은 *그 축의 결과가 0 또는 1* 이다.
        ///   · 긴 변은 `min(fit, major)` 이라 `fit == 1` 이라야 갈리는데 코퍼스 `fit` 값은
        ///     256(`fluidsimulation` 6장) · 512(`cursorripple` 2장) 두 가지뿐이다.
        ///   · 짧은 변은 `trunc(minor/major × min(fit, major)) ≤ 1`, 즉 종횡비가 **`fit/2 : 1`
        ///     보다 극단**일 때다 — fit 256 이면 128:1, fit 512 면 256:1.
        ///   · `fit` FBO 는 코퍼스 전건이 `scale` 미선언(=1)이라(FBO 선언 112건 중 `fit` 28건,
        ///     `fit`+`scale` 동시 0건) 나눗셈이 다시 1 이하로 끌어내리는 경로도 없다.
        ///   · 그 두 이펙트를 **쓰는 자리**는 씬 전수(`objects[].effects[].file`) **4건**뿐이고
        ///     (동봉 `effects/{fluidsimulation,cursorripple}/preview/scene.json` + 설치본 사본 2)
        ///     전부 `size:"256 256"` · `scale:"1 1 1"` · `orthogonalprojection 256×256` 의
        ///     **정사각** 레이어라 짧은 변 = 긴 변 = 256 이다. 하한까지 **128배** 여유다.
        ///   · `fit` 미선언 갈래(`max(1, dst/scale)`, `SceneRendererFrameEncoder`)도 같이 쟀다 —
        ///     `scale > 1` 인 FBO 를 쓰는 씬 자리 12건의 최악값이 `min(축)/scale = 64` 다
        ///     (`blur`/`cursorripple` scale 4 · 256×256 레이어).
        /// 잠금은 `EffectFboFitTests.testLowerBoundDeviationBoundaryIsTheDerivedShortSide` 와
        /// `…HasNoCorpusReach` 두 개다.
        public func fittedBox(baseWidth: Int, baseHeight: Int) -> (width: Int, height: Int)? {
            guard let fit = fit else { return nil }
            return Self.fittedBox(fit: fit, declaredWidth: declaredWidth, declaredHeight: declaredHeight,
                                  scale: scale, baseWidth: baseWidth, baseHeight: baseHeight)
        }

        /// `fittedBox` 의 순수 계산부 — 렌더 계층의 `FBOSpec`(매니페스트 타입을 들지 않는다)이
        /// 같은 산술을 쓰도록 정적으로 뺀다. 규약 전문은 위 인스턴스 메서드 주석.
        public static func fittedBox(fit: Int, declaredWidth: Int?, declaredHeight: Int?,
                                     scale: Int, baseWidth: Int, baseHeight: Int)
            -> (width: Int, height: Int) {
            // 원본은 dst 를 4 로 하한 클램프한다(`0x1401ea5e4`/`0x1401ea606`). 상한은 원본에 없지만
            // 여기 base 는 레이어/프로젝션 크기라 신뢰 경계 밖 값이 올 수 있어 u16 폭으로 접는다 —
            // 원본이 `width`/`height`/`fit` 을 u16 필드에 담는 것과 같은 폭이다(`0x1401e7804` 등).
            let w0 = Swift.max(4, Swift.min(baseWidth, 65535))
            let h0 = Swift.max(4, Swift.min(baseHeight, 65535))
            // W-FIT-2: `width`/`height` 선언이 있으면 fit 의 **입력**이 그것으로 바뀐다.
            let w = Swift.max(1, declaredWidth ?? w0)
            let h = Swift.max(1, declaredHeight ?? h0)
            let box = Swift.max(1, fit)
            let major: Int, minor: Int, fittedMajor: Int
            let widthIsMajor = w >= h                    // 0x1401eb30c (jb → 반대 분기)
            if widthIsMajor { major = w; minor = h } else { major = h; minor = w }
            fittedMajor = Swift.min(box, major)          // 0x1401eb316 / 0x1401eb34c — 확대 금지
            let fittedMinor = ratioTruncated(minor: minor, major: major, fittedMajor: fittedMajor)
            let fullW = widthIsMajor ? fittedMajor : fittedMinor
            let fullH = widthIsMajor ? fittedMinor : fittedMajor
            // W-FIT-4: scale 은 **그 뒤에** 나눈다(원본 하한 2, 여기는 위 주석의 의도적 편차로 1).
            let s = Swift.max(1, scale)
            return (Swift.max(1, fullW / s), Swift.max(1, fullH / s))
        }

        /// `(float)minor / (float)major * (float)fittedMajor` 를 float32 로 계산하고 0 방향 절단.
        /// 원본 `cvtsi2ss`/`divss`/`mulss`/`cvttss2si`(`0x1401eb31e`–`0x1401eb33b`)와 같은 순서다.
        /// `Int(exactly:)` 로 받는 이유: 입력이 effect.json(신뢰 경계 밖)에서 오므로 `Int(Float)`
        /// 의 트랩을 원리적으로 배제한다. `major >= 1` 이라 0 나눗셈은 없고 결과는 `[0, minor]` 다.
        private static func ratioTruncated(minor: Int, major: Int, fittedMajor: Int) -> Int {
            let v = (Float(minor) / Float(major) * Float(fittedMajor)).rounded(.towardZero)
            return Int(exactly: v) ?? 0
        }
    }

    /// T09-D1: 최상위 `functions` — **원본이 실제로 소비한다**(선행 스윕의 "안 읽는다" 는 틀렸다).
    ///
    /// 정체는 **스크립트 API `executeMaterialFunction(name)` 의 대상 테이블**이다. 등록 지점이
    /// `0x1401f0156`(명령 이름 문자열 `"executeMaterialFunction"`, 길이 0x17) + `0x1401f016c`
    /// (네이티브 구현 포인터 `0x1401ee3a0`), 인자 1개(`0x1401f0173` 의 `mov [rbx+0x70], 1`).
    /// 동봉 `fluidsimulation` 이 정의하는 `clearVelocity`/`clearDye` 는 **바이너리에 문자열이
    /// 아예 없다** — 저작자가 지은 이름이고, 스크립트가 문자열로 부른다.
    ///
    /// 파서 `0x1401e8248`–`0x1401e88a1` 실측 규약:
    ///   · 루트 문서(`[rbp+0xc0]` — `fbos` `0x1401e735c` · `passes` `0x1401e7996` 와 같은 객체)에서
    ///     `functions` 를 찾고(`0x1401e824f`) jsoncpp `getMemberNames`(`0x1401e8272`)로 키를 훑는다.
    ///     jsoncpp 객체는 `std::map` 이라 **키가 사전순**으로 나온다 — 그래서 우리도 이름순 정렬한다.
    ///     키가 없으면 태그 0(null) 이 돌아오고 `getMemberNames` 는 빈 벡터다(`0x14008837e`).
    ///   · 값이 타입 태그 **7(object)** 이 아니면 그 항목을 버린다(`0x1401e83f9`).
    ///   · `action` 이 타입 태그 **4(string)** 이고(`0x1401e842d`) 길이가 정확히 5(`0x1401e8454`),
    ///     `memcmp("clear") == 0`(`0x1401e845a`) 이어야 한다. 아니면 항목째 버린다 —
    ///     **원본이 아는 action 은 `clear` 하나뿐이다.**
    ///   · `fbos` 가 타입 태그 **6(array)** 이 아니면 항목째 버린다(`0x1401e84df`).
    ///   · 배열 원소는 문자열(태그 4)만 본다(`0x1401e8593`). 이펙트가 **선언한 fbo 목록**에서
    ///     이름 완전 일치로 선형 탐색해(`0x1401e8630`–`0x1401e867d`, stride 0x50) 찾은
    ///     **인덱스**를 담는다. 못 찾은 이름은 그냥 빠진다. `functions` 파스가 `fbos` 파스보다
    ///     **뒤**라(0x1401e735c < 0x1401e8248) 인덱스는 파스가 끝난 목록 기준이다 —
    ///     name/format 없어 버려진 선언(X-⑧)은 애초에 목록에 없다.
    ///   · 인덱스가 하나도 안 남으면 그 항목을 **push 하지 않는다**(`0x1401e884a` `je 0x1401e88a1`).
    ///     레코드는 stride 0x40 = { int action; std::string name; std::vector<int> fboIndices; }.
    ///
    /// 소비 `0x1401ee3a0`–`0x1401ee51b`: 이름으로 항목을 선형 탐색해 **첫 일치**를 쓰고
    /// (`0x1401ee3d0`–`0x1401ee40a`), 인덱스마다 그 FBO 를 렌더 타깃으로 밀고(`0x1401ee468`
    /// vtbl+0x48), fbo 레코드의 float 4개(+0x14·+0x18·+0x1c·+0x20 = `fbos[].clear` 파스 결과)를
    /// 실어(`0x1401ee472`–`0x1401ee491`) 클리어색 설정(`0x1401ee49a` vtbl+0x118) → 클리어
    /// (`0x1401ee4b6` vtbl+0x120, `dl=1`/`r8d=0` = 색만·깊이 없음) 한 뒤 타깃을 되돌린다
    /// (`0x1401ee4bc`–`0x1401ee4e7`).
    ///
    /// 동봉 자산 도달은 1건 — `effects/fluidsimulation/effect.json`.
    public struct Function: Equatable {
        /// 원본이 아는 action 은 `clear` 하나뿐이다(`0x1401e845a` 의 `memcmp("clear")`, 길이 5 고정).
        public enum Action: String, Equatable, CaseIterable {
            case clear
        }
        public let name: String
        public let action: Action
        /// `EffectManifest.fbos` 의 인덱스. 원본과 같게 **파스 시점에** 이름→인덱스로 푼다.
        /// 절대 비지 않는다 — 비면 항목 자체가 안 생긴다(`0x1401e884a`).
        public let fboIndices: [Int]
        public init(name: String, action: Action = .clear, fboIndices: [Int]) {
            self.name = name; self.action = action; self.fboIndices = fboIndices
        }
    }

    public let passes: [Pass]
    public let fbos: [FBO]
    /// G-B4-08: 이 이펙트의 **자산 basename**. 디렉터리명과 다를 수 있다 — 동봉 WEAssets 최상위
    /// effect.json 46개가 **전건** 이 키를 갖고, 그중 7개가 디렉터리명과 다르다:
    /// `_empty→empty` · `blurprecise→blur_precise` · `blurradial→blur_radial` ·
    /// `chromaticaberration→chromatic_aberration` · `depthparallax→iris` · `refraction→refract` ·
    /// `watercaustics→caustics`. 머티리얼 JSON 을 못 읽어 관례 셰이더명으로 폴백할 때
    /// `effects/<디렉터리명>` 을 쓰면 이 7종은 존재하지 않는 경로를 찾게 된다.
    public let replacementKey: String?

    /// T09-D1: 이름으로 부르는 FBO 클리어 함수들. 키 이름순(jsoncpp `std::map` 순서와 같다).
    public let functions: [Function]

    public init(passes: [Pass], fbos: [FBO], replacementKey: String? = nil,
                functions: [Function] = []) {
        self.passes = passes; self.fbos = fbos; self.replacementKey = replacementKey
        self.functions = functions
    }

    /// T09-D1: 스크립트 `executeMaterialFunction(name)` 이 찾는 그 조회다.
    /// 원본 소비처(`0x1401ee3d0`–`0x1401ee40a`)가 선형 탐색으로 **첫 일치**를 쓴다.
    public func function(named name: String) -> Function? {
        functions.first { $0.name == name }
    }

    /// WE 의 JSON 파서는 관용이다 — 자기 자산이 그 관용에 의존한다. 동봉 WEAssets 실측
    /// (모집단 = `WEAssets/effects/**` 의 effect.json **122개**. WEAssets 전수는 128 로
    /// `presets/` 4 · `scenes/` 2 가 더 있다 — 이 절의 도수는 전부 122 기준이다):
    /// effect.json 122개 중 **27개가 RFC 엄격 파스에 실패**한다(최상위 `fluidsimulation` 1개는
    /// `dependencies` 배열의 트레일링 콤마, 나머지 26개 preview 는 `//` 줄 주석). 27개 전부
    /// 아래 전처리로 복구된다.
    ///
    /// 그래서 **엄격 파스를 먼저 시도하고 실패했을 때만** 이 전처리를 쓴다 — 정상 자산은 종전
    /// 경로 그대로라 무회귀이고, 관용은 딱 두 가지(줄 주석 · 트레일링 콤마)로 제한한다.
    /// 스캐너는 문자열 리터럴 안을 절대 건드리지 않는다(이스케이프 처리 포함) — `{"a":"x,]"}`
    /// 같은 값이 깨지면 안 된다.
    ///
    /// **[2026-08-21] 위 "27개 전부 복구된다" 가 한동안 거짓이었다 — 지금은 고쳤다.**
    /// 동봉 effect.json 122개는 **전건 CRLF** 인데, `AssetJSON.relaxed` 의 줄 주석 스키퍼가
    /// `while text[i] != "\n"` 으로 돌고 있었다. Swift `String` 은 그래핌 클러스터 단위로
    /// 순회하고 `"\r\n"` 은 **한 개의 `Character`** 라 `"\n"` 과 같지 않다 — 그래서 첫 `//` 를
    /// 만나면 **파일 끝까지** 지워 버렸다. 트레일링 콤마 스키퍼의 공백 집합도 같은 이유로
    /// `"\r\n"` 을 못 건너뛰었다. 실측: 원시 바이트로 **25/122 파스 nil**(macOS 는 트레일링
    /// 콤마까지 엄격해 26/122). `isNewline` 으로 고친 뒤 **0/122**.
    ///
    /// 이 회귀는 `EffectManifestTests.testEveryBundledEffectManifestParsesAndFunctionComposeReachIsPinned`
    /// 과 `AssetJSONLenientTests` 의 CRLF 케이스가 고정한다.
    static func relaxedJSON(_ data: Data) -> Data? { AssetJSON.relaxed(data) }

    public static func parse(_ data: Data) -> EffectManifest? {
        if let strict = parseStrict(data) { return strict }
        guard let relaxed = relaxedJSON(data) else { return nil }
        return parseStrict(relaxed)
    }

    private static func parseStrict(_ data: Data) -> EffectManifest? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawAny = obj["passes"] as? [Any], !rawAny.isEmpty else { return nil }
        // `as? [[String: Any]]` 로 받으면 **원소 하나가 객체가 아닐 때 배열 전체 캐스트가 실패**해
        // 매니페스트가 통째로 nil 이 된다 → 관례 1패스 폴백 → 대개 셰이더 부재 → 이펙트 소멸.
        // 원본은 그 원소의 멤버가 null 일 뿐 이펙트를 버리지 않으므로, 비객체는 빈 패스로 **자리를
        // 보존**한다(씬 오버라이드가 원본 배열 인덱스 정렬이라 자리 보존이 곧 정합이다).
        let rawPasses: [[String: Any]] = rawAny.map { ($0 as? [String: Any]) ?? [:] }
        var passes: [Pass] = []
        for p in rawPasses {
            var binds: [Bind] = []
            // r3-O11: 바로 위 `rawPasses` 와 **같은 원소별 폴백**이다. 종전 `as? [[String: Any]]` 는
            // 배열 전체 캐스트라 원소 하나가 비객체면 그 패스의 bind 가 전량 소실됐다(passes 만
            // 고쳐지고 bind/fbos 는 남아 있던 비대칭).
            for raw in (p["bind"] as? [Any]) ?? [] {
                guard let b = raw as? [String: Any],
                      let name = b["name"] as? String, let idx = safeInt(b["index"]), idx >= 0 else { continue }
                binds.append(Bind(name: name, index: idx, conditions: parseConditions(b["conditions"])))
            }
            passes.append(Pass(material: p["material"] as? String,
                               shader: p["shader"] as? String,
                               target: p["target"] as? String,
                               binds: binds,
                               command: p["command"] as? String,
                               source: p["source"] as? String,
                               conditions: parseConditions(p["conditions"]),
                               // T09-D2: 원본은 타입 태그 5(boolean)만 받는다(`0x1401e7dac`).
                               // `"compose": 1` 은 켜지면 안 된다 — `fbos[].unique` 와 같은 이유로
                               // Swift 의 NSNumber 동적 캐스트를 `isJSONBool` 로 먼저 가른다.
                               compose: isJSONBool(p["compose"]) && (p["compose"] as? Bool) == true))
        }
        var fbos: [FBO] = []
        // X-①-sweep: **개수**도 상한을 둔다. 종전엔 치수(8192)만 클램프했는데, 소비처
        // (`SceneRendererFrameEncoder.swift:1958-1963`, `:301-315`)가 선언된 FBO 를 **사용 여부와
        // 무관하게 매 프레임 체크아웃**하므로 개수만으로 GPU 메모리와 프레임 시간을 밀어낼 수 있다.
        // 64 인 이유(r4-20 — 모집단 라벨): **동봉 코퍼스** `Sources/WapleRender/Resources/WEAssets`
        // 의 effect.json **128개 전수**(= `effects/` 122 + `presets/` 4 + `scenes/` 2)를 2026-09-01
        // 에 다시 세면 `fbos` 개수 분포가 {0:105, 1:5, 2:16, 9:2} 이고 최대는 **9**
        // (`effects/fluidsimulation`)다. 즉 정상 저작은 64 근처에도 안 온다. (종전 이 줄의 "101개"
        // 는 라벨 없는 부분집합이었고 지금 트리의 어떤 모집단과도 맞지 않는다 — 같은 파일이
        // 다른 자리에서 쓰는 122 는 `effects/` 서브트리, 파일 헤더 표의 128 은 WEAssets 전수다.)
        let maxFBOs = 64
        // r3-O11: bind 와 같은 이유로 원소별 폴백.
        for raw in (obj["fbos"] as? [Any]) ?? [] {
            guard let f = raw as? [String: Any] else { continue }
            guard fbos.count < maxFBOs else { break }
            // X-⑧: 원본은 `name` **또는** `format` 이 없거나 문자열이 아니면 그 FBO 선언을 통째로
            // 버린다(`0x1401e7440`/`0x1401e744f` → `jne 0x1401e7964`, 벡터에 push 안 함).
            // 종전엔 name 만 봤다. 동봉 자산은 55/55 가 둘 다 가지므로 실측 도달은 0 이고,
            // 이름 키로 인덱스를 만드는 소비처는 빠진 선언을 미지 이름 폴백(G-A5-04)으로
            // 흡수한다 — 즉 원본과 같아지면서 이펙트가 통째로 죽지는 않는다.
            guard let name = f["name"] as? String, f["format"] is String else { continue }
            let scale = safeInt(f["scale"]) ?? 1
            // X-①: 8192 클램프 — 신뢰불가 effect.json 정수가 makeTexture 에 그대로 흘러가 과대 할당/
            // 실패를 유발하지 않도록(B1 8192 가드와 동일 원칙). 0 이하는 무시(scale 기반 폴백 유지).
            func clampedFixed(_ v: Any?) -> Int? {
                guard let n = safeInt(v), n > 0 else { return nil }
                return Swift.min(n, 8192)
            }
            // W-FIT: `fit` 은 **정사각 치수가 아니라 봉투 한 변**이라 파스 시점에 치수로 접을 수
            // 없다(dst 를 알아야 풀린다) — 세 값을 그대로 들고 `FBO.fittedBox` 가 소비처에서 푼다.
            // 원본의 8192 대신 4096 이 아닌 이유: 원본은 값을 u16 에 담은 뒤(`0x1401e7804`) 쓰는
            // 자리에서 `> 0x1000` 이면 **미선언 취급**한다(`0x1401eb301`). 즉 `fit:5000` 은 원본에서
            // 무시되고 여기서는 5000 으로 살아남는다 — 다만 `fittedBox` 가 `min(fit, 긴 변)` 을
            // 거치므로 4096 을 넘는 값은 사실상 "dst 그대로" 로 접혀 관측 가능한 차이가 없다
            // (4096 을 넘는 긴 변에서만 갈리고, 그 구간은 8192 클램프가 다시 덮는다).
            let declaredW = clampedFixed(f["width"])
            let declaredH = clampedFixed(f["height"])
            let fitBox = clampedFixed(f["fit"])
            let uvsRepeat = (f["uvs"] as? String) == "repeat"
            // X-⑧: 문자열은 있으나 **표에 없는** 값이면 nil — 원본이 해시맵 miss 에서 0(rgba8888)을
            // 돌려주는 것(`0x1401e546a`)과 같게, 소비처가 rgba8 로 폴백한다.
            let format = (f["format"] as? String).flatMap { FBO.Format(rawValue: $0) }
            // 원본은 타입 태그 5(boolean)만 받는다. Swift 의 NSNumber 동적 캐스트는 **0/1 인 숫자도
            // Bool 로 성공**시키므로(`"unique":1` → true) 그대로 두면 원본보다 관대해진다.
            // `unique` 는 프레임 간 지속 경로를 켜는 스위치라, 잘못 켜지면 워크샵 이펙트에
            // 원본에 없는 잔상이 쌓인다.
            let unique = isJSONBool(f["unique"]) && ((f["unique"] as? Bool) == true)
            fbos.append(FBO(name: name, scale: Swift.max(1, scale),
                            declaredWidth: declaredW, declaredHeight: declaredH, fit: fitBox,
                            uvsRepeat: uvsRepeat, format: format, unique: unique,
                            clearColor: parseClearColor(f["clear"]),
                            conditions: parseConditions(f["conditions"])))
        }
        let replacementKey = (obj["replacementkey"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        // T09-D1: 원본도 `fbos` 파스가 끝난 **뒤**에 이름→인덱스를 푼다(`0x1401e735c` < `0x1401e8248`).
        let functions = parseFunctions(obj["functions"], fbos: fbos)
        return EffectManifest(passes: passes, fbos: fbos, replacementKey: replacementKey,
                              functions: functions)
    }

    /// T09-D1: 최상위 `functions` 파스. 규약은 `Function` 의 주석에 VA 와 함께 적어 뒀다.
    /// 요약하면 — 객체가 아니면 빈 목록, 항목은 `{action:"clear", fbos:[선언된 fbo 이름…]}` 만,
    /// 이름은 파스된 `fbos` 인덱스로 풀고 하나도 못 풀면 항목째 버린다.
    static func parseFunctions(_ v: Any?, fbos: [FBO]) -> [Function] {
        guard let obj = v as? [String: Any] else { return [] }
        var out: [Function] = []
        // jsoncpp 객체는 `std::map` 이라 `getMemberNames`(`0x1401e8272`)가 **키 사전순**을 준다.
        // Swift 사전은 순서가 없으니 여기서 정렬해 원본 순서와 결정성을 둘 다 맞춘다.
        for name in obj.keys.sorted() {
            // 태그 7(object) 아니면 드롭(`0x1401e83f9`).
            guard let spec = obj[name] as? [String: Any] else { continue }
            // 태그 4(string) + 정확히 "clear" 아니면 드롭(`0x1401e842d`·`0x1401e8454`·`0x1401e845a`).
            guard let raw = spec["action"] as? String, let action = Function.Action(rawValue: raw)
            else { continue }
            // 태그 6(array) 아니면 드롭(`0x1401e84df`).
            guard let names = spec["fbos"] as? [Any] else { continue }
            var indices: [Int] = []
            for element in names {
                // 원소가 문자열(태그 4)이 아니면 그 원소만 건너뛴다(`0x1401e8593`).
                guard let fboName = element as? String else { continue }
                // 이름 완전 일치 선형 탐색, 첫 일치(`0x1401e8630`–`0x1401e867d`).
                // 못 찾으면 아무것도 안 넣는다 — 원본도 인덱스를 push 하지 않는다.
                guard let idx = fbos.firstIndex(where: { $0.name == fboName }) else { continue }
                indices.append(idx)
            }
            // 인덱스가 비면 항목 자체를 안 만든다(`0x1401e884a` `je 0x1401e88a1`).
            guard !indices.isEmpty else { continue }
            out.append(Function(name: name, action: action, fboIndices: indices))
        }
        return out
    }

    /// X-⑪: `conditions` 파스. 배열이 아니면 **nil**(= 항상 true, fail-open).
    ///
    /// 값 타입별 처리가 원본과 같아야 한다:
    ///   · int/uint  → 등호 비교
    ///   · real      → **0 방향 절삭 후** 32비트 정수 등호(`cvttsd2si`)
    ///   · object    → `{op, value}`. `value` 가 int/uint/real 이 아니면 **0**,
    ///                 `op` 가 문자열이 아니거나 길이 2 가 아니거나 4종에 없으면 **등호 폴백**
    ///   · 그 외(string/bool/array/null) → **조건 자체를 무시**(누산에 영향 없음)
    ///
    /// 마지막 항목이 중요하다 — "무시" 는 false 가 아니다. 그래서 조건을 만들지 않고 건너뛴다.
    static func parseConditions(_ v: Any?) -> Conditions? {
        guard let array = v as? [Any] else { return nil }
        var groups: Conditions = []
        for element in array {
            // 객체가 아닌 원소는 빈 그룹 — 결과에 영향을 주지 않는다(원본도 acc 를 안 건드린다).
            guard let obj = element as? [String: Any] else { groups.append([]); continue }
            var group: [Condition] = []
            for (combo, spec) in obj {
                if let c = parseCondition(combo: combo, spec: spec) { group.append(c) }
            }
            groups.append(group)
        }
        return groups
    }

    private static func parseCondition(combo: String, spec: Any) -> Condition? {
        // bool 이 숫자로 브리징되는 것을 먼저 막는다 — 원본은 타입 태그로 갈라 bool 을 무시한다.
        if isJSONBool(spec) { return nil }
        if let i = spec as? Int { return Condition(combo: combo, op: .eq, value: i) }
        if let d = spec as? Double, let i = safeInt(d) { return Condition(combo: combo, op: .eq, value: i) }
        guard let obj = spec as? [String: Any] else { return nil }   // string/bool/array/null → 무시
        // `value` 가 숫자가 아니면 0. **원본은 `asInt()` 를 부르지 않는다** — 호출 직전에 타입 태그를
        // 인라인으로 걸러(`0x1401e6682`-`0x1401e668e`: `dec eax` + `cmp eax, 2` + `jbe`) 1/2/3 만
        // `asInt`(`0x140085ee0`)로 보내고 나머지는 `xor r12d, r12d` 로 0 을 쓴다. 이 구분이 실제
        // 동작을 가른다: 진짜 `asInt` 는 bool 에 **1** 을 돌려주고(`0x140085f03`) string/array/object
        // 에는 `int3` 로 죽는다(`0x140085f32`). 그래서 "asInt 가 0 을 준다" 로 옮겨 적으면
        // `{"op":"ge","value":true}` 가 0 이 아니라 1 이 되어 갈린다.
        var rhs = 0
        let rawValue = obj["value"]
        if !isJSONBool(rawValue) {
            if let i = rawValue as? Int { rhs = i }
            else if let d = rawValue as? Double, let i = safeInt(d) { rhs = i }
        }
        var op: Condition.Op = .eq
        if let raw = obj["op"] as? String, raw.utf8.count == 2 {
            switch raw {
            case "ge": op = .ge
            case "gt": op = .gt
            case "le": op = .le
            case "lt": op = .lt
            default: op = .eq        // 길이는 2 인데 아는 연산자가 아니면 등호 폴백
            }
        }
        return Condition(combo: combo, op: op, value: rhs)
    }

    /// X-⑧: `clear` 값 파스 — **원본 파서(`0x1401e7629`-`0x1401e7777`) 그대로**.
    ///
    /// 처음엔 "WE 의 색 표기는 성분 수가 흔들린다"고 보고 1/3/4 성분을 다 받게 썼는데,
    /// 원본을 뜯어 보니 그렇지 않았다. 실제 동작은 셋 다 종전 추측과 다르다:
    ///
    /// ① **구분자는 스페이스(0x20)뿐이다.** 파서가 `cmp byte ptr [rdi], 0x20` 만 반복한다 —
    ///    콤마도 탭도 구분자가 아니다. 종전 구현은 콤마·탭까지 받아 원본보다 관대했다.
    /// ② **정확히 4성분이어야 한다.** 성분이 모자라면 파싱이 `0x1401e777b` 로 빠져
    ///    **clear 비트 자체가 서지 않는다**(즉 `"0 0"` 은 클리어 안 함). 종전 구현은 3성분을
    ///    RGB+알파1 로, 1성분을 그레이스케일로 받아들여 원본에 없는 동작을 지어냈다.
    /// ③ **빈 문자열은 (0,0,0,0) 으로 클리어한다.** `0x1401e7641` 이 4성분을 전부 0 으로 채우고
    ///    그대로 clear 비트를 세운다. 종전 구현은 nil(=클리어 안 함)이었다 — 정반대다.
    ///
    /// 성분 순서가 RGBA 인 근거는 클리어 호출부다(`0x1401eba68`-`0x1401eba7f`):
    /// `xmm1=[+0x14]` `xmm2=[+0x18]` `xmm3=[+0x1c]`, 5번째 인자 `[+0x20]` 순으로 넘긴다.
    ///
    /// 비유한값(nan/inf) 거부는 원본에 없는 우리 쪽 방어다 — 이 값은 MTLClearColor 로 직행하므로
    /// 신뢰불가 입력이 드라이버까지 가면 안 된다. 원본은 `strtod` 결과를 그대로 쓴다.
    static func parseClearColor(_ v: Any?) -> SIMD4<Float>? {
        guard let s = v as? String else { return nil }
        if s.isEmpty { return SIMD4(0, 0, 0, 0) }
        let tokens = s.split(separator: " ", omittingEmptySubsequences: true)
        guard tokens.count == 4 else { return nil }
        let parsed = tokens.map { Float($0) }
        guard !parsed.contains(where: { $0 == nil }) else { return nil }
        let parts = parsed.map { $0! }
        guard parts.allSatisfy({ $0.isFinite }) else { return nil }
        return SIMD4(parts[0], parts[1], parts[2], parts[3])
    }

    /// JSON 값이 **진짜 boolean** 인가. `JSONSerialization` 은 숫자와 불리언을 모두 `NSNumber` 로
    /// 주고 Swift 의 동적 캐스트는 둘을 섞어 준다(`1 as? Bool` → true, `true as? Int` → 1).
    /// 원본 파서는 JsonCpp 타입 태그로 엄격히 가르므로 우리도 갈라야 한다.
    static func isJSONBool(_ v: Any?) -> Bool {
        guard let n = v as? NSNumber else { return false }
        // `objCType` 이 "c"(char) 인 것만 boolean 이다. `CFGetTypeID(n) == CFBooleanGetTypeID()` 가
        // 더 직설적이지만 CoreFoundation 을 끌어와야 해서 리눅스 타입체크(우리 사전 게이트)가 깨진다.
        // JSONSerialization 은 Int8 을 만들지 않으므로 "c" 는 boolean 과 1:1 이다.
        return n.objCType.pointee == 0x63
    }

    private static func safeInt(_ v: Any?) -> Int? {
        // `true as? Int` 는 1 로 성공한다 — `{"fit":true}` 가 1×1 렌더 타깃을 만든다.
        // 8192 클램프를 둔 것과 같은 이유(신뢰불가 정수가 makeTexture 로 직행)로 여기서 막는다.
        if isJSONBool(v) { return nil }
        if let i = v as? Int { return i }
        if let d = v as? Double {
            guard d.isFinite, d >= Double(Int.min), d < Double(Int.max) else { return nil }
            return Int(d)
        }
        return nil
    }
}
