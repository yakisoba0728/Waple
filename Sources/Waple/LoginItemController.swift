import Foundation
import ServiceManagement

/// 로그인 시 자동 시작(SMAppService.mainApp) 등록/해제.
///
/// SPM 단독 실행 파일(번들 미등록)은 register 가 실패할 수 있다 — 호출부는 실패를 조용히 로깅만 하고
/// 체크 상태는 실제 `isEnabled`(status) 로 재조회해 어긋나지 않게 한다.
enum LoginItemController {
    /// 현재 로그인 항목으로 등록되어 있는가.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 등록/해제. 실패는 throw(호출부에서 조용히 처리).
    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            if service.status != .enabled { try service.register() }
        } else if service.status == .enabled || service.status == .requiresApproval {
            try service.unregister()
        }
    }
}
