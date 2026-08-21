// `import Darwin` 대역 — `Sources/WapleCompatCore/ProfilePipeline.swift` 의 mach VM 질의 전용.
//
// 리눅스에는 `Darwin` 모듈이 없다. 여기 있는 것은 **타입과 시그니처뿐**이고 값은 전부 더미다 —
// 이 도구는 타입체크만 하므로 동작을 흉내 낼 필요가 없고, 흉내 내면 오히려 "리눅스에서 돌더라" 는
// 잘못된 인상을 준다.
//
// 실제 사용처(`ProfilePipeline.physFootprint()`):
//     var info = task_vm_info_data_t()
//     var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride
//                                        / MemoryLayout<natural_t>.stride)
//     let kr = withUnsafeMutablePointer(to: &info) { ptr in
//         ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
//             task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
//         }
//     }
//     return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
//
// 확신 없음: 실제 `task_vm_info_data_t` 는 필드가 30개가 넘는 C 구조체다. 여기서는 호출부가
// 읽는 `phys_footprint` 하나만 둔다 — **`MemoryLayout<...>.stride` 가 실물과 다르다.** 그래서
// 이 심으로는 `count` 산술의 정합을 검증할 수 없다(타입만 맞는다). 그 산술이 맞는지는
// macOS 실행만이 답한다.

// ⚠️ **`#if canImport(Darwin)` 을 뒤집는다.** 이 심이 `-I $MODS` 에 들어가 있으면 그 조건이
// 리눅스에서도 **참**이 된다. 지금은 `--compat` 대상(`Sources/WapleCompatCore/**` ·
// `Tests/WapleCompatCoreTests/**` · `Tests/WapleSnapshotTests/**` · `Tests/WapleRenderTests/**`)에
// `canImport(Darwin)` 을 쓰는 파일이 **0건**이라 무해하지만, 생기면 조용히 macOS 가지를
// 타입체크하게 된다(실행이 아니라 타입체크라 결과가 뒤집히지는 않지만, 검사 대상이 바뀐다).
// 참고로 `Tests/WapleCoreTests/AssetJSONLenientTests.swift` 가 그 조건을 쓰는데, 그 파일은
// `scripts/dev/linux-core-tests.sh` 의 임시 패키지에서 돌고 거기엔 이 심이 없다 — 그래서
// 리눅스 가지를 정상적으로 탄다. 두 하네스의 모듈 경로를 섞지 마라.

public typealias natural_t = UInt32
public typealias integer_t = Int32
public typealias mach_msg_type_number_t = UInt32
public typealias task_flavor_t = UInt32
public typealias task_t = UInt32
public typealias kern_return_t = Int32

public struct task_vm_info_data_t {
    public var phys_footprint: UInt64 = 0
    public init() {}
}

public let mach_task_self_: task_t = 0
public let TASK_VM_INFO: Int32 = 22
public let KERN_SUCCESS: kern_return_t = 0

public func task_info(_ target: task_t, _ flavor: task_flavor_t,
                      _ info: UnsafeMutablePointer<integer_t>?,
                      _ count: UnsafeMutablePointer<mach_msg_type_number_t>?) -> kern_return_t { 0 }
