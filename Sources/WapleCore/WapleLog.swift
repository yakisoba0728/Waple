import Foundation

/// WapleCore 경계의 최소 로깅 훅. 코어 코드가 `NSLog` 을 직접 호출하지 않도록 한 곳으로 모은다.
/// 기본 핸들러는 기존 `NSLog("%@", …)` 동작과 동일. 테스트는 `warnHandler` 를 교체해 출력을
/// 가로채거나(어서션) 무음화할 수 있다.
public enum WapleLog {
    /// 경고 메시지 싱크. 기본: NSLog. 교체는 프로세스 전역이므로 테스트에서 defer/tearDown 로 원복할 것.
    ///
    /// nonisolated(unsafe): 이 훅은 **테스트 시임**이다(WapleLogTests·DrawFailureDiagnosticsTests·
    /// SceneRenderFixRegressionTests 가 setUp/defer 로 교체·원복). 쓰기는 그 교체 시점뿐이고 — 즉
    /// 검증 대상 코드를 돌리기 **전에** 한 번 — 그 뒤로는 읽기만 있다(write-once-before-use).
    /// 타입을 `@Sendable (String) -> Void` 로 좁히지 않은 이유: 테스트가 지역 `var captured` 배열에
    /// append 하는 클로저를 꽂는데, @Sendable 로 만들면 그 캡처가 진단 대상이 되어 **소스 타깃의
    /// 경고를 테스트 타깃으로 옮기기만 한다**. 시임의 계약(설치 후 읽기 전용)이 실제 안전 근거다.
    nonisolated(unsafe) public static var warnHandler: (String) -> Void = { NSLog("%@", $0) }

    /// 경고 로깅(기존 `NSLog("%@", …)` 대체). 경계 정리용 — 코어는 이 훅만 호출한다.
    public static func warn(_ message: String) {
        warnHandler(message)
    }
}
