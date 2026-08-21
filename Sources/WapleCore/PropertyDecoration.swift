import Foundation

/// 편집 UI 에서 숨길 '장식(decoration)' 프로퍼티 판정(작업 7).
/// WE 워크샵에는 속성 패널을 HTML 광고·링크·구분선으로 꾸미는 관행이 있어(WaifuX 실측 근거),
/// key 가 imgsrc/brimgsrc 로 시작하거나 text 에 <img/<a/<hr 이 있으면 실제 편집 대상이 아니다.
///
/// **WE 스키마 대조**(`ui/dist/scripts/scripts.js` 의 `views/includes/browseruserproperties.html`
/// 템플릿, 오프셋 750144–757383): 브라우저가 아는 프로퍼티 `type` 은
/// `color · bool · textinput · slider · volume · combo · combolutfilters · directory · file ·
///  scenetexture · usershortcut · divider` 열둘 + 그룹 컨테이너 `group` 이고, 이 중 **`divider`
/// 만 편집 위젯 없이 `<hr class="fullWidth">` 하나를 그린다** — 즉 WE 자신의 스키마에도
/// 장식 타입이 하나 있다. 설치본 코퍼스 도달은 0 이지만(프로퍼티 244개 중 divider 0건,
/// imgsrc 도 0건 — 위 휴리스틱과 같은 처지다) 판정은 스키마 쪽이 근거가 확실하다.
public enum PropertyDecoration {
    public static func isDecoration(_ property: WallpaperProperty) -> Bool {
        if property.type.lowercased() == "divider" { return true }
        let key = property.key.lowercased()
        if key.hasPrefix("imgsrc") || key.hasPrefix("brimgsrc") { return true }
        let text = (property.text ?? "").lowercased()
        return text.contains("<img") || text.contains("<a") || text.contains("<hr")
    }

    /// 조건부 표시(PropertyConditionEvaluator)와 합성해, 장식 프로퍼티까지 제외한 최종 표시 인덱스.
    public static func visibleIndices(in properties: [WallpaperProperty]) -> [Int] {
        PropertyConditionEvaluator.visibleIndices(in: properties)
            .filter { !isDecoration(properties[$0]) }
    }
}
