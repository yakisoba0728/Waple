import Foundation

/// 파티클 **컨트롤 포인트(CP)** 의 순수 산술 — 저작값이 매 프레임 4×4 로 접히는 경로 전부.
///
/// 왜 `WapleCore` 에 있는가
/// -----------------------
/// CP 는 파티클이 세계(오브젝트 변환·마우스·부모 파티클)와 만나는 **유일한 통로**다.
/// 그런데 Waple 의 CP 는 지금 `ParticleSystem.parse` 가 로드 시 1회 `Vec3` 로 굽는 정적 값이고
/// (`bakeControlPointTargets`), 회전·공간 변환·마우스는 아예 없다. 그 공백을 메우려면 먼저
/// **산술이 값으로 잠겨** 있어야 한다 — 배선(`ParticleSimulator`/`SceneRenderer*`)은 소유가
/// 다르고 리눅스에서 실행 검증이 안 되기 때문이다. 그래서 산수만 여기 둔다.
/// `import simd` 를 쓰지 않는다(Foundation 만) — 리눅스 코어 테스트에서 그대로 돈다.
///
/// 근거
/// ----
/// `wallpaper64.exe`(imagebase `0x140000000`) 실측. 전문은 `docs/re/particle-control-points.md`.
/// **이 파일의 VA 는 전부 이 레인에서 `.pdata` 함수 시작부터 선형으로 다시 떠서 확인했다**
/// (방법론 함정 14·15 — 남의 VA 를 베끼지 않았고 거꾸로 뜨지 않았다).
///
/// 이 파일이 **하지 않는** 것
/// -------------------------
/// - json 파스(그건 `ParticleSystem.swift` 의 몫이다).
/// - 시뮬 배선(그건 `ParticleSimulator.swift` 의 몫이다).
/// 여기 있는 것은 전부 **입력 → 출력**이 닫힌 함수다.

// MARK: - 한계

/// CP 슬롯의 하드 상한과 인덱스 규약.
public enum ParticleControlPointLimits {

    /// **[확정] CP 슬롯은 8개가 상한이다.** 근거 셋이 같은 수를 준다:
    ///
    /// 1. 파티클 `.json` 파서가 CP 디스크립터 배열을 **`0x100` 바이트로 0-메모리셋**한다 —
    ///    `lea rcx, [r13 + 0xa4]` / `xor edx, edx` / `mov r8d, 0x100` / `call 0x1404217a0`
    ///    (`0x1401c5490`–`0x1401d152c` 대형 팩토리 안 — `merged()` 로 9조각을 병합한 범위다.
    ///    메모리셋 자리 `0x1401d04d8`–`0x1401d04e7`).
    ///    `0x100 / 0x20`(슬롯 스트라이드) = **8**.
    /// 2. 그 뒤 파스 루프가 **고정 8회**다 — `inc r14d` / `cmp r14d, 8` / `jl`
    ///    (`0x1401d0807`–`0x1401d080e`). 배열 길이를 읽지 않고 `operator[](i)` 를 8번 부른 뒤
    ///    태그 7(object)이 아니면 그 자리를 건너뛴다(`cmp byte ptr [rax + 8], 7` @`0x1401d053e`).
    ///    → **9번째 이후 원소는 파스 자체가 안 된다.**
    /// 3. 씬 프로퍼티백 등록부가 `controlpoint0..7` + `controlpointangle0..7` **정확히 16개**를
    ///    등록한다. 이미지의 `controlpoint`/`controlpointangle` 접두 문자열을 전수로 뽑으면
    ///    `controlpoint0`(`0x140491408`) … `controlpoint7`(`0x1404914f8`) ·
    ///    `controlpointangle0`(`0x140491490`) … `controlpointangle7`(`0x140491508`) 뿐이고,
    ///    `controlpoint8` 도 `controlpointangle8` 도 **없다**.
    ///
    /// **코퍼스 확인**: 동봉 `WEAssets` 1,698 `.json` 중 `controlpoint[]` 를 가진 245파일의
    /// 배열 길이 분포는 `8`×220 · `2`×19 · `3`×6 이고 **최댓값이 8**이다(설치본 2,143 중에서도
    /// `8`×225 · `2`×19 · `3`×6). 즉 상한을 넘는 저작은 두 코퍼스에 **0건**이다.
    public static let slotCount = 8

    /// 디스크립터 슬롯 스트라이드(바이트). 파서가 `shl rdi, 5`(`0x1401d0593`)로 만든다.
    public static let descriptorStride = 0x20

    /// 런타임 CP 레코드 스트라이드(바이트). 인덱싱은 언제나 `imul rXX, idx, 0xd0` 다.
    public static let recordStride = 0xD0

    /// **[확정] CP 인덱스 클램프는 부호 **없는** 비교다** — `mov edx, 7` / `cmp ecx, edx` /
    /// `cmovb edx, ecx`. 즉 **음수는 0 이 아니라 7 이 된다**.
    /// 실물 자리(이 레인에서 직접 확인): `remapvalue` 의 `inputcontrolpoint0`/`outputcontrolpoint0`
    /// `0x1401cef35`–`0x1401cef4f`, `inputcontrolpoint1`/`outputcontrolpoint1`
    /// `0x1401cefff`–`0x1401cf019`.
    public static func clampIndex(_ raw: Int) -> Int {
        // 엔진은 `ecx` 의 하위 32비트만 본다 — 그래서 **절단 뒤** 부호 없는 비교다.
        // 32비트로 접은 값이 음수면 `cmovb` 가 안 걸려 7 이 남는다.
        let low = Int(Int32(truncatingIfNeeded: raw))
        return (0..<7).contains(low) ? low : 7
    }

    /// 파스 루프가 실제로 채우는 슬롯인가(`0 ..< 8`).
    public static func acceptsSlot(_ slot: Int) -> Bool { slot >= 0 && slot < slotCount }
}

// MARK: - 플래그

/// `controlpoint[].flags` 의 비트. **런타임이 읽는 비트는 다섯이다** — bit0·bit1·bit2·bit3·bit16.
///
/// > **정정.** `docs/re/particle-control-points.md` §8.3 은 "런타임이 읽는 비트는
/// > bit0·bit2·bit3·bit16 뿐" 이라고 적는데 **bit1 이 빠졌다**. bit1 은 두 자리에서 읽힌다 —
/// > 기본 갱신 `0x14022a08c`(`and r9d, 2`)와 이니셜라이저 opid 8 `0x14023bc9c`
/// > (`test byte ptr [rbx + 0xc0], 2`). 같은 문서 §1·§2.3 은 bit1 을 제대로 적고 있어서
/// > **문서가 자기 자신과 모순**이었다(방법론 함정 20 의 정본 판).
public enum ParticleControlPointFlag {

    /// bit0 — **마우스 구동**. 매 프레임 base 를 cur 로 복사한 뒤 **평행이동 행만**
    /// 포인터 역투영점으로 덮는다(`0x14022e472` 게이트 → 스토어 `0x14022e656`–`0x14022e662`).
    /// 회전 3행은 base 그대로 남는다.
    ///
    /// **동봉 도달 28 CP 원소 / 1,816**(설치본도 28 / 1,856). 파일로는 `examplecursorfollow` ·
    /// `examplecursoravoid` · `presets/interactive/trail_0..2` · `fireflies` · `bubbles1` ·
    /// `vapor0/1` · `powerup` · `dust_motes_0` · `dna` 등.
    public static let pointerDriven = 0x1

    /// bit1 — **이 CP 의 `offset` 은 월드 좌표다**(로컬이 아니다).
    ///
    /// **[확정, 이 레인 신규]** 기본 갱신 `0x14022a070`–`0x14022a117` 를 전수로 뜨면 네 갈래다:
    /// ```
    /// 0x14022a08c  r9d = cp.flags & 2
    /// 0x14022a097  je  A                       ; bit1 없음
    /// 0x14022a099  test edx, edx ; je A        ; idx == 0 이면 A 로 (아래 예외)
    ///              jmp B
    /// A: 0x14022a0a3 test byte ptr [rcx + 0x20], 1   ; 시스템 flags bit0 = worldspace
    ///    0x14022a0ab je  C
    ///    0x14022a0bc call 0x14024f0e0(dst, rdx = 오브젝트 월드 4×4, r8 = base)
    ///    0x14022a0c4  cur = base × objectWorld ; return true
    /// C: 0x14022a0ea test r9d, r9d ; je 0x14022a10d(return false)
    /// B: 0x14022a0ef test byte ptr [rax], 1 ; jne 0x14022a10d(return false)   ; rax = sys + 0x20
    ///    0x14022a0fc call 0x1402290d0(rcx = 오브젝트 월드, rdx = out)   ; 4×4 역행렬
    ///    0x14022a10b jmp 0x14022a0b5           ; cur = base × inverse(objectWorld)
    /// ```
    /// 정리하면 **시스템 공간과 CP 공간이 어긋날 때만 변환한다**:
    /// | 시스템 worldspace | CP bit1 | 결과 |
    /// | --- | --- | --- |
    /// | 예 | 아니오 | `cur = base × objectWorld` (로컬 → 월드) |
    /// | 예 | 예 | **갱신 없음**(둘 다 월드) |
    /// | 아니오 | 예 | `cur = base × inverse(objectWorld)` (월드 → 로컬) |
    /// | 아니오 | 아니오 | **갱신 없음**(둘 다 로컬) |
    ///
    /// `0x1402290d0` 이 역행렬인 근거: `0x1402290e2`부터 `[rcx]`/`[rcx+0x10]`/`[rcx+0x20]`/
    /// `[rcx+0x30]` 네 행을 `shufps` 로 섞어 여인수(adjugate)를 만들고 행렬식으로 나누는
    /// 고전 SSE 4×4 역행렬 코드다.
    ///
    /// **예외 하나**: `idx == 0` 이면 bit1 이 서 있어도 A 로 간다(`test edx, edx` @`0x14022a099`).
    /// 즉 슬롯 0 의 bit1 은 worldspace 시스템에서 무시된다. **동봉·설치 도달 0** — bit1 저작
    /// 10건이 전부 `idx == 1` 이다.
    ///
    /// **동봉 도달 10 CP 원소 / 1,816**: `discharge` · `dischargearc`(×3) · `thunderbolt`(×2) ·
    /// `water_faucet`(×2) · `water_faucet_large`(×2). 앞 6건은 시스템 `flags: 0` 이라
    /// `base × inverse(objectWorld)`, 뒤 4건은 시스템 `flags: 1` 이라 **갱신 없음**이다.
    public static let worldAuthored = 0x2

    /// bit2 — **부모 시스템의 CP 에 부착**. `cp.parentControlPoint` 를 부모 CP 배열의 인덱스로
    /// 쓴다(`0x14022e684` `mov eax, dword ptr [rsi + rdi + 0xc4]`, 경계검사
    /// `cmp dword ptr [r8 + 0x44], eax` / `jbe` @`0x14022e68b`).
    ///
    /// **동봉 도달 7 CP 원소 / 1,816.** 주의 — `parentcontrolpoint` **키** 자체는 108 원소가
    /// 저작하지만 bit2 가 서는 것은 7뿐이다. 즉 **101 원소의 `parentcontrolpoint` 는 죽은 값**이다.
    public static let parentAttached = 0x4

    /// bit3 — 부모 부착 시 **부모 4×4 를 통째로 복사**(합성하지 않음).
    /// 실물 조건은 OR 다 — `(자식 worldspace && 부모 worldspace) || (cp.flags & 8)`
    /// (`0x14022e69c`–`0x14022e6b6`). 참이면 `0x14022e6b8`–`0x14022e6d9` 가 네 행을 그대로 옮긴다.
    /// **동봉·설치 도달 0**(bit3 저작 0건).
    public static let parentCopyWholesale = 0x8

    /// bit16 — **remap 출력 CP**. 마스터 갱신이 이 CP 를 **아무것도 하지 않고 건너뛴다**
    /// (`bt edx, 0x10` / `jb` @`0x14022e468`–`0x14022e46c`) — 값은 오퍼레이터가 직접 쓴다.
    ///
    /// **[확정, 이 레인 신규] 이 비트는 저작 키가 아니라 파서가 세운다.**
    /// ```
    /// 0x1401d0860  mov  ecx, dword ptr [rbx + 0x10]     ; 수집된 출력 CP id
    /// 0x1401d0863  cmp  ecx, 8 ; jae 0x1401d0878        ; 8 이상은 무시
    /// 0x1401d0868  shl  rcx, 5
    /// 0x1401d086c  or   dword ptr [rcx + r13 + 0xa4], 0x10000
    /// ```
    /// 수집은 `remapvalue`(`0x1401cf05d`–`0x1401cf07e`)와
    /// `remapinitialvalue`(`0x1401cafc2`–`0x1401cafe0`)에서 일어나고, 게이트가
    /// `0x1401bc470`(`cmp ecx, 0x10` / `sete al`)이다 — **출력 채널이 `controlpoint`(표 인덱스 16)
    /// 일 때만** 넣는다. 넣는 값은 `outputcontrolpoint0`(`[rsi + 0xe4]`, ≤7 클램프)다.
    ///
    /// (형제 술어 `0x1401bc480` 은 `{7, 8} ∪ {16, 17, 18}` 을 참으로 준다 —
    /// `distancetocontrolpoint` · `positionbetweentwocontrolpoints` · `controlpoint` ·
    /// `deltatocontrolpoint` · `directiontocontrolpoint`. 그쪽은 **CP 개수 상향**용이다.)
    ///
    /// **동봉·설치 도달 0** — 두 코퍼스에서 `output` 이 `"controlpoint"` 인 `remapvalue`/
    /// `remapinitialvalue` 는 **0건**이고(관측된 값은 `color`·`opacity`·`velocity`·`speed`),
    /// `outputcontrolpoint0/1` 키 저작도 **0건**이다.
    public static let remapOutput = 0x1_0000

    /// 씬 `instanceoverride.controlpointN`/`controlpointangleN` 을 **통째로 무시**하는 마스크.
    /// `test dword ptr [rdi + rbx + 0xc0], 0x10005` / `jne` (`0x14022bf26`–`0x14022bf31`).
    /// = bit0 | bit2 | bit16.
    public static let overrideBlockMask = 0x1_0005
}

// MARK: - 4×4

/// CP 가 다루는 4×4. **행 우선(row-major) · 행벡터 규약**이다 — `p' = p · M`, 행 3 이 평행이동.
///
/// **[확정] 규약을 값으로 판정했다**(방법론 함정 12 — 레이아웃만으로는 못 가른다).
/// 마우스 CP 가 점을 변환하는 자리(`0x14022e5b8`–`0x14022e643`)가
/// `out = u·row0 + v·row1 + 0·row2 + row3` 를 성분별로 펼쳐 놓는다. 곱셈기
/// `0x14024f0e0`(`0x14024f191`–`0x14024f210`)도 `dst.row0 = A[0][0]·B.row0 + A[0][1]·B.row1 + …`
/// 로 같은 규약이다.
public struct CPMatrix4: Equatable {
    /// 16개 성분, 행 우선(`m[row * 4 + col]`).
    public var m: [Float]

    public init(_ values: [Float]) {
        precondition(values.count == 16, "CPMatrix4 는 성분 16개다")
        self.m = values
    }

    public static let identity = CPMatrix4([1, 0, 0, 0,
                                            0, 1, 0, 0,
                                            0, 0, 1, 0,
                                            0, 0, 0, 1])

    public subscript(row: Int, col: Int) -> Float {
        get { m[row * 4 + col] }
        set { m[row * 4 + col] = newValue }
    }

    /// 행 3 의 xyz. 실물은 `Matrix::row(3)`(`0x140255cf0`, `rax = rcx + idx * 16`)로 꺼낸다.
    public var translation: Vec3 { Vec3(x: m[12], y: m[13], z: m[14]) }

    /// `self × rhs`. 실물 `0x14024f0e0(rcx = dst, rdx = rhs, r8 = self)` 와 같은 순서다.
    public func multiplied(by rhs: CPMatrix4) -> CPMatrix4 {
        var out = [Float](repeating: 0, count: 16)
        for i in 0..<4 {
            for j in 0..<4 {
                var acc: Float = 0
                for k in 0..<4 { acc += m[i * 4 + k] * rhs.m[k * 4 + j] }
                out[i * 4 + j] = acc
            }
        }
        return CPMatrix4(out)
    }
}

// MARK: - 디스크립터

/// 파티클 `.json` `controlpoint[]` 원소 하나가 디스크립터에 남기는 것 전부.
///
/// **[확정] 파서가 읽는 키는 넷이다** — `offset` · `flags` · `parentcontrolpoint` · `angles`.
/// `"id"` 는 **한 번도 참조되지 않는다**(슬롯은 배열 위치다 — `shl rdi, 5` @`0x1401d0593`).
/// `"locktopointer"` 도 소비자가 없다(아래 `pointerLockKeyIsDead`).
///
/// **기본값은 전부 0 이다.** 파서가 슬롯 배열을 통째로 0-메모리셋하고(`0x1401d04d8`) 시작하며,
/// 태그 검사에 걸린 키는 **저장을 건너뛸 뿐**이라 그 0 이 남는다(방법론 함정 13).
/// 구체적으로 `offset`/`angles` 는 **문자열일 때만**(`cmp byte ptr [rax + 8], 4`
/// @`0x1401d05c5` · `0x1401d06da`) 저장되므로 `"offset": null` 은 `(0,0,0)` 이 된다 —
/// 동봉 `thunderbolt_fizzle.json` 이 실제로 그렇게 저작돼 있다.
public struct ParticleControlPointDescriptor: Equatable {
    /// `flags` — 주입기 `0x1401d8280`(기본 0) 뒤 `asInt`(`0x140085f70`) → `[rdi + r13 + 0xa4]`.
    public var flags: Int
    /// `parentcontrolpoint` — 주입기 `0x1401d8280`(기본 0) 뒤 `asInt` → `[rdi + r13 + 0xa8]`
    /// (`0x1401d07ff`).
    public var parentControlPoint: Int
    /// `offset` — 주입기 `H_STRING`(`0x1401d7e80`, 기본 `"0 0 0"`) 뒤 `strtod` ×3 →
    /// `[rdi + r13 + 0xac/0xb0/0xb4]`(`0x1401d06ac` · `0x1401d06bc`).
    public var offset: Vec3
    /// `angles` — **주입기가 없다**(부재면 널 노드 → 태그 4 검사 실패 → 0 유지).
    /// 저장은 `[rdi + r13 + 0xb8/0xbc/0xc0]`(`0x1401d07c9` · `0x1401d07d9`).
    /// **[확정] 그런데 이 12바이트를 읽는 자리는 없다** — 아래 `particleAnglesAreInert` 참조.
    public var angles: Vec3

    public init(flags: Int = 0,
                parentControlPoint: Int = 0,
                offset: Vec3 = Vec3(x: 0, y: 0, z: 0),
                angles: Vec3 = Vec3(x: 0, y: 0, z: 0)) {
        self.flags = flags
        self.parentControlPoint = parentControlPoint
        self.offset = offset
        self.angles = angles
    }
}

// MARK: - 산술

public enum ParticleControlPointMath {

    // MARK: 저작 → base 4×4

    /// **[확정] 파티클 `.json` 의 `controlpoint[].angles` 는 base 행렬에 안 실린다.**
    ///
    /// 시스템 생성자 `0x14022c3c0`–`0x14022cf93` 의 CP 루프(`0x14022cdc0`–`0x14022cf55`)를
    /// 전수로 뜨면 디스크립터에서 읽는 것은 넷뿐이다 —
    /// `+0xbc`(flags, `0x14022cddc`) · `+0xc0`(parent, `0x14022cdec`) ·
    /// `+0xc4/0xc8/0xcc`(offset, `0x14022cea9`/`0x14022ceb9`/`0x14022cec9`).
    /// 생성자 베이스는 파서 베이스보다 `0x18` 크므로 `angles`(파서 `+0xb8`)는 생성자 공간
    /// `+0xd0` 인데 **그 자리를 읽는 명령이 루프 안에 없다**. 회전 3행에는 항등이 들어간다
    /// (`0x14022ce42`/`0x14022ce59`/`0x14022ce68`/`0x14022ce82` 가 `+0x40..0x7f` 의 항등
    /// 네 행을 `+0x80/+0x90/+0xa0/+0xb0` 에 그대로 옮긴다).
    ///
    /// **전수 반증은 못 했지만 그물은 좁혔다**: 디스크립터를 읽으려면 스트라이드 `0x20` 인덱싱이
    /// 필요한데, 이미지 전체에서 `REX.W shl reg, 5` 는 424자리 · 139함수이고 그중 CP 디스크립터
    /// 베이스를 쓰는 함수는 **파서(`0x1401d0593` · `0x1401d0868`)와 생성자(`0x14022cdd8`)
    /// 셋뿐**이다(`imul reg, reg, 0x20` 은 이미지 전체 0자리). 8슬롯을 언롤한 상수 접근은
    /// 배제하지 못한다.
    ///
    /// **도달**: 동봉 1,816 CP 원소 · 설치본 1,856 원소 중 `angles` 저작 **0건**. 즉 실효 0.
    public static let particleAnglesAreInert = true

    /// **[확정] `controlpoint[].locktopointer` 는 죽은 키다.**
    /// WE 설치본 전체에서 `.json` 이 아닌 파일 **3,995개**를 ASCII·UTF-16LE·대소문자 무시로
    /// 훑어 `locktopointer` 히트 **0건**(방법론 함정 8·11 — 바이너리 하나로 판단하지 않았다).
    /// 문자열은 오직 자산 `.json` 2파일에만 있다(`particles/exampleturbolence.json` ·
    /// `particles/exampleturbolence3d.json`, 합 16원소).
    ///
    /// **그래서 관측 가능한 갈림이 하나 있다**: `exampleturbolence3d.json` 의 CP 1 은
    /// `locktopointer: true` 인데 `flags: 0` 이다 → 실물은 **마우스를 안 따라간다**.
    /// (형제 `exampleturbolence.json` 의 CP 1 은 `flags: 1` 이라 따라간다.)
    public static let pointerLockKeyIsDead = true

    /// 생성자가 만드는 base 4×4 — **회전은 항등, 평행이동은 `offset`**.
    /// `+0xbc` 성분(행3 의 w)은 항등에서 온 `1` 이다(`0x14022ce82` 가 항등 행3 을 통째로 옮긴다).
    public static func authoredBase(offset: Vec3) -> CPMatrix4 {
        var base = CPMatrix4.identity
        base[3, 0] = offset.x
        base[3, 1] = offset.y
        base[3, 2] = offset.z
        return base
    }

    /// 씬 `controlpointangleN`(라디안, 파일 순서 `(x, y, z)`)이 만드는 3×3.
    ///
    /// **[확정] 스토어 순서까지 그대로 옮겼다.** `0x14022bf53`–`0x14022c069`:
    /// `cosf`(`0x14041a2e0`) · `sinf`(`0x14041a9c0`)를 z → y → x 순으로 부르고
    /// (`xmm6 ← angles.z` @`0x14022bf53`, `xmm6 ← angles.y` @`0x14022bf71`,
    ///  `xmm0 ← angles.x` @`0x14022bf95`), 부호 반전은 `xorps xmm1, xmm14` @`0x14022bfe1`
    /// (`xmm14 = -0.0`, 적재 `0x14022bed8` ← `0x140492ff0`).
    /// ```
    /// +0x80 = cos(y)cos(z)                    +0x84 = cos(y)sin(z)                    +0x88 = -sin(y)
    /// +0x90 = sin(x)sin(y)cos(z)-cos(x)sin(z) +0x94 = sin(x)sin(y)sin(z)+cos(x)cos(z) +0x98 = sin(x)cos(y)
    /// +0xa0 = cos(x)sin(y)cos(z)+sin(x)sin(z) +0xa4 = cos(x)sin(y)sin(z)-sin(x)cos(z) +0xa8 = cos(x)cos(y)
    /// ```
    /// 행벡터 규약에서 이것은 `Rx · Ry · Rz` 다(열벡터로 읽으면 `Rz · Ry · Rx` — 같은 행렬).
    /// w 성분(`+0x8c`/`+0x9c`/`+0xac`)은 **쓰이지 않아** 항등의 0 이 남는다.
    public static func rotation(angles: Vec3) -> CPMatrix4 {
        let ca = cosf(angles.x), sa = sinf(angles.x)
        let cb = cosf(angles.y), sb = sinf(angles.y)
        let cc = cosf(angles.z), sc = sinf(angles.z)
        var out = CPMatrix4.identity
        out[0, 0] = cb * cc
        out[0, 1] = cb * sc
        out[0, 2] = -sb
        out[1, 0] = sa * sb * cc - ca * sc
        out[1, 1] = sa * sb * sc + ca * cc
        out[1, 2] = sa * cb
        out[2, 0] = ca * sb * cc + sa * sc
        out[2, 1] = ca * sb * sc - sa * cc
        out[2, 2] = ca * cb
        return out
    }

    /// 회전 + 평행이동을 합친 base(= 씬 오버라이드가 각도와 위치를 **둘 다** 지정했을 때의 모습).
    public static func baseMatrix(offset: Vec3, angles: Vec3) -> CPMatrix4 {
        var base = rotation(angles: angles)
        base[3, 0] = offset.x
        base[3, 1] = offset.y
        base[3, 2] = offset.z
        return base
    }

    // MARK: 씬 instanceoverride

    /// "지정 안 됨" 센티널 — 프로퍼티백 생성자 `0x14024d760`–`0x14024d8c6` 가 16개 vec3 슬롯의
    /// **`.x` 만** 이 값으로 깐다. 비교는 `ucomiss` 라 **NaN 은 "지정됨"** 으로 취급된다
    /// (`jp` 가 같음 분기를 건너뛴다 — `0x14022bf4b` · `0x14022c081`).
    public static let unspecified = Float.greatestFiniteMagnitude   // 0x7f7fffff

    /// `ucomiss x, FLT_MAX` + `jp`/`je` 규약. NaN 은 **미지정이 아니다**.
    public static func isUnspecified(_ value: Float) -> Bool {
        !value.isNaN && value == unspecified
    }

    /// 씬 `instanceoverride.controlpointN` / `controlpointangleN` 을 base 에 반영한 결과.
    public struct InstanceOverrideOutcome: Equatable {
        /// 반영 뒤 base 4×4.
        public var base: CPMatrix4
        /// 각도가 지정돼 3×3 을 덮었는가(`0x14022bf47` 검사 통과).
        public var wroteRotation: Bool
        /// 위치가 지정돼 평행이동을 덮었는가(`0x14022c07d` 검사 통과).
        public var wroteTranslation: Bool
        /// 이 CP 는 통째로 건너뛴다 — 게이트에 걸렸거나 둘 다 미지정이라 재합성도 안 한다.
        public var skipped: Bool
    }

    /// **[확정] 절대 대체다**(합산 아님) — 스토어가 전부 `movss`/`mov` 다.
    /// 두 센티널 검사가 **독립**이라 "각도만" · "위치만" 지정이 가능하고, 둘 다 미지정이면
    /// `test cl, cl` / `je`(`0x14022c085`–`0x14022c087`)로 이 CP 를 통째로 건너뛴다.
    ///
    /// `flags & 0x10005` 는 그보다 먼저 걸린다(`0x14022bf26`) — 위치도 각도도 안 본다.
    ///
    /// **동봉 도달**: `objects[].instanceoverride` 기준 `controlpoint1` 34 · `controlpoint2` 22 ·
    /// `controlpointangle1` 6 · `controlpointangle2` 1 (설치본 동일).
    /// `variants[].objects[]` 까지 세면 `controlpoint1` +2 · `controlpoint2` +2 ·
    /// `controlpointangle1` +5 · `controlpointangle2` +2 — `SceneDocument` 는 `variants[]` 를
    /// 파스하지 않으므로 그쪽은 현재 도달 밖이다.
    /// **`controlpoint0`/`controlpointangle0` 저작은 두 코퍼스 모두 0건이다.**
    public static func applyInstanceOverride(base: CPMatrix4,
                                             flags: Int,
                                             overrideAngles: Vec3,
                                             overrideTranslation: Vec3) -> InstanceOverrideOutcome {
        if flags & ParticleControlPointFlag.overrideBlockMask != 0 {
            return InstanceOverrideOutcome(base: base, wroteRotation: false,
                                           wroteTranslation: false, skipped: true)
        }
        var out = base
        var wroteRotation = false
        if !isUnspecified(overrideAngles.x) {
            let r = rotation(angles: overrideAngles)
            for row in 0..<3 {
                for col in 0..<3 { out[row, col] = r[row, col] }
            }
            wroteRotation = true
        }
        var wroteTranslation = false
        if !isUnspecified(overrideTranslation.x) {
            out[3, 0] = overrideTranslation.x
            out[3, 1] = overrideTranslation.y
            out[3, 2] = overrideTranslation.z
            wroteTranslation = true
        }
        if !wroteRotation && !wroteTranslation {
            return InstanceOverrideOutcome(base: base, wroteRotation: false,
                                           wroteTranslation: false, skipped: true)
        }
        return InstanceOverrideOutcome(base: out, wroteRotation: wroteRotation,
                                       wroteTranslation: wroteTranslation, skipped: false)
    }

    // MARK: 매 프레임 갱신

    /// 마스터 CP 갱신 `0x14022e3e0`–`0x14022ebde` 가 CP 하나에 대해 고르는 갈래.
    public enum FrameUpdate: Equatable {
        /// bit16 — 손대지 않는다(오퍼레이터가 직접 쓴다). `0x14022e468`.
        case untouched
        /// bit0 — base → cur 복사 뒤 평행이동만 포인터 역투영점으로. `0x14022e472`.
        case pointer
        /// bit2 — 부모 CP 의 현재 4×4 를 통째로 복사. `0x14022e6b8`.
        case parentCopy
        /// bit2 — `cur = parentCur × M`. `0x14022e6ee`–`0x14022e81b`.
        case parentCompose
        /// bit2 인데 부모 시스템이 없거나 인덱스가 범위 밖 — 아무것도 안 한다. `0x14022e67e`/`0x14022e68f`.
        case parentUnavailable
        /// 부모 파티클이 이 슬롯을 먹인다 — 엔진은 기본 갱신을 **건너뛴다**. `0x14022eb47`.
        case fedByParentParticles
        /// 기본 경로 — `cur = base × objectWorld`.
        case composeWithObject
        /// 기본 경로 — `cur = base × inverse(objectWorld)`(CP bit1, 시스템 로컬).
        case composeWithInverseObject
        /// 기본 경로 — 갱신 없음(공간이 이미 맞다). `0x14022a10d`.
        case keepCurrent
    }

    /// CP 하나의 이번 프레임 갈래를 고른다. 인자는 전부 실물이 그 자리에서 읽는 값이다.
    ///
    /// - `childFeedEnabled`: `[sys + 0x3f6] & 1` — 자식 링크 `flags & 1` 이 선 시스템에만 켜진다
    ///   (`or byte ptr [rax + 0x3f6], 1` @`0x14022ccd1`).
    /// - `childFeedStartIndex`: `[sys + 0x3f5]` = `children[].controlpointstartindex`
    ///   (`0x14022cce3`–`0x14022cce7`).
    public static func frameUpdate(cpFlags: Int,
                                   index: Int,
                                   parentControlPoint: Int,
                                   parentControlPointCount: Int,
                                   hasParentSystem: Bool,
                                   systemSimulatesInWorldSpace: Bool,
                                   parentSimulatesInWorldSpace: Bool,
                                   childFeedEnabled: Bool,
                                   childFeedStartIndex: Int) -> FrameUpdate {
        if cpFlags & ParticleControlPointFlag.remapOutput != 0 { return .untouched }
        if cpFlags & ParticleControlPointFlag.pointerDriven != 0 { return .pointer }
        if cpFlags & ParticleControlPointFlag.parentAttached != 0 {
            guard hasParentSystem else { return .parentUnavailable }
            // `cmp dword ptr [r8 + 0x44], eax` / `jbe` — 부호 없는 비교라 음수도 탈락한다.
            let idx = Int(Int32(truncatingIfNeeded: parentControlPoint))
            guard idx >= 0, idx < parentControlPointCount else { return .parentUnavailable }
            let wholesale = (systemSimulatesInWorldSpace && parentSimulatesInWorldSpace)
                || (cpFlags & ParticleControlPointFlag.parentCopyWholesale != 0)
            return wholesale ? .parentCopy : .parentCompose
        }
        if childFeedEnabled && index >= childFeedStartIndex { return .fedByParentParticles }
        let worldAuthored = cpFlags & ParticleControlPointFlag.worldAuthored != 0
        // `test edx, edx` @0x14022a099 — 슬롯 0 의 bit1 은 A 갈래로 빠진다.
        if worldAuthored && index != 0 {
            return systemSimulatesInWorldSpace ? .keepCurrent : .composeWithInverseObject
        }
        if systemSimulatesInWorldSpace { return .composeWithObject }
        return worldAuthored ? .composeWithInverseObject : .keepCurrent
    }

    // MARK: 마우스

    /// 포인터를 NDC 로 바꾼다 — `x' = 2x − 1`, `y' = 1 − 2y`.
    /// `0x14022e4ba`–`0x14022e53f`: `xmm8 = [ctx + 0x8c]`(정규화 x) · `xmm7 = 1.0 − [ctx + 0x90]`,
    /// 각각 `addss` 자기자신(×2) 뒤 `subss xmm13`(= 1.0, 적재 `0x14022e41f` ← `0x140492704`).
    public static func pointerNDC(_ pointer: Vec2) -> Vec2 {
        Vec2(x: 2 * pointer.x - 1, y: 1 - 2 * pointer.y)
    }

    /// NDC 를 `inverse(viewProjection)` 으로 역투영한 **평면 위 점의 x, y**.
    ///
    /// **[확정] z 는 계산되지 않는다.** 실물은 NDC z 자리에 `xmm12 = 0`(`xorps` @`0x14022e413`)을
    /// 넣고 `x/w`, `y/w` **둘만** 나눈다(`divss xmm9, xmm6` / `divss xmm10, xmm6`
    /// @`0x14022e597`–`0x14022e59c`). z 성분 `+0x28`/`+0x38`/… 는 이 단계에서 안 읽힌다.
    public static func pointerPlanePoint(pointer: Vec2, inverseViewProjection m: CPMatrix4) -> Vec2 {
        let n = pointerNDC(pointer)
        let x = n.x * m[0, 0] + n.y * m[1, 0] + m[3, 0]
        let y = n.x * m[0, 1] + n.y * m[1, 1] + m[3, 1]
        let w = n.x * m[0, 3] + n.y * m[1, 3] + m[3, 3]
        return Vec2(x: x / w, y: y / w)
    }

    /// 마우스 구동 CP 의 이번 프레임 **평행이동 행**.
    ///
    /// - 시스템이 worldspace 면 `(u, v, 0)` 을 그대로 쓴다(`0x14022e64a`–`0x14022e652`:
    ///   `xmm7 = xmm10`, `xmm6 = xmm9`, `xmm8 = 0`).
    /// - 아니면 `inverse(objectWorld)` 로 한 번 더 내린다 —
    ///   `(u, v, 0, 1) · N`(`0x14022e5b8`–`0x14022e643`, 세 성분 모두 계산).
    ///
    /// 회전 3행은 이 경로에서 **안 건드린다** — base 복사분이 그대로 남는다
    /// (`0x14022e47b`–`0x14022e4ae` 가 `+0x80..0xbf` 를 `+0x00..0x3f` 로 옮긴 뒤
    ///  `0x14022e656`–`0x14022e662` 가 `+0x30/+0x34/+0x38` 만 덮는다).
    public static func pointerControlPointTranslation(pointer: Vec2,
                                                      inverseViewProjection: CPMatrix4,
                                                      inverseObjectWorld: CPMatrix4,
                                                      systemSimulatesInWorldSpace: Bool) -> Vec3 {
        let p = pointerPlanePoint(pointer: pointer, inverseViewProjection: inverseViewProjection)
        if systemSimulatesInWorldSpace { return Vec3(x: p.x, y: p.y, z: 0) }
        let n = inverseObjectWorld
        return Vec3(x: p.x * n[0, 0] + p.y * n[1, 0] + n[3, 0],
                    y: p.x * n[0, 1] + p.y * n[1, 1] + n[3, 1],
                    z: p.x * n[0, 2] + p.y * n[1, 2] + n[3, 2])
    }

    /// **[확정] CP 로 들어오는 외부 입력은 마우스뿐이다 — 오디오는 CP 를 타지 않는다.**
    /// 마스터 갱신 `0x14022e3e0`–`0x14022ebde` 전문에서 `call` 대상은 다섯뿐이고
    /// (`0x14005ecb0` 4×4 곱 · `0x14005f730` 역행렬 · `0x1402290d0` 역행렬 ·
    ///  `0x14022a070` 기본 갱신 · `0x14024f0e0` 4×4 곱) 오디오·시간·난수 호출이 **0건**이다.
    /// 오디오는 `remapvalue` 의 입력 채널로 파티클에 닿지, CP 슬롯으로 들어오지 않는다.
    public static let onlyExternalInputIsPointer = true

    // MARK: 이니셜라이저 opid 8 — inheritcontrolpointvelocity

    /// `v = (현재 위치 − 직전 위치) / dt`.
    /// `0x14023bc4c`(row3 of `CP + 0x00`) · `0x14023bc63`(row3 of `CP + 0x40`) ·
    /// `subps xmm6, xmm0` @`0x14023bc80` · `divps xmm6, xmm2` @`0x14023bc8e`
    /// (`xmm3 = [[sys] + 0x150]` = dt, `0x14023bc78`).
    public static func inheritedControlPointVelocity(current: Vec3,
                                                     previous: Vec3,
                                                     dt: Float) -> Vec3 {
        Vec3(x: (current.x - previous.x) / dt,
             y: (current.y - previous.y) / dt,
             z: (current.z - previous.z) / dt)
    }

    /// 스케일 `s = min + r · span`(`mulss xmm0, [r14 + 8]` @`0x14023bd0b` →
    /// `addss xmm0, [r14 + 4]` @`0x14023bd22`). 레코드 페이로드가 `+0x00 = min`,
    /// `+0x04 = max − min` 으로 굽혀 들어온다(`between` 의 `bounds` 와 같은 관례).
    public static func inheritScale(random: Float, min: Float, span: Float) -> Float {
        random * span + min
    }

    /// **[확정] 오브젝트 변환 보정은 두 조건이 AND 다** —
    /// 시스템 flags bit0(`test byte ptr [rdi + 0x20], 1` @`0x14023bc68`)이 서고
    /// **그 CP 의 bit1 이 서지 않아야** 한다(`test byte ptr [rbx + 0xc0], 2` / `jne`
    /// @`0x14023bc9c`–`0x14023bca3`). 속도 상속 자체는 언제나 일어난다.
    ///
    /// **동봉 도달 1 선언 / 289 파티클 파일**(설치본도 1) — `initializer[].name` 이
    /// `inheritcontrolpointvelocity` 인 것이 1건뿐이다.
    public static func inheritAppliesObjectCorrection(systemSimulatesInWorldSpace: Bool,
                                                      cpFlags: Int) -> Bool {
        systemSimulatesInWorldSpace && (cpFlags & ParticleControlPointFlag.worldAuthored) == 0
    }

    // MARK: 자식 CP 피드

    /// 부모 파티클 하나가 자식 CP 슬롯 하나를 먹인 결과.
    public struct ChildControlPointFeed: Equatable {
        public let slot: Int
        public let parentParticle: Int
        public init(slot: Int, parentParticle: Int) {
            self.slot = slot
            self.parentParticle = parentParticle
        }
    }

    /// `0x14022a580`–`0x14022a897` 의 배정 루프.
    ///
    /// ```
    /// 0x14022a710  edx = link.controlpointstartindex
    /// 0x14022a715  cmp edx, 8 ; jge → 끝
    /// 0x14022a730  cmp ecx, [rbx + 0xe8] ; jae → 끝            ; ecx = 부모 파티클 인덱스
    /// 0x14022a749  ucomiss xmm0, xmm7(0) ; jp/je → 0x14022a81d ; lifetime == 0 이면 건너뜀
    /// 0x14022a765  test dword ptr [r9 + r8 + 0xc0], 0x10005 ; jne → 0x14022a81d
    /// 0x14022a787  inc edx                                     ; 슬롯 소비
    /// 0x14022a7de  CP[구 edx] + 0x30/0x34/0x38 = 변환된 부모 위치
    /// 0x14022a81d  inc ecx ; cmp edx, 8 ; jl → 루프
    /// ```
    ///
    /// **[확정] 막힌 슬롯은 영구 정체다.** 두 건너뛰기(죽은 파티클 · `flags & 0x10005`)가 **같은**
    /// 자리 `0x14022a81d` 로 가고 거기서는 `ecx` 만 증가한다 — `edx` 는 그대로다. 즉 슬롯 k 가
    /// 막혀 있으면 남은 부모 파티클 전부가 같은 슬롯에서 튕기고 **k 이후로 아무것도 안 채워진다**.
    ///
    /// **[정정] 도달은 0 이 아니다.** `docs/re/particle-control-points.md` §6 은 "동봉 도달 0"
    /// 이라고 적는데, 실제로는 **동봉 2파일 / 설치 2파일**이 이 정체에 걸린다:
    /// `presets/lightning/particles/presets/thunderbolt.json`(과 `previewthunderbolt/` 사본)의
    /// 자식 링크는 `flags: 1` · `controlpointstartindex` 부재(→ 주입 기본 0)인데, 그 자식
    /// `thunderbolt_child_spawner.json` 의 CP 1 이 `flags: 4`(bit2)라 **슬롯 1 에서 막힌다**.
    /// → 그 자식은 CP 슬롯 **0 하나만** 부모 파티클을 받는다.
    /// (다른 체인인 `thunderbolt_child_spawner → thunderbolt_beam_child`(startIndex 1)는
    ///  자식 CP flags 가 전부 0 이라 슬롯 1..7 을 정상으로 받는다.)
    ///
    /// - Parameters:
    ///   - parentLifetimes: 부모 SoA `+0x260`. `0` 이면 죽은 파티클이다.
    ///     **NaN 은 살아 있는 것으로 친다**(`jp` 가 같음 분기를 건너뛴다 — `0x14022a74c`).
    ///   - childControlPointFlags: 자식 시스템의 CP `flags` 8개.
    public static func childControlPointFeed(startIndex: Int,
                                             parentLifetimes: [Float],
                                             childControlPointFlags: [Int]) -> [ChildControlPointFeed] {
        var slot = startIndex
        guard slot < ParticleControlPointLimits.slotCount else { return [] }
        var out: [ChildControlPointFeed] = []
        var particle = 0
        while particle < parentLifetimes.count {
            let life = parentLifetimes[particle]
            let dead = !life.isNaN && life == 0
            if !dead {
                let flags = slot >= 0 && slot < childControlPointFlags.count
                    ? childControlPointFlags[slot] : 0
                if flags & ParticleControlPointFlag.overrideBlockMask == 0 {
                    out.append(ChildControlPointFeed(slot: slot, parentParticle: particle))
                    slot += 1
                }
            }
            particle += 1
            if slot >= ParticleControlPointLimits.slotCount { break }
        }
        return out
    }

    /// **[확정] 자식 CP 피드가 켜지면 자식 시스템의 CP 개수가 무조건 8 이 된다** —
    /// `mov dword ptr [r12 + 0x44], 8` @`0x14022ccda`. 게이트는 자식 링크 `flags & 1`
    /// (`test byte ptr [rax + 0x64], 1` / `je` @`0x14022cccb`)이고, 실패하면
    /// `and byte ptr [rax + 0x3f6], 0xfe` @`0x14022ccf8` 로 피드 플래그를 도로 끈다.
    ///
    /// **동봉·설치 도달 4 링크**(`children[].flags` bit0), 그중 `controlpointstartindex` 를
    /// 저작한 것이 2 링크다.
    public static let childFeedForcesEightSlots = 8

    // MARK: remap 출력 CP 표시

    /// 파스 끝에서 `cp[slot].flags |= 0x10000` 을 받을 슬롯. 조건은
    /// **출력 채널이 `controlpoint`(표 인덱스 16)** 이고 `outputcontrolpoint0 < 8` 인 것뿐이다.
    /// (`0x1401bc470` = `cmp ecx, 0x10` / `sete al`, 상한 검사 `cmp ecx, 8` / `jae`
    ///  @`0x1401d0863`.) 인덱스는 이미 `clampIndex` 를 거친 값이라 실무상 늘 8 미만이다.
    public static func remapOutputMarkedSlot(outputChannelIndex: Int,
                                             outputControlPoint0: Int) -> Int? {
        guard outputChannelIndex == 16 else { return nil }
        let slot = Int(Int32(truncatingIfNeeded: outputControlPoint0))
        guard slot >= 0, slot < ParticleControlPointLimits.slotCount else { return nil }
        return slot
    }
}
