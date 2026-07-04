import Foundation

/// WapleCore 경계의 최소 로깅 훅. 코어 코드가 `NSLog` 을 직접 호출하지 않도록 한 곳으로 모은다.
/// 기본 핸들러는 기존 `NSLog("%@", …)` 동작과 동일. 테스트는 `warnHandler` 를 교체해 출력을
/// 가로채거나(어서션) 무음화할 수 있다.
public enum WapleLog {
    /// 경고 메시지 싱크. 기본: NSLog. 교체는 프로세스 전역이므로 테스트에서 defer/tearDown 로 원복할 것.
    public static var warnHandler: (String) -> Void = { NSLog("%@", $0) }

    /// 경고 로깅(기존 `NSLog("%@", …)` 대체). 경계 정리용 — 코어는 이 훅만 호출한다.
    public static func warn(_ message: String) {
        warnHandler(message)
    }
}
