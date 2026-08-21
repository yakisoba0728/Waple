import Foundation

/// 자산 JSON 을 **WE 파서의 관용도**로 읽는다.
///
/// WE 는 jsoncpp 를 쓰고 `CharReaderBuilder` 의 `allowComments` 와 `allowTrailingCommas` 를
/// **둘 다 true 로 둔다**(0x140091fe2 · 0x1400920b3). 즉 관용은 이펙트 매니페스트만의 성질이
/// 아니라 **WE 가 읽는 모든 JSON 의 성질**이고, WE 자기 자산이 실제로 그 관용에 의존한다.
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
/// 관용은 딱 둘로 제한한다(WE 의 `allowComments`/`allowTrailingCommas` 와 같은 범위).
/// **블록 주석 `/* */` 은 일부러 넣지 않았다** — WE 토크나이저는 그것도 소비하지만
/// (0x14008e949–0x14008e9d6) 동봉·설치본 자산 2,143개 전수에서 0건이라, 근거 없는 관용을
/// 늘리는 대신 이 유보를 기록으로 남긴다.
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
            if c == "/" {
                let next = text.index(after: i)
                if next < text.endIndex, text[next] == "/" {
                    while i < text.endIndex, text[i] != "\n" { i = text.index(after: i) }
                    continue
                }
            }
            // 트레일링 콤마: `,` 뒤 공백만 지나 `]`/`}` 가 오면 그 콤마를 버린다.
            if c == "," {
                var j = text.index(after: i)
                while j < text.endIndex, text[j] == " " || text[j] == "\t" || text[j] == "\r" || text[j] == "\n" {
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
