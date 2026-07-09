import Foundation

/// 편집 UI 에서 숨길 '장식(decoration)' 프로퍼티 판정(작업 7).
/// WE 워크샵에는 속성 패널을 HTML 광고·링크·구분선으로 꾸미는 관행이 있어(WaifuX 실측 근거),
/// key 가 imgsrc/brimgsrc 로 시작하거나 text 에 <img/<a/<hr 이 있으면 실제 편집 대상이 아니다.
public enum PropertyDecoration {
    public static func isDecoration(_ property: WallpaperProperty) -> Bool {
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
