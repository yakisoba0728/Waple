import XCTest
@testable import WapleRender
@testable import WapleCore

/// 실물 코퍼스 프로브(env WAPLE_REAL_PKGS ?? ~/Downloads/wallpaper_dev/backgrounds, 부재 시 skip — CI 안전,
/// RealPackagesGroundTruthTests 가드 패턴): mip>1 .tex 전건의 전체 mip 체인 파스·레벨별 디코드 성공 단언.
/// 실물 DJK_1.tex 클래스(mip 9개)가 대상 — 저장 체인 수집/디코드가 실물 데이터에서 깨지지 않음을 보증.
final class RealTexMipChainProbeTests: XCTestCase {
    func testRealCorpusMipChainTexturesDecodeAllLevels() throws {
        let base = ProcessInfo.processInfo.environment["WAPLE_REAL_PKGS"]
            ?? (NSHomeDirectory() + "/Downloads/wallpaper_dev/backgrounds")
        let baseURL = URL(fileURLWithPath: base)
        guard FileManager.default.fileExists(atPath: base) else { throw XCTSkip("no real pkgs dir: \(base)") }
        let folders = (try FileManager.default.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil))
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var found = 0          // mipChain>1(mip>1 저장) .tex 수
        var decoded = 0        // rgbaLevels 전 레벨 디코드 성공 수
        var nativeOK = 0       // BC 네이티브 후보 levels==chain 일치 수
        var failures: [String] = []
        for folder in folders {
            for pkgName in ["scene.pkg", "gifscene.pkg"] {
                let url = folder.appendingPathComponent(pkgName)
                guard let pkgData = try? Data(contentsOf: url),
                      let pkg = try? ScenePackage.parse(pkgData) else { continue }
                for e in pkg.entries where e.name.hasSuffix(".tex") {
                    guard let raw = pkg.data(for: e.name), let tex = TexImage.parse(raw) else { continue }
                    guard tex.mipChain.count > 1 else { continue }
                    found += 1
                    let tag = "\(folder.lastPathComponent)/\(e.name)"
                    // mip 기반 페이로드만 디코드 단언(.unknown 등은 기존처럼 디코드 불가 — 무회귀 대상 외).
                    switch tex.payload {
                    case .bc3, .bc2, .bc1, .r8, .rg88, .lz4RGBA: break
                    default: continue
                    }
                    guard let levels = TexDecoder.rgbaLevels(from: tex, data: raw) else {
                        failures.append("\(tag): rgbaLevels nil(fmt\(tex.format), chain \(tex.mipChain.count))")
                        continue
                    }
                    decoded += 1
                    XCTAssertEqual(levels.count, tex.mipChain.count, "\(tag): 레벨 수 == 체인 수")
                    for (i, lv) in levels.enumerated() {
                        XCTAssertEqual(lv.width, max(1, levels[0].width >> i),
                                       "\(tag) L\(i): 폭 진행 max(1,\(levels[0].width)>>\(i))")
                        XCTAssertEqual(lv.height, max(1, levels[0].height >> i), "\(tag) L\(i): 높이 진행")
                        XCTAssertEqual(lv.pixels.count, lv.width * lv.height * 4, "\(tag) L\(i): 픽셀 수")
                    }
                    // BC 는 네이티브 후보도 체인 일치여야(CPU 추출 — 디바이스 무관).
                    switch tex.payload {
                    case .bc1, .bc2, .bc3:
                        if let bc = TexDecoder.nativeBC(from: tex, data: raw) {
                            XCTAssertEqual(bc.levels.count, tex.mipChain.count,
                                           "\(tag): 네이티브 levels == 체인 수")
                            nativeOK += 1
                        }
                    default: break
                    }
                }
            }
        }
        NSLog("%@", "[mipchain-probe] found=\(found) decoded=\(decoded) nativeBC=\(nativeOK) failures=\(failures.count)")
        if found == 0 { throw XCTSkip("코퍼스에 mip>1 .tex 부재 — 프로브 불능") }
        XCTAssertEqual(decoded, found, "mip>1 전건 디코드 성공. 실패: \(failures.prefix(5))")
    }
}
