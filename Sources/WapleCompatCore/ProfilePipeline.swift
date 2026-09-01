import Foundation
import AppKit
import Darwin
import WapleCore
import WapleRender

/// 성능 실측 드라이버(하네스 전용). WapleProfiler(제품, 기본 비활성) 계측을 켜고 마운트/캡처를
/// 실행해 씬별 페이즈 분해 + 텍스처/셰이더/파티클/메모리 통계를 JSON 으로 낸다.
///
/// 규약: 씬 1개 = 프로세스 1개(`--only <id>`) — 메모리 상주(phys_footprint) 오염 방지 + Metal
/// 컴파일러 콜드 상태 재현. 캡처 결정 조건은 SnapshotPipeline 재사용(pin + StoppedNowPlaying + pause).
public enum ProfilePipeline {

    // MARK: 프로세스 상주 메모리(phys_footprint) — 통합메모리이므로 GPU 텍스처 포함.

    static func physFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<natural_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    // MARK: --inventory : 표본 선정용 씬별 경량 메타(파스만, 마운트 없음)


    /// **[2026-08-25] 이 두 파이프라인이 `.pkg` 만 열고 있었다.**
    ///
    /// `SnapshotPipeline.sceneFolders` 는 packed 가 0개면 `unpackedSceneFolders` 로 폴백하는데,
    /// 그 폴백이 돌려주는 폴더는 **정의상 `.pkg` 가 없다**(`project.json` 로 판정한 언팩 프로젝트다).
    /// 그런데 `--inventory`/`--vis-blast` 는 `folder/scene.pkg` 를 직접 열고 실패하면 `return` 으로
    /// 조용히 건너뛰었다. `folders.isEmpty` 가드는 폴더가 있으니 통과한다 — 결과는
    /// `scenes=0` + **exit 0**. 측정이 아니라 침묵이고, `vis-blast` 는 한술 더 떠
    /// `scenes-scanned=16 scenes-affected=0` 을 **적극적으로 단언**했다.
    ///
    /// 이건 `DeepScan.scanScene` 이 3차 웨이브에서 이미 고친 것과 **같은 결함**이다(그 주석 참조 —
    /// WE 2.8.42 설치본은 씬 188/188 이 언팩이고 `.pkg` 가 0개다). 그때 형제 스캐너 셋 중 둘만
    /// 고쳐졌고 여기 둘이 남아 있었다. 마운트 선택자를 렌더러·DeepScan 과 **같은 함수**로 맞춘다 —
    /// `project.json` 의 `file` 이 단독 결정자이고 `.pkg` 는 그 파일이 디스크에 없을 때의 폴백이다.
    static func mountPackage(_ folder: URL) -> ScenePackage? {
        let project = try? ProjectJSONParser.parse(folderURL: folder)
        switch ScenePackage.resolveMountSource(folderURL: folder,
                                               fileName: project?.fileName ?? "scene.pkg",
                                               hasDependency: project?.dependency != nil) {
        case .package(let pkgURL):
            guard let d = try? Data(contentsOf: pkgURL, options: .mappedIfSafe) else { return nil }
            return try? ScenePackage.parse(d)
        case .directory:
            return ScenePackage.fromDirectory(folder)
        }
    }


    /// 드롭 보고 + 종료코드 판정. **전건 드롭은 성공이 아니다.**
    ///
    /// 이 리포는 "조용히 틀리는 것보다 실패하는 쪽" 을 택해 왔다(`ShaderPreprocessor` 의 `#if` 거부가
    /// 그 예다). 진단 도구가 아무것도 못 읽고도 exit 0 을 내면 그 원칙이 정반대로 뒤집힌다 —
    /// CI 나 사람이 "돌렸고 통과했다" 로 읽는다. 그래서 셋으로 나눈다:
    ///   · 하나도 못 읽음 → **exit 2**(F520 의 "씬 0개" 가드와 같은 판정)
    ///   · 일부 드롭      → exit 0 이되 stderr 에 건수와 앞 10건을 남긴다(부분 코퍼스는 정상 상황이다)
    ///   · 드롭 없음      → exit 0, 조용
    static func reportDrops(tag: String, rows: Int, folders: Int, dropped: [String]) -> Int32 {
        guard !dropped.isEmpty else { return 0 }
        fputs("[\(tag)] ⚠️ \(dropped.count)/\(folders) 건이 드롭됐다:\n", stderr)
        for d in dropped.prefix(10) { fputs("[\(tag)]    · \(d)\n", stderr) }
        if dropped.count > 10 { fputs("[\(tag)]    · … 외 \(dropped.count - 10)건\n", stderr) }
        if rows == 0 {
            fputs("[\(tag)] ❌ 읽어낸 씬이 **0개**다 — 이 실행은 아무것도 측정하지 않았다. "
                  + "root 가 가리키는 트리에 마운트 가능한 씬이 있는지 확인하라.\n", stderr)
            return 2
        }
        return 0
    }

    struct InventoryRow { let id: String; let is3D: Bool; let layers: Int; let effects: Int
                          let particles: Int; let texBytes: Int; let hdr: Bool; let bloom: Bool }

    public static func runInventory(root: String, outCSV: URL) -> Int32 {
        let restore = SnapshotPipeline.pinRenderSettings(root: root)
        defer { restore() }
        // F520: 루트 오지정으로 씬 0개면 빈 CSV 를 쓰고 exit 0 → CI 오인 방지(capture/compare 와 동일 가드).
        let folders = SnapshotPipeline.sceneFolders(root: root)
        guard !folders.isEmpty else {
            fputs("[profile] ⚠️ 씬 0개 — root 지정 확인: \(root)\n", stderr); return 2
        }
        // F680: 공유 에셋 리졸버 — assets: nil 이면 models/util/*.json 등 pkg 외 참조를 쓰는 레이어가
        // 파스 단계에서 드롭되어 layers/effects 카운트가 실제보다 적게 찍혔다(3706286085: 실물 36오브젝트인데
        // layers=0 실측). DeepScan 과 동일 해석(root/assets → 형제 assets 순으로 첫 존재).
        let rootURL = URL(fileURLWithPath: NSString(string: root).expandingTildeInPath, isDirectory: true).standardizedFileURL
        let assetsDir = DeepScan.firstExisting([rootURL.appendingPathComponent("assets"),
                                                rootURL.deletingLastPathComponent().appendingPathComponent("assets")])
        var rows: [InventoryRow] = []
        var dropped: [String] = []
        for folder in folders {
            let id = folder.lastPathComponent
            autoreleasepool {
                guard let pkg = mountPackage(folder) else { dropped.append("\(id): 마운트 실패"); return }
                let res = PkgAssets(package: pkg, assetsDir: assetsDir)
                guard let doc = try? SceneDocument.parse(
                    package: pkg,
                    assets: { res.baseAssetURL($0).flatMap { try? Data(contentsOf: $0) } }
                ) else { dropped.append("\(id): 씬 파스 실패"); return }
                let is3D = doc.camera3D != nil && !doc.objects3D.isEmpty
                let effects = doc.layers.reduce(0) { $0 + $1.effects.count }
                let texBytes = pkg.entries.filter { $0.name.hasSuffix(".tex") }.reduce(0) { $0 + $1.size }
                rows.append(InventoryRow(id: id, is3D: is3D, layers: doc.layers.count, effects: effects,
                                         particles: doc.particles.count, texBytes: texBytes,
                                         hdr: doc.hdr, bloom: doc.bloom))
            }
        }
        var csv = "id,is3D,layers,effects,particles,texBytes,hdr,bloom\n"
        for r in rows.sorted(by: { $0.id < $1.id }) {
            csv += "\(r.id),\(r.is3D ? 1 : 0),\(r.layers),\(r.effects),\(r.particles),\(r.texBytes),\(r.hdr ? 1 : 0),\(r.bloom ? 1 : 0)\n"
        }
        do { try csv.write(to: outCSV, atomically: true, encoding: .utf8) }
        catch { fputs("[profile] inventory write failed: \(error)\n", stderr); return 2 }
        print("[profile inventory] scenes=\(rows.count) dropped=\(dropped.count)/\(folders.count) → \(outCSV.path)")
        return reportDrops(tag: "profile inventory", rows: rows.count, folders: folders.count, dropped: dropped)
    }

    // MARK: --vis-blast : W3-① C8 가시성 상속 전파의 코퍼스 블라스트 반경(파스만, 마운트 없음)

    struct VisBlastRow { let id: String; let layers: Int; let texts: Int; let particles: Int
                         var total: Int { layers + texts + particles } }

    /// 씬마다 SceneDocument.parse 를 WAPLE_VIS_INHERIT=0(끔)/기본(켬) 두 번 돌려, 켬 쪽에서
    /// initialVisible/visible 이 true→false 로 새로 마킹된 레이어/텍스트/파티클 수를 센다(드롭이 아니라
    /// 마킹이라 두 파스의 배열 길이/순서가 항상 같음 — index 로 zip 비교). CSV 는 영향 있는 씬만 기록.
    public static func runVisBlast(root: String, outCSV: URL) -> Int32 {
        let restore = SnapshotPipeline.pinRenderSettings(root: root)
        defer { restore() }
        let folders = SnapshotPipeline.sceneFolders(root: root)
        guard !folders.isEmpty else {
            fputs("[profile] ⚠️ 씬 0개 — root 지정 확인: \(root)\n", stderr); return 2
        }
        let rootURL = URL(fileURLWithPath: NSString(string: root).expandingTildeInPath, isDirectory: true).standardizedFileURL
        let assetsDir = DeepScan.firstExisting([rootURL.appendingPathComponent("assets"),
                                                rootURL.deletingLastPathComponent().appendingPathComponent("assets")])
        var rows: [VisBlastRow] = []
        var dropped: [String] = []
        var scanned = 0
        for folder in folders {
            let id = folder.lastPathComponent
            autoreleasepool {
                guard let pkg = mountPackage(folder) else { dropped.append("\(id): 마운트 실패"); return }
                let res = PkgAssets(package: pkg, assetsDir: assetsDir)
                let assetsFn: (String) -> Data? = { res.baseAssetURL($0).flatMap { try? Data(contentsOf: $0) } }
                setenv("WAPLE_VIS_INHERIT", "0", 1)
                guard let off = try? SceneDocument.parse(package: pkg, assets: assetsFn) else {
                    unsetenv("WAPLE_VIS_INHERIT"); dropped.append("\(id): 씬 파스 실패(off)"); return
                }
                unsetenv("WAPLE_VIS_INHERIT")
                guard let on = try? SceneDocument.parse(package: pkg, assets: assetsFn) else {
                    dropped.append("\(id): 씬 파스 실패(on)"); return
                }
                scanned += 1
                guard off.layers.count == on.layers.count, off.texts.count == on.texts.count,
                      off.particles.count == on.particles.count else {
                    fputs("[vis-blast] ⚠️ \(id): 두 파스 배열 길이 불일치(비결정 스킵)\n", stderr); return
                }
                // 종전 지표는 initialVisible 플립만 셌다 — 그건 **스크립트 없는** 자식만 잡는다.
                // 자기 visible 스크립트를 가진 자식은 initialVisible 이 시드일 뿐이라 마킹 대상이 아니고
                // hiddenByAncestor(런타임 하드 게이트)로 간다. 두 축을 다 세지 않으면 새 반경이 0 으로 보인다.
                var layersHidden = 0, textsHidden = 0, particlesHidden = 0
                for i in off.layers.indices
                where (off.layers[i].initialVisible && !on.layers[i].initialVisible)
                    || (!off.layers[i].hiddenByAncestor && on.layers[i].hiddenByAncestor) {
                    layersHidden += 1
                }
                for i in off.texts.indices
                where (off.texts[i].initialVisible && !on.texts[i].initialVisible)
                    || (!off.texts[i].hiddenByAncestor && on.texts[i].hiddenByAncestor) {
                    textsHidden += 1
                }
                for i in off.particles.indices
                where (off.particles[i].visible && !on.particles[i].visible)
                    || (!off.particles[i].hiddenByAncestor && on.particles[i].hiddenByAncestor) {
                    particlesHidden += 1
                }
                let row = VisBlastRow(id: id, layers: layersHidden, texts: textsHidden, particles: particlesHidden)
                if row.total > 0 { rows.append(row) }
            }
        }
        let sorted = rows.sorted { $0.total != $1.total ? $0.total > $1.total : $0.id < $1.id }
        var csv = "id,layersHidden,textsHidden,particlesHidden,total\n"
        for r in sorted { csv += "\(r.id),\(r.layers),\(r.texts),\(r.particles),\(r.total)\n" }
        do { try csv.write(to: outCSV, atomically: true, encoding: .utf8) }
        catch { fputs("[vis-blast] write failed: \(error)\n", stderr); return 2 }
        let totalObjects = sorted.reduce(0) { $0 + $1.total }
        let totalLayers = sorted.reduce(0) { $0 + $1.layers }
        let totalTexts = sorted.reduce(0) { $0 + $1.texts }
        let totalParticles = sorted.reduce(0) { $0 + $1.particles }
        // `scenes-scanned` 는 **실제로 두 번 파스한 수**다. 종전엔 `folders.count`(=열거된 폴더 수)를
        // 찍었는데, 전건 드롭이어도 그 수가 그대로 나와 "16개를 훑었고 영향 0" 처럼 읽혔다.
        print("[vis-blast] scenes-scanned=\(scanned)/\(folders.count) dropped=\(dropped.count) " +
              "scenes-affected=\(sorted.count) " +
              "objects-newly-hidden=\(totalObjects) (layers=\(totalLayers) texts=\(totalTexts) particles=\(totalParticles)) → \(outCSV.path)")
        print("[vis-blast] top 5: " + sorted.prefix(5).map { "\($0.id)(\($0.total))" }.joined(separator: ", "))
        return reportDrops(tag: "vis-blast", rows: scanned, folders: folders.count, dropped: dropped)
    }

    // MARK: --profile : 단일 씬 실측

    struct FormatAgg: Codable { var count = 0; var outBytes = 0; var inBytes = 0; var ms = 0.0 }
    struct ProfileResult: Codable {
        let id: String
        let layers: Int, effects: Int, particles: Int
        let is3D: Bool, hdr: Bool, bloom: Bool
        let totalMountColdMs: Double
        let totalMountWarmMs: Double?      // 재마운트(프로세스 내 2차 = Metal 컴파일러 웜)
        let phasesColdMs: [String: Double] // pkgRead/pkgParse/docParse/deviceInit/texDecode/glslTranslate/shaderCompile/pipelineCreate
        let phasesWarmMs: [String: Double]?
        let otherColdMs: Double            // totalMountCold − Σphases (계측 밖 잔여: 버퍼/JS/지오메트리)
        let firstFrameThumbMs: Double      // 마운트 후 첫 프레임까지(256×144, sim catch-up+encode+readback+PNG)
        // 텍스처
        let texDecodeMs: Double, texOutBytes: Int, texInBytes: Int, texCount: Int
        let texMaxSingleOutBytes: Int
        let texByFormat: [String: FormatAgg]
        let bcOutBytes: Int, bcInBytes: Int, bcDecodeMs: Double   // BC1/2/3 소계(네이티브 BC 대상)
        // 셰이더
        let shaderCompileCount: Int, shaderCompileMs: Double
        let glslTranslateCount: Int, glslTranslateMs: Double
        let pipelineCreateMs: Double
        let shaderUniqueSources: Int, shaderWithinSceneDupes: Int  // MSL 문자열 dedup(프로세스 내)
        let shaderHashes: [String]                                 // 프로세스 간 dedup 용(안정 해시, hex)
        // 파티클
        let particlePeakCount: Int, particleSteadyMsPerFrame: Double, particleStepCount: Int
        // 실해상도 프레임(프레임 예산 분모 — GPU 부분은 해상도 의존)
        let frameResW: Int, frameResH: Int, frameFullMs: Double
        // 메모리(델타 = 마운트 순증)
        let footBeforeBytes: Int, footAfterBytes: Int, footDeltaBytes: Int, deviceAllocBytes: Int
    }

    public static func runProfile(root: String, outDir: URL, only: String, remount: Bool, frameW: Int, frameH: Int) -> Int32 {
        let fm = FileManager.default
        try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        // F520: 개발 루트/backgrounds/단일 씬 디렉터리 직접 지정 모두 수용(sceneFolders 와 동일 해석).
        guard let folder = SnapshotPipeline.sceneFolders(root: root).first(where: { $0.lastPathComponent == only }) else {
            fputs("[profile] scene not found: \(only) (root: \(root))\n", stderr); return 2
        }
        let restore = SnapshotPipeline.pinRenderSettings(root: root)
        defer { restore() }
        // F148: PID 로 스코프(SnapshotPipeline.runCapture 와 동일 이유 — 동시 실행 간 캡처파일 충돌 방지).
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_profile_\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        // 메타(파스만, 계측 밖) — 카운트/분류.
        guard let project = try? ProjectJSONParser.parse(folderURL: folder) else {
            fputs("[profile] project parse failed: \(only)\n", stderr); return 2
        }
        // [2026-08-27] 이 자리만 `.pkg` 를 하드코딩하고 있었다. 이 파일 머리의 정정이 "마운트
        // 선택자를 렌더러·DeepScan 과 **같은 함수**로 맞춘다" 고 선언했는데 `mountPackage` 호출부는
        // runInventory·runVisBlast 둘뿐이었고 runProfile 만 빠져 있었다.
        //
        // 귀결이 컸다: `DeepScan.swift` 가 실측으로 기록한 대로 WE 2.8.42 설치본 씬은 **188/188 이
        // 언팩**이고 두 루트 전체에 `.pkg` 가 0개다. 폴더는 SnapshotPipeline.sceneFolders 가
        // 언팩 폴백으로 잘 찾아 주므로 `--profile` 은 **여기까지 와서** 죽었다 — 즉 이 모드가
        // 자기가 겨냥해 만들어진 코퍼스에서 전건 exit 2 였다. mpkg 는 layers/effects 카운트
        // 메타에만 쓰이고 실제 프로파일링은 아래 r.mount 가 하므로, 측정 가능한 상태인데도
        // 메타 파스에서 떨어진 것이다.
        //
        // 트립와이어도 못 잡았다 — scripts/spec/check_scene_mount_parity.py 의 감시 목록에
        // ProfilePipeline 이 없었다. 그쪽도 같이 넓힌다.
        guard let mpkg = mountPackage(folder) else {
            fputs("[profile] meta parse failed: \(only)\n", stderr); return 2
        }
        // F680: 메타 파스도 inventory 와 같은 공유 에셋 리졸버를 쓴다 — 없으면 models/util/*.json 참조
        // 레이어가 드롭되어 JSON 의 layers/effects 카운트가 실제보다 적게 나온다(동일 결함 클래스).
        let rootURL = URL(fileURLWithPath: NSString(string: root).expandingTildeInPath, isDirectory: true).standardizedFileURL
        let assetsDir = DeepScan.firstExisting([rootURL.appendingPathComponent("assets"),
                                                rootURL.deletingLastPathComponent().appendingPathComponent("assets")])
        let mres = PkgAssets(package: mpkg, assetsDir: assetsDir)
        guard let mdoc = try? SceneDocument.parse(
            package: mpkg,
            assets: { mres.baseAssetURL($0).flatMap { try? Data(contentsOf: $0) } }
        ) else {
            fputs("[profile] meta parse failed: \(only)\n", stderr); return 2
        }
        let is3D = mdoc.camera3D != nil && !mdoc.objects3D.isEmpty
        let effects = mdoc.layers.reduce(0) { $0 + $1.effects.count }

        // 메인 액터 전용 API. 이 CLI 는 파이프라인을 main.swift 최상위(메인 스레드)에서 동기로만
        // 돌린다(이 파일에 디스패치 없음) — SnapshotPipeline.captureFrame 과 같은 근거.
        let container = MainActor.assumeIsolated {
            NSView(frame: NSRect(x: 0, y: 0, width: SnapshotPipeline.thumbW, height: SnapshotPipeline.thumbH))
        }
        let r = SceneRenderer()
        // [2026-08-26] 포인터 핀은 이제 **인스턴스 소유**다. 종전에는 프로세스 전역
        // `SceneRenderer.capturePointerUV` 였고, 위 `pinRenderSettings`(:244)가 그것을 걸어 주었기
        // 때문에 여기서 아무것도 안 해도 이 인스턴스가 핀 상태로 태어났다. 전역을 없애면서 그
        // 경로가 끊겼다 — **그런데 이 파일은 전역 이름을 한 번도 쓰지 않아서 컴파일은 그대로
        // 통과하고 핀만 조용히 사라진다.** 이 리포가 특히 싫어하는 실패 모양이라 명시 대입으로 막는다.
        // 값은 캡처 경로와 같은 상수를 쓴다(SnapshotPipeline.capturePointerUV = 중앙 (0.5, 0.5)).
        r.capturePointerUV = SnapshotPipeline.capturePointerUV
        r.nowPlayingProvider = SnapshotPipeline.StoppedNowPlaying()

        // 콜드 마운트(#1) — Metal 컴파일러 콜드.
        let footBefore = physFootprint()
        WapleProfiler.reset(); WapleProfiler.enabled = true
        let m0 = CFAbsoluteTimeGetCurrent()
        do { try r.mount(in: container, project: project) }
        catch { WapleProfiler.enabled = false; fputs("[profile] mount FAILED \(only): \(error)\n", stderr); return 1 }
        let coldMountMs = (CFAbsoluteTimeGetCurrent() - m0) * 1000
        let footAfter = physFootprint()
        let deviceAlloc = WapleProfiler.deviceAllocatedBytes
        // 콜드 스냅샷.
        let phasesCold = WapleProfiler.phases
        let texRecs = WapleProfiler.texRecs
        let shaderHashes = WapleProfiler.shaderHashes
        let translateCount = Int(WapleProfiler.counters["translateCount"] ?? 0)

        r.pause(); r.setSpectrum(.silent)

        // 첫 프레임(썸네일) — sim catch-up 포함(파티클 스텝 채움, CPU sim 은 해상도 무관).
        let f0 = CFAbsoluteTimeGetCurrent()
        _ = r.captureFrames(width: SnapshotPipeline.thumbW, height: SnapshotPipeline.thumbH,
                            times: [SnapshotPipeline.captureT], toDir: tmp)
        let firstFrameMs = (CFAbsoluteTimeGetCurrent() - f0) * 1000
        let particleSteps = WapleProfiler.particleSteps   // 썸네일 프레임까지의 스텝

        // 실해상도 프레임(GPU 부분 = 해상도 의존 → 프레임 예산 분모).
        let ff0 = CFAbsoluteTimeGetCurrent()
        _ = r.captureFrames(width: frameW, height: frameH, times: [SnapshotPipeline.captureT], toDir: tmp)
        let frameFullMs = (CFAbsoluteTimeGetCurrent() - ff0) * 1000

        // 재마운트(웜) — 동일 프로세스 2차 마운트. teardown 은 mount 진입 시 자동.
        var warmMountMs: Double? = nil
        var phasesWarm: [String: Double]? = nil
        if remount {
            WapleProfiler.reset()   // enabled 유지
            let w0 = CFAbsoluteTimeGetCurrent()
            if (try? r.mount(in: container, project: project)) != nil {
                warmMountMs = (CFAbsoluteTimeGetCurrent() - w0) * 1000
                phasesWarm = WapleProfiler.phases
            }
        }
        r.teardown()
        WapleProfiler.enabled = false

        // 집계.
        var byFormat: [String: FormatAgg] = [:]
        var maxSingle = 0
        var bcOut = 0, bcIn = 0, bcMs = 0.0
        let bcFormats: Set<String> = ["bc1", "bc2", "bc3"]
        for t in texRecs {
            var a = byFormat[t.format] ?? FormatAgg()
            a.count += 1; a.outBytes += t.outBytes; a.inBytes += t.inBytes; a.ms += t.seconds * 1000
            byFormat[t.format] = a
            maxSingle = max(maxSingle, t.outBytes)
            if bcFormats.contains(t.format) { bcOut += t.outBytes; bcIn += t.inBytes; bcMs += t.seconds * 1000 }
        }
        let texOut = texRecs.reduce(0) { $0 + $1.outBytes }
        let texIn = texRecs.reduce(0) { $0 + $1.inBytes }
        let texMs = (phasesCold["texDecode"] ?? 0) * 1000

        // 파티클 정상상태: 피크 수 + 피크의 80% 이상 스텝 평균 ms(램프업 제외).
        let peak = particleSteps.map { $0.count }.max() ?? 0
        let steadyThresh = Int(Double(peak) * 0.8)
        let steady = particleSteps.filter { $0.count >= steadyThresh && $0.count > 0 }
        let steadyMs = steady.isEmpty ? 0 : steady.reduce(0.0) { $0 + $1.seconds } / Double(steady.count) * 1000

        let phasesColdMs = phasesCold.mapValues { $0 * 1000 }
        let sumPhases = phasesColdMs.values.reduce(0, +)

        let result = ProfileResult(
            id: only, layers: mdoc.layers.count, effects: effects, particles: mdoc.particles.count,
            is3D: is3D, hdr: mdoc.hdr, bloom: mdoc.bloom,
            totalMountColdMs: coldMountMs, totalMountWarmMs: warmMountMs,
            phasesColdMs: phasesColdMs, phasesWarmMs: phasesWarm?.mapValues { $0 * 1000 },
            otherColdMs: max(0, coldMountMs - sumPhases), firstFrameThumbMs: firstFrameMs,
            texDecodeMs: texMs, texOutBytes: texOut, texInBytes: texIn, texCount: texRecs.count,
            texMaxSingleOutBytes: maxSingle, texByFormat: byFormat,
            bcOutBytes: bcOut, bcInBytes: bcIn, bcDecodeMs: bcMs,
            shaderCompileCount: shaderHashes.count, shaderCompileMs: (phasesCold["shaderCompile"] ?? 0) * 1000,
            glslTranslateCount: translateCount, glslTranslateMs: (phasesCold["glslTranslate"] ?? 0) * 1000,
            pipelineCreateMs: (phasesCold["pipelineCreate"] ?? 0) * 1000,
            shaderUniqueSources: Set(shaderHashes).count,
            shaderWithinSceneDupes: shaderHashes.count - Set(shaderHashes).count,
            shaderHashes: shaderHashes.map { String($0, radix: 16) },
            particlePeakCount: peak, particleSteadyMsPerFrame: steadyMs, particleStepCount: particleSteps.count,
            frameResW: frameW, frameResH: frameH, frameFullMs: frameFullMs,
            footBeforeBytes: Int(footBefore), footAfterBytes: Int(footAfter),
            footDeltaBytes: Int(footAfter) - Int(footBefore), deviceAllocBytes: deviceAlloc)

        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try enc.encode(result)
            try data.write(to: outDir.appendingPathComponent("\(only).json"))
        } catch { fputs("[profile] write failed \(only): \(error)\n", stderr); return 2 }
        print("[profile] \(only)  mountCold=\(ms(coldMountMs)) warm=\(warmMountMs.map(ms) ?? "-")  tex=\(ms(texMs))/\(texRecs.count)  shader=\(ms((phasesCold["shaderCompile"] ?? 0)*1000))/\(shaderHashes.count)  mem+=\(mb(Int(footAfter)-Int(footBefore)))  part=\(peak)@\(ms(steadyMs))")
        return 0
    }

    private static func ms(_ v: Double) -> String { String(format: "%.1fms", v) }
    private static func mb(_ bytes: Int) -> String { String(format: "%.1fMB", Double(bytes) / (1024*1024)) }
}
