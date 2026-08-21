import Foundation

/// 자산 JSON 을 **WE 파서의 관용도**로 읽는다.
///
/// WE 는 jsoncpp 를 쓰고 `CharReaderBuilder` 의 `allowComments` 와 `allowTrailingCommas` 를
/// **둘 다 true 로 둔다**(0x140091fe2 · 0x1400920b3). 즉 관용은 이펙트 매니페스트만의 성질이
/// 아니라 **WE 가 읽는 모든 JSON 의 성질**이고, WE 자기 자산이 실제로 그 관용에 의존한다.
///
/// ## `CharReaderBuilder::setDefaults` 전수 (`0x140091ef0`–`0x1400924b4`)
///
/// 종전에는 위 두 설정만 확인돼 있었다. **[2026-08-21] 그 함수를 통째로 떠서 12개 설정을
/// 전수했다** — 각 설정은 `mov byte [rbp-0x30], <태그>` 로 값 태그를, `mov [rbp-0x38], <값>` 으로
/// 값을 세운 뒤 `operator[](char*)`(`0x140086de0`)로 심는다. `r14b` 는 진입부
/// `xor r14d,r14d`(`0x140091f2c`)라 **0(false)** 이다.
///
/// | 설정 | 값 | 값 스토어 VA |
/// | --- | --- | --- |
/// | `collectComments` | **true** | `0x140091f12` |
/// | `allowComments` | **true** | `0x140091fed` |
/// | `allowTrailingCommas` | **true** | `0x1400920be` |
/// | `strictRoot` | false | `0x140092195` |
/// | `allowDroppedNullPlaceholders` | false | `0x140092235` |
/// | `allowNumericKeys` | false | `0x14009227b` |
/// | `allowSingleQuotes` | false | `0x1400922c1` |
/// | `stackLimit` | **0x100 = 256**(태그 1) | `0x140092307` |
/// | `failIfExtra` | false | `0x140092351` |
/// | `rejectDupKeys` | false | `0x14009238b` |
/// | `allowSpecialFloats` | **false** | `0x1400923dd` |
/// | `skipBom` | **true** | `0x140092423` |
///
/// ## 우리(Foundation)와 실물의 대조 — 리눅스 실측 2026-08-21
///
/// `swift-corelibs-foundation` 의 `JSONSerialization.jsonObject(with:)` 를 직접 돌려 잰 것이다.
///
/// | 입력 | 실물 | Foundation | 판정 |
/// | --- | --- | --- | --- |
/// | 줄 주석 `//` | 허용 | 거부 | `relaxed` 가 메운다 |
/// | 트레일링 콤마 | 허용 | 거부 | `relaxed` 가 메운다 |
/// | BOM `EF BB BF` | 허용(`skipBom`) | **허용** | 일치 — 손댈 것 없다 |
/// | 중복 키 `{"a":1,"a":2}` | 허용, **뒤가 이긴다**(`rejectDupKeys=false`) | 허용, **뒤가 이긴다**(a=2) | 일치 |
/// | `NaN`/`Infinity` 리터럴 | 거부(`allowSpecialFloats=false`) | 거부 | 일치 |
/// | 작은따옴표 `{'a':1}` | 거부(`allowSingleQuotes=false`) | 거부 | 일치 |
/// | 숫자 키 `{1:2}` | 거부(`allowNumericKeys=false`) | 거부 | 일치 |
/// | 문자열 안 raw 제어문자 | 미확인 | 거부 | **[미해결]** |
/// | 루트 뒤 잔여 바이트 | **허용**(`failIfExtra=false`) | 거부 | 우리가 더 엄격(도달 0) |
/// | 루트 스칼라 `42` | **허용**(`strictRoot=false`) | 거부(`.allowFragments` 없음) | 우리가 더 엄격(도달 0) |
/// | 중첩 깊이 > 256 | 거부(`stackLimit`) | 자체 한계(다름) | 폭이 다름(도달 0) |
///
/// 즉 **관용이 필요한 실제 차이는 주석과 트레일링 콤마 둘뿐**이고, 나머지 열 갈래는
/// 이미 일치하거나 우리가 더 엄격한 쪽이다(코퍼스 도달 0).
///
/// 종전에는 `EffectManifest.parse` 만 관용이었다. 그래서 머티리얼·모델·씬·프로젝트 리더는
/// 맨 `JSONSerialization` 이었고, **동봉 기본 프로젝트에서 실제로 깨졌다**:
///
///     projects/defaultprojects/fantasticcar/materials/car/glass.json:6
///         //"cullmode": "nocull",          ← 줄 주석
///
/// `models/car/body.mdl` 이 이 경로를 머티리얼 문자열로 담는다. 엄격 파스가 실패하면 그
/// 메시의 `textures:["car/glass"]` · `blending:"translucent"` · `constantshadervalues`
/// 셋이 통째로 유실된다 — 유리가 불투명해지고 스페큘러가 사라진다.
/// `assets/presets/water/preset.json:55` 는 트레일링 콤마로 같은 부류다.
///
/// **엄격을 먼저 시도하고 실패했을 때만** 전처리를 태운다. 정상 자산은 종전 경로 그대로라
/// 무회귀이고, 실패하던 자산만 복구된다.
///
/// 관용은 딱 둘로 제한한다 — 줄 주석과 트레일링 콤마.
///
/// **블록 주석 `/* */` 은 여전히 일부러 넣지 않았다.** 근거는 이번에 더 세졌다:
/// `allowComments=true`(`0x140091fed`)는 jsoncpp 에서 `//` 와 `/* */` 를 **둘 다** 켜고,
/// 토크나이저도 실제로 둘 다 소비한다(직접 재확인 — `0x14008e968 cmp al,0x2f` 로 `/` 를 보고
/// `0x14008e975 cmp al,0x2a` 로 `*` 를 가른 뒤 `0x14008e996`–`0x14008e99a` 에서 `*/` 를 찾는다;
/// 종료 판정은 `0x14008e9d3 cmp cl,0x2f`). 그런데도 안 넣는 이유는 **도달 0건**이다 —
/// 동봉 WEAssets 1,698 + 설치본 `wallpaper_engine` 트리 2,143(= assets 1,698 + projects 259 +
/// locale 75 + ui 100 + 그 외 11) 의 **합집합 2,143 파일**(동봉본과 설치본 `assets/` 는
/// `diff -rq` 무출력으로 바이트 동일)에서 블록 주석 0건. 스코프 라벨을 붙이면 종전 문장의
/// "동봉·설치본 자산 2,143개" 는 **합집합**을 뜻한 것이고 단순 합(3,841)이 아니다.
///
/// **넘길 것**: 지원하기로 뒤집으려면 Swift 쪽과 `scripts/spec/check_lenient_json_reach.py`
/// 의 파이썬 모델(`relaxed()` + `selftest()` 의 "블록 주석이 통과했다" 음성 대조)을
/// **같이** 고쳐야 한다. 한쪽만 고치면 게이트가 거짓말을 하게 된다.
public enum AssetJSON {

    /// 줄 주석과 트레일링 콤마만 걷어낸다. 문자열 리터럴 안은 **절대** 건드리지 않는다
    /// (이스케이프 포함) — `{"a":"x,]"}` 같은 값이 깨지면 안 된다.
    public static func relaxed(_ data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var out = String(); out.reserveCapacity(text.count)
        var inString = false
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if inString {
                out.append(c)
                if c == "\\" {
                    let next = text.index(after: i)
                    if next < text.endIndex { out.append(text[next]); i = text.index(after: next); continue }
                } else if c == "\"" {
                    inString = false
                }
                i = text.index(after: i); continue
            }
            if c == "\"" { inString = true; out.append(c); i = text.index(after: i); continue }
            // 줄 주석: `//` 부터 개행 전까지 버린다(개행은 남긴다 — 줄 번호 보존).
            //
            // **[2026-08-21] `!= "\n"` 이 CRLF 를 못 넘었다.** Swift `String` 은 유니코드
            // **그래핌 클러스터** 단위로 순회하고 `"\r\n"` 은 **한 개의 `Character`** 다.
            // `Character("\r\n") == "\n"` 은 **false** 이므로 CRLF 파일에서는 이 루프가
            // 개행에 멈추지 못하고 **파일 끝까지** 지워 버렸다 — 즉 `//` 가 하나라도 있는
            // CRLF 자산은 관용 파스가 통째로 실패했다. 동봉 `effects/**/effect.json` 은
            // **122개 전건이 CRLF** 이고, 엄격 파스가 실패해 관용이 필요한 자산 31건도
            // **전건 CRLF** 다. `isNewline` 은 `"\n"`·`"\r"`·`"\r\n"` 을 모두 참으로 본다.
            if c == "/" {
                let next = text.index(after: i)
                if next < text.endIndex, text[next] == "/" {
                    while i < text.endIndex, !text[i].isNewline { i = text.index(after: i) }
                    continue
                }
            }
            // 트레일링 콤마: `,` 뒤 공백만 지나 `]`/`}` 가 오면 그 콤마를 버린다.
            if c == "," {
                var j = text.index(after: i)
                // 같은 그래핌 문제: `"\r\n"` 은 `"\r"` 도 `"\n"` 도 아니라 종전 집합을 빠져나갔다.
                while j < text.endIndex, text[j] == " " || text[j] == "\t" || text[j].isNewline {
                    j = text.index(after: j)
                }
                if j < text.endIndex, text[j] == "]" || text[j] == "}" {
                    i = text.index(after: i); continue
                }
            }
            out.append(c); i = text.index(after: i)
        }
        return out.data(using: .utf8)
    }

    /// 엄격 → 실패 시 관용. 둘 다 실패하면 nil.
    public static func object(_ data: Data) -> Any? {
        if let o = try? JSONSerialization.jsonObject(with: data) { return o }
        guard let r = relaxed(data) else { return nil }
        return try? JSONSerialization.jsonObject(with: r)
    }

    /// 최상위가 오브젝트일 때만 돌려준다 — 호출부 대부분이 그 형태다.
    public static func dictionary(_ data: Data) -> [String: Any]? {
        object(data) as? [String: Any]
    }
}
