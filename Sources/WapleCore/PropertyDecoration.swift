import Foundation

/// 편집 UI 에서 숨길 '장식(decoration)' 프로퍼티 판정(작업 7).
/// WE 워크샵에는 속성 패널을 HTML 광고·링크·구분선으로 꾸미는 관행이 있어(WaifuX 실측 근거),
/// key 가 imgsrc/brimgsrc 로 시작하거나 text 에 <img/<a/<hr 이 있으면 실제 편집 대상이 아니다.
///
/// **WE 스키마 대조**(`ui/dist/scripts/scripts.js` 의 `views/includes/browseruserproperties.html`
/// 템플릿, char@750151–757383): 브라우저가 아는 프로퍼티 `type` 은
/// `color · bool · textinput · slider · volume · combo · combolutfilters · directory · file ·
///  scenetexture · usershortcut · divider` 열둘 + 그룹 컨테이너 `group` 이고, 이 중 **`divider`
/// 만 편집 위젯 없이 `<hr class="fullWidth">` 하나를 그린다** — 즉 WE 자신의 스키마에도
/// 장식 타입이 하나 있다. 설치본 코퍼스 도달은 0 이지만(프로퍼티 **241개** 중 divider 0건,
/// imgsrc 도 0건 — 위 휴리스틱과 같은 처지다) 판정은 스키마 쪽이 근거가 확실하다.
///
/// # 이 판정은 **편집 UI 전용이다** — 런타임 값에 영향이 없다 (2026-08-21 클러스터 AF 확정)
///
/// 못박아 둔다. 근거 셋이고, 셋 다 값싸고 결정적이다.
///
/// 1. **로케일이 이름을 그렇게 부른다.** `wallpaper_engine/locale/ui_en-us.json`:
///    `ui_editor_user_properties_condition` = **"Display Condition"**,
///    자리표시자 `ui_editor_user_properties_condition_placeholder` = `"otherkey.value == XYZ"`,
///    그리고 `ui_editor_user_properties_value` = **"Default Value"**. 조건은 *표시* 를 정하고,
///    `value` 는 *기본값* 이다. (이 리포는 `disablepropagation` 을 같은 방식으로 UI 문자열로
///    확정한 전례가 있다.)
/// 2. **템플릿이 `ng-if`/`ng-show` 하나로 끝난다.** 조건이 거짓이면 **행이 안 그려질 뿐**이고
///    `property.value` 는 그대로 남아 `callbackWallpaperPropertyChanged` 로 엔진에 나간다.
///    숨겨진 프로퍼티의 값이 바뀌거나 지워지는 코드는 없다(char@750308 브라우저 ·
///    char@757571 그룹 · char@945562 플러그인 옵션 · char@993077 에디터 목록).
/// 3. **엔진은 조건을 쓰기만 한다.** `wallpaper64.exe` 의 `"condition"` 문자열
///    (0x140474a60) xref **16자리** 중 10 이 내장 프로퍼티 주입기 0x140104b60 의 **쓰기**이고,
///    읽는 자리 6 중 어느 것도 표시 조건식 평가기가 아니다(씬 `user` 바인딩 0x1401a4f1b ·
///    TEXB 변형 0x14015cc13 등 — 전부 **값 동등비교** 문법). 결정적 반증: 주입기가 쓰는 조건
///    `alignment.value<2&&checkPositionVisibility()` 의 `checkPositionVisibility` 는
///    **브라우저 스코프 함수**다(scripts.js char@106119). 엔진에는 그 함수가 없으므로 엔진은
///    이 식을 평가할 수 없다.
///
/// 따라서 `visibleIndices` 는 **패널에 무엇을 그릴지**만 정한다. 값 합성(오버라이드 병합,
/// 셰이더/씬으로의 전달)은 `WallpaperProperties.applying(overrides:to:)` 와
/// `SceneDocument.resolveUserBindings` 가 하고, **둘 다 이 판정을 보지 않는다** — 숨겨진
/// 프로퍼티도 값은 살아 있다. 이게 WE 와 같은 동작이다.
///
/// - Note: `group` 은 여기서 장식으로 치지 **않는다**. `divider` 는 `<hr>` 하나라 정말 아무것도
///   아니지만 `group` 은 제목 + 접기 컨테이너를 그리고 자기 `condition` 으로 **그룹 전체**를
///   숨긴다(`browseruserpropertiesgroup.html` 의 `ng-show`, char@757571). 값이 없다는 점은
///   같지만 화면에 남는 것이 있어 성격이 다르다. 설치본 도달 0(`group` 0건)이라 어느 쪽으로
///   골라도 코퍼스가 안 움직이므로, 정보를 지우지 않는 쪽으로 둔다.
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
