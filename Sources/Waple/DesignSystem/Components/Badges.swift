import SwiftUI

/// 썸네일 위에 얹는 유형 배지 — 무엇인지(장면·동영상·웹·지원 예정)를 한 단어로 말한다.
///
/// 캡슐 + 얇은 재질은 종전 그리드 배지에서 승격했다. 재질을 쓰는 이유는 아래 이미지가 비쳐야
/// 이 배지가 **그 썸네일에 붙은 것**으로 읽히기 때문이고, 재질이라 다크·라이트·투명도 줄이기가
/// 전부 시스템 몫이다(`Surface.badge`).
///
/// ## 문구를 `Text` 로 받는 이유
///
/// 파라미터가 `String` 이면 호출부가 한국어 리터럴을 담은 변수를 넘기게 되고, 그 순간
/// `Text(someString)` 비현지화 오버로드로 붙어 **영어 시스템에서도 한국어가 나오는데 아무 것도
/// 실패하지 않는다**(실측: 사용자 대면 문자열 42건 중 40건이 이 병이다).
/// `Text` 로 받으면 호출부가 리터럴(자동 번역 + 커버리지 오라클에 잡힘)과 런타임 데이터를
/// 명시적으로 구분하게 된다. 규약이 타입으로 강제된다 — `tileAccessibility` 와 같은 이유다.
///
/// ## 접근성
///
/// `Label` 은 글자와 글리프를 한 요소로 묶어 읽으므로 따로 붙일 게 없다. 아이콘만 남기지
/// 마라 — 유형 배지는 색과 모양만으로도 구분되는 것처럼 보이지만 그건 눈으로 볼 때 이야기다.
struct TypeBadge: View {
    /// SF Symbol 이름. 사용자에게 보이는 문자열이 아니라 자산 식별자라 `String` 이 맞다.
    let symbol: String
    /// 배지 문구.
    let label: Text

    var body: some View {
        Label(title: { label }, icon: { Image(systemName: symbol) })
            .font(Typography.badge)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, Space.badgeH)
            .padding(.vertical, Space.badgeV)
            .background(Surface.badge, in: Capsule())
            .padding(Space.xs)
    }
}

/// 수치 배지 — 평점·구독 수처럼 **숫자가 곧 내용**인 자리.
///
/// `TypeBadge` 와 겉모습은 같지만 두 가지가 다르다.
///
/// 1. 글꼴이 `Typography.metric`(고정폭 숫자)이다. 값이 갱신되며 자리수가 변하는 숫자를
///    비례 숫자로 두면 폭이 튀어 옆 요소가 밀린다.
/// 2. **접근성 이름을 따로 받는다.** 화면에는 숫자만 보이고 무슨 수치인지는 글리프가 말하는데,
///    글리프는 보조기술에 읽히지 않는다. 그대로 두면 VoiceOver 가 "4.2" 만 읽는다.
///    그래서 이름은 라벨로, 숫자는 값으로 나눈다 — 상태를 이름에 이어 붙이면 값이 바뀔 때마다
///    항목 전체가 다시 읽힌다(청사진 §4.2).
///
/// 색은 호출부가 정한다(`.foregroundStyle(ColorRole.rating)` 등). 파라미터로 받지 않는 이유는
/// 배지가 쓰이는 자리마다 뜻이 다르고, 색은 이미 `ColorRole` 이 이름으로 관리하기 때문이다.
struct MetricBadge: View {
    /// SF Symbol 이름.
    let symbol: String
    /// 표시되는 수치. 숫자만 담는다 — 단위와 이름은 `label` 쪽이다.
    let value: Text
    /// 이 수치가 무엇인지. 화면에는 안 보이고 보조기술만 읽는다.
    let label: Text

    var body: some View {
        Label(title: { value }, icon: { Image(systemName: symbol) })
            .font(Typography.metric)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, Space.badgeH)
            .padding(.vertical, Space.badgeV)
            .background(Surface.badge, in: Capsule())
            .padding(Space.xs)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(value)
    }
}
