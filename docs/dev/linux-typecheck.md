# 리눅스에서 WapleRender 타입체크하기

`scripts/dev/linux-render-typecheck.sh` 는 `Sources/WapleRender/**` 를 **리눅스에서
`swiftc -typecheck`** 한다. macOS CI 왕복(약 10분) 없이 스코프·타입 오류를 커밋 전에 잡는다.

```bash
scripts/dev/linux-render-typecheck.sh          # 커버 대상 전체 타입체크
scripts/dev/linux-render-typecheck.sh --list   # 커버/제외 목록만
```

작업 디렉터리는 `WAPLE_LINUX_TYPECHECK_DIR`(기본 `$TMPDIR/waple-linux-render-typecheck`).

스크립트는 **스스로 락을 잡는다.** 이 컨테이너에서 동시 swift 빌드 2개는 OOM 으로 컨테이너를
통째로 재시작시킨다(실측: 실제로 당했다). 기본 락은 **작업 디렉터리와 무관한 고정 경로**
`$TMPDIR/waple-swift.lock` 이고, 실행할 때마다 어느 락을 잡는지 첫 줄에 찍는다.

> **[2026-08-21] 락 기본값을 유도에서 고정으로 바꿨다.** 종전엔 작업 디렉터리의 상위에서
> 유도했는데, 그러면 `WAPLE_LINUX_TYPECHECK_DIR` 을 다르게 잡은 두 실행이 **서로 다른 락**을
> 잡아 상호배제가 아예 안 된다. 실측으로 `/tmp/swift.lock` 과 `<스크래치패드>/swift.lock` 이
> 동시에 잡혀 있는 것을 봤다 — 유도 기본값은 안전해 **보이기만** 했다.

다른 swift 작업과 묶으려면 `WAPLE_SWIFT_LOCK` 을 **명시해라**(`linux-core-tests.sh` 는 스스로
락을 잡지 않으므로 호출자가 `flock` 으로 감싸는 관례다):

```bash
SC=<공유 스크래치패드>
WAPLE_SWIFT_LOCK="$SC/swift.lock" WAPLE_LINUX_TYPECHECK_DIR="$SC/linux-render-typecheck" \
  scripts/dev/linux-render-typecheck.sh
flock -w 3600 "$SC/swift.lock" env WAPLE_LINUX_TEST_DIR="$SC/linux-tests-shared" \
  scripts/dev/linux-core-tests.sh --filter …     # → 같은 락
```

## 왜 필요한가

WapleRender 는 `import Metal`/`MetalKit`/`AppKit` 이라 리눅스에서 `swiftc -parse` 밖에 못 돌린다.
**`-parse` 는 타입체크를 하지 않는다** — 문법만 본다. 그래서 `-parse` 의 rc=0 은 아무것도
보장하지 않고, 이 브랜치에서 그 공백으로 macOS CI 가 두 번 깨졌다:

| 커밋 | 결함 | `-parse` | 이 도구 |
|---|---|---|---|
| `b98db0a` | `Mesh3DShaders.swift:152` — Swift 멀티라인 리터럴 안 MSL 주석의 `\n` 하나가 MSL 147행을 깼다 | rc=0 (놓침) | **못 잡는다**(아래 한계 ①) |
| `bb5f902` | `SceneRendererResources.swift:1214` — 그 스코프에 없는 이름 `texW`/`texH` | rc=0 (놓침) | **잡는다**(양성 대조 아래) |

## 어떻게 도는가

`scripts/dev/linux-shim/` 의 **대역(shim) 모듈**을 `swiftc -emit-module` 로 만들고, 같은
모듈 검색 경로(`-I`)에서 커버 대상 소스를 `-typecheck` 한다. `Sources/` 는 한 글자도 건드리지
않는다(복사도 링크도 하지 않고 경로를 그대로 넘긴다).

심 모듈(전부 `scripts/dev/linux-shim/`):

| 모듈 | 파일 | 비고 |
|---|---|---|
| `CoreGraphics` | `coregraphics.swift` | CG* + **CoreFoundation 최소분**(`CFData`=`NSData` 등) + `FoundationNetworking` 재수출 |
| `QuartzCore` | `quartzcore.swift` | `CALayer`, `CACurrentMediaTime` |
| `Metal` | `metal.swift` | MTL* 전부 |
| `AppKit` | `appkit.swift` | `NSView`/`NSWindow`/`NSScreen`/`NSEvent`/`NSImage`/… **쓰는 것만** |
| `MetalKit` | `metalkit.swift` | `MTKView`, `MTKViewDelegate` |
| `CoreVideo` | `corevideo.swift` | `CVPixelBuffer`, `CVMetalTextureCache` |
| `AVFoundation` | `avfoundation.swift` | AV* + CoreMedia(`CMTime`·`CMSampleBuffer`) + CoreAudio(`AudioBufferList`) |
| `ScreenCaptureKit` | `screencapturekit.swift` | `SCStream` 계열 — **확신도 낮음** |
| `CoreText` | `coretext.swift` | `CTFont`/`CTLine`/`CTTypesetter` |
| `ImageIO` | `imageio.swift` | `CGImageSource` |
| `Accelerate` | `accelerate.swift` | vDSP FFT + vImage 회전/미러 |
| `JavaScriptCore` | `javascriptcore.swift` | `JSContext`, `JSValue` |
| `CryptoKit` | `cryptokit.swift` | `SHA256` |
| `Compression` | `compression.swift` | `compression_decode_buffer` |
| `WebKit` | `webkit.swift` | `WKWebView`·`WKNavigationDelegate`·`WKScriptMessageHandler`·`WKURLSchemeHandler` — **리눅스 Foundation 결손분**(`FoundationNetworking` 재수출, `autoreleasepool`)도 여기서 낸다 |
| `UniformTypeIdentifiers` | `uniformtypeidentifiers.swift` | `UTType(filenameExtension:)`·`preferredMIMEType` 뿐 |
| `simd` | `simd.swift`(기존) + `simd-extra.swift`(신규) | `simd-extra` 는 렌더 계층이 쓰는 것만 보탠다 |
| `WapleCore` | 실제 소스 + `corefoundation.swift` | 매 실행 다시 만든다 |

`simd.swift` 와 `corefoundation.swift` 는 `linux-core-tests.sh`(코어 테스트) 자산이라 건드리지
않았다. `simd-extra.swift` 는 이 스크립트만 함께 컴파일하며, `simd.swift` 에 이미 있는 것을
다시 선언하면 중복 선언 오류가 난다(그 목록이 `simd-extra.swift` 머리말에 있다).

`CFGetTypeID`/`CFBooleanGetTypeID` 만은 `WapleCore` 를 통해 나간다 —
`UserPropertyStore.swift`(WapleRender)가 `Foundation`+`WapleCore` 만 import 하는데 애플에서는
Foundation 이 CoreFoundation 을 재수출하기 때문이다. 스크립트가 읽기 전용 코어 심을
`sed` 로 그 **두 심볼만 public** 으로 바꿔 넣는다(사본이 아니라 파생이라 원본과 어긋날 수 없다).

## 커버 범위

`Sources/WapleRender/**` 의 `.swift` **55개 전부**가 타입체크된다. 제외는 **0건**이다.

> **[2026-08-21] 49 → 51 → 55.**
> · 49→51: `VideoRenderer.swift`·`FFmpegConverter.swift`. KVO 심
>   (`NSKeyValueObservation`·`NSKeyValueObservingOptions`·`NSKeyValueObservedChange`·
>   `AVPlayerItem.observe(_:options:changeHandler:)`)은 **이미 `avfoundation.swift` 에 있었고**
>   커버 목록에만 안 들어가 있었다. 실제로 모자랐던 것은 KVO 가 아니라 다섯 개뿐이었다 —
>   `AVPlayer.defaultRate` · `AVPlayerItem.audioTimePitchAlgorithm`(+`AVAudioTimePitchAlgorithm`) ·
>   `AVAsset.load` 의 2·3인자 오버로드 · `.tracks` 비동기 프로퍼티 · `AVAssetTrack.mediaType` ·
>   `CAAutoresizingMask` · `NSWindow.didChangeOcclusionStateNotification`.
> · 51→55: WebKit 덩어리 4파일. `webkit.swift`(신규, WK* 16종) +
>   `uniformtypeidentifiers.swift`(신규, `UTType` 하나) + `appkit.swift` 보강
>   (`NSTrackingArea`·`NSWindowDelegate`·`NSResponder` 입력 이벤트·`NSEvent.keyCode`/
>   `scrollingDelta*`/`charactersIgnoringModifiers`·`NSRect.fill()`·`NSString.draw(at:withAttributes:)`·
>   `NSImage.draw(in:from:operation:fraction:)`·`NSCompositingOperation`).
>   덤으로 **리눅스 Foundation 의 결손 두 개**가 드러났다(아래 "리눅스 Foundation 결손" 참조).

`OggVorbis/` 하위 6개도 커버에 포함된다.
실측(2026-08-21, 4코어 컨테이너, 55파일): 심 모듈 빌드 ~7초 + `WapleCore` emit-module ~22초 +
**타입체크 29~36초**(같은 트리에서 5회 측정). 도구 자체가 쓴 CPU 는 `user+sys` 약 63초다.
락 대기는 별도이고, 8개 에이전트가 동시에 도는 동안 벽시계는 2분 39초까지 갔다.
`spec` 잡의 `timeout-minutes: 10`(실측 잡 전체 15~28초) 안에는 여유롭게 들어간다.

**이 문서의 숫자는 스냅샷이다.** 정본은 스크립트의 `COVERED`/`EXCLUDED` 배열이고
`--list` 로 읽어라 — 커버가 늘어도(줄어도) 스크립트가 먼저 바뀌고 이 문단은 뒤따른다.
숫자가 어긋나면 `--list` 를 믿어라.

스크립트는 **커버/제외 목록이 실제 트리와 정확히 일치하는지** 매 실행 검사하고 어긋나면
실패한다. 새 파일이 조용히 커버 밖으로 떨어지는 것을 막는다(이런 도구가 죽는 가장 흔한 방식).
실측(2026-08-21): 목록에서 `QuadShaders.swift` 를 빼고 없는 `NotInTree.swift` 를 넣어 돌리니
양쪽 다 잡고 심 빌드 전에 `exit 1` 했다.

### `--tests` — `Tests/WapleRenderTests/**` 152파일 (2026-08-21 신설)

이 리포에서 **제일 큰 사각지대**였다. `Tests/WapleRenderTests/**` 는 152파일이고 macOS 전용
타깃이라, 여기서는 `swiftc -parse` 밖에 못 돌렸다. 즉 테스트 파일을 고친 작업은 "구문은 맞다"
만 확인한 채 푸시됐다. `-parse` 가 아무것도 보장하지 않는다는 것은 이 브랜치가 이미 두 번
배웠는데(위 `bb5f902`), **테스트 파일은 오히려 더 위험하다** — 소스보다 자주 고쳐지고,
`@testable import` 로 internal 표면까지 만지며, 깨져도 프로덕션 코드가 아니라서 리뷰가 얕다.

```
scripts/dev/linux-render-typecheck.sh --tests
```

소스 55파일 타입체크가 **통과한 뒤에만** 다음 단계로 간다(소스가 깨져 있으면 테스트 오류는
전부 그 파생이라 노이즈다). 그 다음:

1. `WapleCore` · `WapleSnapshot` · `WapleRender` 를 `-enable-testing` 으로 **모듈 emit**.
   `-typecheck` 가 아니라 emit 이어야 하는 이유는 `@testable import WapleRender` 가 실제로
   동작해야 internal 심볼 오타·시그니처 변경까지 잡히기 때문이다.
2. 테스트 152파일을 한 번에 `-typecheck`.

실측(2026-08-21, 4코어 컨테이너): 소스 타입체크 32초 + **모듈 emit 66초** + 테스트 타입체크.
소스만 볼 때(약 35초)보다 2~3배 든다 — 그래서 기본값이 아니라 **명시 플래그**다.
`Tests/**` 를 건드린 작업은 푸시 전에 반드시 이걸 돌려라.

#### 첫 실행이 찾은 것 — 그리고 그게 심 공백이었다는 것

첫 실행(152파일)에서 **1파일 · 오류 16줄**이 났고 전부 **심 공백**이었다:

| 없던 것 | 쓰는 곳 | 처리 |
|---|---|---|
| `NSBitmapImageRep.init?(data:)` | `AncestorVisibilityGateRenderTests:48` | `appkit.swift` 에 추가 |
| `NSBitmapImageRep.colorAt(x:y:)` | 〃 `:49` | 〃 |
| `NSColor.redComponent`/`greenComponent` | 〃 `:66` 이하 | `blueComponent`/`alphaComponent` 까지 함께 |

**151/152 는 손대지 않고 통과했다** — 즉 심의 표면은 이미 테스트 대부분을 덮고 있었고,
안 쓰던 도구였을 뿐이다.

> **심 공백과 진짜 오류를 구분하는 법.** 오류가 `linux-shim/` 의 `note:` 를 달고 나오거나
> 메시지가 `has no member` / `extra argument` / `missing argument` 면 대개 심이 모자란
> 것이다. 그때는 **테스트가 아니라 `scripts/dev/linux-shim/` 을 고쳐라**(실제 애플 헤더
> 시그니처를 주석에 적고 본문은 더미로 둔다 — 이 도구는 타입만 본다).
> 스크립트도 실패 시 이 판별을 자동으로 한 줄 찍는다. 소스 쪽 실패 메시지와 달리
> **"macOS 에서도 그대로 난다" 고 단정하지 않는다** — 테스트는 애플 API 표면을 훨씬 넓게 쓴다.

#### 서곡 파일 — 애플의 "Clang 모듈 전이 노출" 을 흉내 낸다

두 번째 실행에서 새 오류가 났다:

```
AudioCalibrationTests.swift:201:15: error: cannot find 'MTLCreateSystemDefaultDevice' in scope
AudioCalibrationTests.swift:230:25: error: cannot find 'NSView' in scope
```

그 파일은 `import Metal` 도 `import AppKit` 도 **안 한다**. 그런데 **macOS 에서는 빌드된다**
(실측: run 32484783071 · 3,140 테스트 0 실패). 스위프트가 임포트한 **Clang 모듈**은 클라이언트
에게 전이로 보이기 때문이다 — `@testable import WapleRender` 하나로 WapleRender 가 임포트한
Metal·AppKit 이 따라 들어온다. 이 리포의 심은 전부 **스위프트** 모듈이라 그 전이가 없다.

즉 **심 모델이 실물보다 엄격**해져 잡히는 것이 전부 거짓 양성이 된다. 그래서
`scripts/dev/linux-shim/zz-test-implicit-imports.swift` 를 테스트 타입체크 단계에만 끼운다
(`@_exported import` 16종). 서곡은 **소스 타입체크에는 안 들어간다** — 소스 파일들은 각자
필요한 것을 명시적으로 임포트하고 있고, 거기서는 엄격한 편이 맞다.

> **이 서곡은 모델을 실물보다 관대하게 만든다.** macOS 는 `WapleRender`/`WapleCore` 가 실제로
> 임포트한 Clang 모듈만 흘리는데 서곡은 심 전부를 흘린다. 지금 두 집합은 거의 같지만
> (WapleRender 가 16종을 전부 임포트한다) 심이 늘고 WapleRender 의 임포트가 줄면 갈린다.
> 그때는 **테스트에 `import` 를 되살리는 것이 아니라 서곡 목록을 줄이는 것**이 맞다.

### `--compat` — `Sources/WapleCompatCore/**` + 그 테스트 (2026-08-21 신설)

`Sources/WapleCompatCore/**`(5파일)는 **어떤 리눅스 검증도 못 받고 있었다** — `import Metal`/
`WapleRender`/`Darwin` 이라 코어 테스트에도, 렌더 커버에도 안 들어간다. 그런데 이 계층에
`SnapshotPipeline`(골든 썸네일 파이프라인)과 `DeepScan` 이 산다. 조용히 깨지면 골든 게이트가
통째로 무의미해지는 자리다.

```
scripts/dev/linux-render-typecheck.sh --compat     # --tests 를 포함한다
```

`--tests` 가 통과한 뒤 `WapleCompatCore` 를 `-enable-testing` 으로 emit 하고
`Tests/WapleCompatCoreTests/**` 와 `Tests/WapleSnapshotTests/**` 를 타입체크한다.
새로 필요했던 심은 `darwin.swift` 하나다(`ProfilePipeline.physFootprint()` 의 mach VM 질의 —
`task_vm_info_data_t`/`task_info`/`mach_task_self_`/`TASK_VM_INFO`/`KERN_SUCCESS` 등).

> `darwin.swift` 의 `task_vm_info_data_t` 는 호출부가 읽는 `phys_footprint` 한 필드만 둔다.
> 실물은 30개가 넘으므로 **`MemoryLayout<...>.stride` 가 다르다** — `count` 산술의 정합은
> 이 심으로 검증되지 않는다. 타입만 맞을 뿐이고, 그 산술은 macOS 실행만이 답한다.

#### 아직 못 하는 것

- `Tests/WapleAppTests/**`(36파일)는 `SwiftUI`·`Combine`·`Security` 심이 없어 커버 밖이다.
- `Tests/WapleCompatCoreTests/**`·`Tests/WapleSnapshotTests/**` 는 `--compat` 이 덮는다.
  `Tests/WapleLibraryTests/**`(7파일)·`Tests/WaplePolicyTests/**`(1파일)는 아직이다 —
  `WapleLibrary`/`WaplePolicy` 모듈을 세우면 붙는다.
- `Tests/WapleCoreTests/**` 는 여기 대상이 아니다 — `scripts/dev/linux-core-tests.sh` 가
  **실제로 실행**한다(타입체크보다 강하다).
- 타입체크는 **실행이 아니다.** 단언이 맞는지, 픽셀이 맞는지는 여전히 macOS CI 가 답한다.

### 제외 파일과 이유

**없다.** `EXCLUDED` 배열은 빈 채로 남겨 둔다 — 새 프레임워크를 쓰는 파일이 생기면 심을 쓰기
전까지 거기 넣고 이 절에 사유를 적는다.

### 리눅스 Foundation 결손 (WebKit 커버가 드러낸 것)

`WallpaperSchemeHandler.swift` 는 `Foundation`+`WebKit` 만 import 하는데 리눅스 Foundation 에
둘이 없어서 `webkit.swift` 가 대신 낸다. **둘 다 WebKit API 가 아니고**, 애플에서는 Foundation 이
항상 주는 것이라 여기 있어도 거짓 통과를 만들지 않는다(macOS 에서는 무조건 보인다):

| 심볼 | 리눅스 실태 | 실측 오류 |
|---|---|---|
| `HTTPURLResponse`(+`URLRequest`/`URLResponse`) | 실물은 `FoundationNetworking`, Foundation 에는 `AnyObject` 별칭만 | `'HTTPURLResponse' (aka 'AnyObject') cannot be constructed because it has no accessible initializers` |
| `autoreleasepool` | **아예 없다** | `cannot find 'autoreleasepool' in scope` |

## 한계 — 이 도구가 **못** 하는 것

① **MSL/GLSL/JS 문자열 리터럴의 내용은 검사하지 않는다.** `b98db0a` 류(Swift 리터럴 안의
   셰이더 문법)는 여기서 rc=0 이다. 그쪽은 `scripts/spec/check_swift_escapes.py` 와
   `WapleCore` 의 셰이더 테스트가 담당한다.

② **심이 실제 프레임워크와 다르면 거짓 통과/거짓 실패가 난다.** 심은 애플 헤더에서 기계적으로
   뽑은 것이 아니라 **손으로 적은 것**이다. 각 선언 위에 실제 시그니처를 주석으로 적었고,
   확신 없는 자리는 `확신 없음` 이라고 표시했다. 확신도가 낮은 순서:
   - `screencapturekit.swift` — 헤더를 못 봤고 호출부에서 역산했다. `SCShareableContent`
     의 async 팩토리와 `SCStream.addStreamOutput` 의 throws 여부가 미확인.
   - `avfoundation.swift` 의 `AVAsyncProperty`(`asset.load(.duration)`) — 타입 이름·제네릭
     배치가 역산이다.
   - `CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer` 의 인자 라벨 배치.
   - 열거형 원시값(예: `MTLPixelFormat`)은 이름만 맞추었다. 코드가 `rawValue` 로 왕복을
     시작하면 그때부터 거짓이 된다.

③ **`@objc optional` 프로토콜 요구사항의 셀렉터 어긋남을 못 잡는다.** `SCStreamOutput`,
   `AVAudioPlayerDelegate`, **`WKNavigationDelegate`, `NSWindowDelegate`** 는 애플에서 optional
   이라 이름이 어긋나도 컴파일이 통과하고 콜백만 조용히 안 온다. 리눅스에는 ObjC 런타임이 없어
   `@objc optional` 자체를 쓸 수 없으므로 심은 **프로토콜 확장의 기본 구현**으로 그 성질을
   재현한다 — **같은 함정을 그대로 둔다.** 특히 `WebRenderer.swift:271~` 이 기록한 사고
   (CI run 32214982769: `decidePolicyFor` 의 witness 자격 상실로 내비게이션 보안 게이트가
   무음으로 꺼졌다)는 **이 도구가 못 잡는 부류다.** 그 자리의 감시자는 여전히
   `WebRendererSecurityTests` 두 건이다.

④ **동시성 진단(`@MainActor`·`Sendable`)은 macOS 와 다를 수 있다.** 애플 SDK 의 격리
   어노테이션(과 `@preconcurrency` 강등)이 심에는 없다. 심의 타입은 전부 비격리다.
   WebKit 이 특히 그렇다 — 애플의 `WKWebView`/`WKNavigationDelegate`/`WKURLSchemeHandler` 는
   전부 `@MainActor` 라 `WebRenderer`·`WallpaperSchemeHandler` 의 `nonisolated` 표기와
   `RendererFactory` 의 "비격리 컨텍스트에서 메인액터 초기화자" 경고가 거기서 나온다.
   **여기서는 그 표기를 지워도 통과한다.** 그 계약의 판정자는 macOS CI 다.

⑤ **런타임 동작은 전혀 검증하지 않는다.** 심 본문은 `fatalError("linux shim")`/더미값이다.

⑥ 다른 작업이 같은 트리에서 `Sources/WapleCore/**` 를 고치는 중이면 swiftc 가
   `input file ... was modified during the build` 로 죽는다. 스크립트가 3회까지 재시도한다.

⑦ **한 번에 모든 오류가 나오지 않는다.** swiftc 드라이버는 파일을 배치로 나눠 돌리고
   한 배치가 실패하면 **남은 배치를 스케줄하지 않는다**. 그래서 출력에 보이는 오류가 전부라고
   믿으면 안 된다 — 고치고 다시 돌려라. (실측: 37파일 중 `UserPropertyStore.swift` 2건만 찍히고
   같은 실행에서 `SceneRenderer.swift` 의 368건이 통째로 안 나왔다.)

**최종 판정자는 여전히 macOS CI 다.** 이 도구는 왕복 횟수를 줄이는 것이지 CI 를 대체하지 않는다.

## 양성 대조 — 이 도구가 실제로 잡는지

`bb5f902` 이전(= `990aa2a`)의 `SceneRendererResources.swift` 를 끼워 넣으면 잡혀야 한다.

```bash
git show 990aa2a:Sources/WapleRender/SceneRendererResources.swift > /tmp/old.swift
scripts/dev/linux-render-typecheck.sh --replace SceneRendererResources.swift=/tmp/old.swift
```

실측(2026-08-21):

```
== 치환: SceneRendererResources.swift → …/SceneRendererResources-990aa2a.swift
== 타입체크: 55 파일 (제외 0) ==
…/SceneRendererResources-990aa2a.swift:1214:51: error: cannot find 'texW' in scope
…/SceneRendererResources-990aa2a.swift:1214:69: error: cannot find 'texH' in scope
== FAIL (rc=1)
```

`bb5f902` 커밋 메시지가 macOS 빌드 로그에서 인용한 자리(`1214:51 texW` · `1214:69 texH`)와
행·열이 정확히 같다. 이 대조가 통과하지 않으면 도구가 고장난 것이다 — 커버 목록이 줄었거나,
심이 그 이름을 우연히 정의해 버렸거나, `--replace` 가 실제로 안 먹은 경우다(**실제로 겪었다**:
락 재실행이 인자를 잃어 도구가 원본을 검사하고 rc=0 을 줬다. 그래서 이 대조가 필요하다).

음성 대조는 인자 없이 돌리는 것 자체다(현 트리 55파일에서 rc=0, 타입체크 34초 — 2026-08-21 실측).

추가로 잰 것(같은 방식의 `--replace` 돌연변이 3종):

| 돌연변이 | 기대 | 실측 |
|---|---|---|
| `Scene3DMath.swift` — `simd_determinant(upper)` → `simd_determinant("upper")` | 잡힘 | rc=1, `85:27 no exact matches in call to global function 'simd_determinant'` |
| `TextRasterizer.swift` — `ascent` → `ascentt`(스코프에 없는 이름) | 잡힘 | rc=1, `117:26 cannot find 'ascentt' in scope` |
| `Mesh3DShaders.swift` — MSL 리터럴 안 주석에 `\n` 삽입(`b98db0a` 재현) | **못 잡음** | rc=0 ← 한계 ① 의 실측 근거 |

새로 커버된 6파일의 양성 대조(2026-08-21, `--replace` 로 한 파일씩만 갈아끼움 — 12/12 잡힘):

| 파일 | 돌연변이 | 실측 |
|---|---|---|
| `VideoRenderer.swift` | `item.observe(\.status,…)` → `\.statuss` | `139:42 value of type 'AVPlayerItem' has no member 'statuss'` |
| `VideoRenderer.swift` | `tracks` → `trackss`(스코프 밖) | `154:32 cannot find 'trackss' in scope` |
| `FFmpegConverter.swift` | `contains(url.pathExtension…)` → `contains(42)` | `13:36 cannot convert value of type 'Int' to expected argument type 'String'` |
| `FFmpegConverter.swift` | `VideoRenderer.unsupportedExtensions` → `…sionss` | `11:70 type 'VideoRenderer' has no member 'unsupportedExtensionss'` |
| `WebRenderer.swift` | `webView.url` → `webView.urll` | `296:49`·`316:49 value of type 'WKWebView' has no member 'urll'` |
| `WebRenderer.swift` | `return .allow` → `.alloww` | `363:17 type 'WKNavigationActionPolicy' has no member 'alloww'` |
| `WebRenderer.swift` | `injectionTime: .atDocumentStart` → `42` | `102:55 cannot convert value of type 'Int' to expected argument type 'WKUserScriptInjectionTime'` |
| `WebInputProxyView.swift` | `event.keyCode` → `keyCodee` | `138:47 value of type 'NSEvent' has no member 'keyCodee'` |
| `WebInputProxyView.swift` | `web.takeSnapshot` → `takeSnapshott` | `38:17 value of type 'WKWebView' has no member 'takeSnapshott'` |
| `WallpaperSchemeHandler.swift` | `task.didFinish()` → `didFinishh()` | `217:22`·`271:18`·`292:14 value of type 'any WKURLSchemeTask' has no member 'didFinishh'` |
| `WallpaperSchemeHandler.swift` | `UTType(filenameExtension: ext)` → `42` | `340:49 cannot convert value of type 'Int' to expected argument type 'String'` |
| `RendererFactory.swift` | `WebRenderer(mode: .web)` → `.webb` | `21:39 type 'WebRenderer.Mode' has no member 'webb'` |

## CI

**현재 상태: `spec.yml` 에 프로브 스텝과 관측 스텝이 들어가 있다. 차단 게이트는 아직 아니다.**

| 단계 | 상태 | 커밋 |
|---|---|---|
| 1 · 프로브(러너 사실 재기) | **들어가 있다** | `1fb7ad2` |
| 2 · 판단 규칙 적용 | **끝났다** — 아래 표에서 "6.3.3 + 모드 5" 행이 뽑혔다 | — |
| 3 · 관측(초록을 안 깨고 진단을 본다) | **들어가 있다** | 이 커밋 |
| 4 · 차단 게이트 | **아직 아니다** — 3단계가 러너에서 rc=0 을 준 뒤에만 | — |

### 확정된 것

먼저 1차 자료(2026-08-21):

| 사실 | 근거 |
|---|---|
| `ubuntu-latest` = **Ubuntu 24.04**, `ubuntu-24.04` 와 **같은 칸** | `actions/runner-images` README 라벨 표 |
| 그 이미지(`20260816.277.1`)에 **Swift 6.3.3** 동봉 | `images/ubuntu/Ubuntu2404-Readme.md` |
| `swift`·`swiftc` 가 **`/usr/local/bin`** 에 심링크, 실체는 `/usr/share/swift` | `images/ubuntu/scripts/build/install-swift.sh` |
| `SWIFT_PATH=/usr/share/swift/usr/bin` 이 `/etc/environment` 에 박힌다 | 같은 스크립트 |
| `ubuntu-latest` 는 **26.04 로 이동 중**(공개 프리뷰, 1~2개월 점진) | 같은 README 의 "Latest Migration Process" |

그리고 **프로브가 실제 러너에서 재 온 것**(`1fb7ad2` 가 넣은 스텝의 CI 로그):

```
image=20260816.277.1  arch=x86_64  cores=4  mem=15989MB    ← 개발 컨테이너와 같은 사양
os=Ubuntu 24.04 LTS
SWIFT_PATH=/usr/share/swift/usr/bin
swift  -> /usr/local/bin/swift          swiftc -> /usr/local/bin/swiftc
Swift version 6.3.3 (swift-6.3.3-RELEASE)      rc(swift --version)=0
flock: yes
rc(기본 언어 모드 typecheck)=0    # 0 이면 모드 5 — 도구의 전제가 선다
```

즉 **툴체인 존재·버전 6.3.3·기본 언어 모드 5·`flock` 존재·4코어**가 전부 확정이다.
설치 단계(`swift-actions/setup-swift` 등)는 필요 없다.

### 미해결 — 그래서 아직 차단 게이트가 아니다

1. **버전이 다르다 — 그리고 실제로 갈렸다. [2026-08-21 관측 결과 도착]**
   로컬 **6.0.3** 은 rc=0 인데 러너 **6.3.3** 은 오류를 하나 낸다. 관측 스텝이 실제로 찍은 줄
   (`spec` run 32482815811 · job 96772696708 · 커밋 `6064495` · 2026-08-21T12:39:18Z):

   ```
   Sources/WapleRender/ArtworkColors.swift:35:22: error: the compiler is unable to
   type-check this expression in reasonable time; try breaking up the expression into
   distinct sub-expressions
   ```

   35행은 `let ranked = (0..<4096).filter { … }.sorted { … }.map { SIMD3<Float>(…) }` 한 줄짜리
   체인이다. **심 문제가 아니라 타입체커 예산 문제**이고, 그래서 심을 고쳐서는 안 닫힌다 —
   식을 명시 타입으로 쪼개야 한다.

   판정: **게이트 승격은 이것부터 닫아야 한다.** 지금 올리면 첫 실행부터 빨간불이다.
   다만 이것이 *심이 러너와 어긋난 사례는 아니라는 것*도 같이 확정됐다 — 55파일 중 심 관련
   진단은 **0건**이었다. 즉 손으로 적은 심 17종은 6.0.3 과 6.3.3 양쪽에서 통했다.
   (macOS CI 는 같은 커밋에서 초록이다 — Xcode 툴체인은 그 식을 예산 안에 푼다. 즉 이 자리는
   **툴체인 예산 경계에 걸쳐 있는 코드**이고, 러너가 먼저 넘어졌을 뿐이다.)

해소된 것도 적어 둔다(전에는 이 목록에 있었다):

- ~~기본 언어 모드를 모른다~~ → 프로브가 rc=0 을 줬다. 모드 5 다.
- ~~러너 Swift 버전이 움직인다 / `ubuntu-latest` 가 26.04 로 이동 중~~ → `spec` 잡을
  **`runs-on: ubuntu-24.04` 로 고정**했다(이 커밋). 오늘 기준 동작은 완전히 같다 — README 가 두 라벨을
  같은 칸에 싣고 프로브가 `Ubuntu 24.04 LTS` 를 찍었다. 잡 전체를 고정한 이유는 **관측이 게이트가
  돌 환경과 같은 환경에서 재야 근거가 이월되기 때문**이고, 덤으로 기존 게이트 20종도 이미지 이동에서
  보호된다. 26.04 로 올릴 때는 라벨만 바꾸지 말고 `workflow_dispatch` 로 한 번 돌려 관측 스텝의
  rc 와 툴체인 줄을 다시 읽어라.
- ~~도구 자체가 이 세션에 바뀌는 중이다~~ → `0a9755e` 가 커버를 **55/55(제외 0)** 로 닫았다.
  `EXCLUDED` 가 비었으므로 "커버 밖으로 새는" 경로가 없고, 목록 불일치 검사가 새 파일을 즉시 잡는다.

### 1단계 — 프로브 (**들어가 있다**)

`spec.yml` 의 `Probe swift on runner`. `set +e` 로 돌고 마지막 명령이 `:` 라 **어떤 경우에도 rc=0** 이다.
로컬 음성 대조(2026-08-21): `swift` 가 PATH 에 **없을 때**도 rc=0(전건 `command not found`), **있을 때**도 rc=0.

기본 언어 모드 판정에 쓰는 스니펫과 그 돌연변이 실측(로컬 6.0.3):

| 인자 | rc | 진단 |
|---|---|---|
| (없음 — 기본) | 0 | — |
| `-swift-version 5` | 0 | — |
| `-swift-version 6` | **1** | `main actor-isolated var 'probeGlobal' can not be mutated from a nonisolated context` |

**관측 스텝이 들어간 뒤에도 프로브는 남긴다.** 관측 스텝은 언어 모드를 재지 않는다 — 그 전제가
깨지는 날 프로브가 먼저 보여 준다.

**읽는 법**: `python3 scripts/dev/ci-status.py --branch <브랜치> --jobs` 로 `spec` 잡 id 를 받고
`python3 scripts/dev/ci-status.py --log <JOB_ID>` 로 발췌한다.

### 2단계 — 판단 규칙

프로브 로그를 읽고 **아래 표대로만** 움직여라. 표에 없는 상태면 넣지 마라.

| 프로브 결과 | 다음 |
|---|---|
| `swift --version` rc≠0 또는 `<none>` | **넣지 마라.** 설치 단계가 필요하고 그러면 별도 잡으로 떼는 게 맞다 |
| 버전이 **6.0.x** (로컬과 동일) + 언어 모드 rc=0 | 3단계(관측)를 건너뛰고 바로 4단계(게이트)로 가도 된다 |
| 버전이 **6.3.3**(예상) + 언어 모드 rc=0 | **3단계(관측)를 먼저 돌려라.** 진단 차이를 안 보고 게이트로 올리지 마라 |
| 언어 모드 rc≠0 | **넣지 마라.** 도구에 `-swift-version 5` 를 넘기도록 고치는 게 먼저다(스크립트 소유자에게 넘겨라) |

**뽑힌 행: 세 번째.** 6.3.3 + 모드 rc=0 → 3단계.

### 3단계 — 관측 (**들어가 있다**)

`spec` 잡의 마지막 스텝 `WapleRender linux typecheck (관측 전용 — 게이트 아님)`.
정본은 `.github/workflows/spec.yml` 이다 — 여기 다시 베껴 적지 않는다(두 벌이 갈리는 것이 이
리포의 상습 결함이다). 설계만 적는다.

**초록을 지키는 장치가 셋이고, 셋 다 서로를 대체하지 않는다.**

| 장치 | 막는 것 | 검증 가능한가 |
|---|---|---|
| `continue-on-error: true` | 스텝 실패 → 잡 failure | 여기서는 **못 잰다**(러너에서만 확인된다) |
| 본문 `set +e` + 마지막 `:` | 스텝 rc 자체 | **로컬 `bash -e` 로 직접 잰다** |
| 내부 `timeout 420` | 스텝이 매달려 잡의 `timeout-minutes: 10` 을 먹는 것 | 로컬에서 잰다(아래) |

세 번째가 특히 중요하다 — **잡 타임아웃은 잡 취소라 `continue-on-error` 로 막히지 않는다.**
예산: 기존 게이트 20종 실측 15~28초 + 이 스텝 최대 420초 = 448초 < 600초(잡 상한).
도구의 실제 소요는 벽시계 1분 05초라 420초는 6배 여유다.

**결과를 세 곳에 띄운다.** `continue-on-error` 만 걸고 끝내면 실패가 조용히 묻힌다 — 이 리포가
이미 겪은 일이다(`ci.yml` 의 release 레인에서 `Show failure summary` 가 통째로 skipped 였다,
run `32218275170`·`32230929535`):

1. 실행 페이지 상단의 `::warning title=리눅스 타입체크 관측 rc=…::`
2. 잡 요약(`$GITHUB_STEP_SUMMARY`) — 러너 이미지·툴체인·커버 수 표 + **파일별 오류 수** +
   원문 40줄(`<details>`)
3. 로그의 기계 판독용 한 줄 `TYPECHECK_OBSERVATION rc=<n> toolchain=<…>`
   (`ci-status.py --log <JOB_ID>` 에서 이것만 grep 하면 된다)

rc 는 세 갈래로 갈라 적는다: `0`(승격 근거가 섰다) · `124`(진단이 아니라 **예산 문제**) ·
그 외(진단 — 심 문제인지 코드 문제인지 가르라).

**본문 로컬 실측(2026-08-21).** YAML 에서 `run:` 문자열을 그대로 뽑아 `bash -e` 로 돌렸다
(추출본과 시험본이 바이트 동일한 것을 `diff` 로 확인). **네 경로 전부 스텝 rc=0 이다:**

| 경로 | 만든 법 | 도구 rc | 스텝 rc | 요약 |
|---|---|---|---|---|
| 정상 | 그대로 | 0 | **0** | "러너 툴체인에서도 rc=0" |
| 진단 | 스텁이 `error:` 3줄 + rc=1 | 1 | **0** | 파일별 표(`WebRenderer 2`·`…Resources 1`) + 원문 |
| 시간 초과 | `timeout` 을 2초로 줄인 사본 + 60초 자는 스텁 | 124 | **0** | "예산 문제" 로 갈라 적는다 |
| 툴체인 없음 | `SWIFT_PATH` 미설정 + PATH 에 swiftc 없음 | 2 | **0** | `!! swiftc 를 못 찾았다` + 경고 |

정상 경로의 벽시계는 66초(55파일, 4코어, 다른 작업 8개가 도는 중)였다. 진단 경로는 **실물로도**
한 번 걸렸다 — 다른 작업이 `SceneRenderer.swift` 를 고치는 중이라 `PointerHit.DeliveryScope` ·
`PointerClickLatch` 미해결로 rc=1 이 났고, 요약이 `4 SceneRenderer.swift` 로 정확히 접었다.

**환경변수를 왜 그렇게 주는가**

- `WAPLE_SWIFT_BIN` — `SWIFT_PATH`(`/usr/share/swift/usr/bin`)를 먼저 쓴다. `/usr/local/bin` 에는
  심링크만 있고 도구는 `$WAPLE_SWIFT_BIN/swiftc` 가 실행 가능하기만 하면 되므로 둘 다 되지만
  실체 경로 쪽이 안전하다. 이 값을 **변수 하나에 담아** 요약의 "툴체인" 칸에도 같이 찍는다 —
  무엇으로 잰 결과인지가 로그만 보고 확정돼야 한다.
- `WAPLE_LINUX_TYPECHECK_DIR`·`WAPLE_SWIFT_LOCK` — 둘 다 `$RUNNER_TEMP` 아래. 러너에는 경합이
  없으므로 락은 형식적이지만, 도구가 락 경로를 **유도**하지 않게 명시하는 것이 이 리포의 규약이다.

### 4단계 — 게이트 (3단계가 러너에서 rc=0 을 준 **뒤에만**)

승격 절차:

1. `spec` 잡 로그에서 `TYPECHECK_OBSERVATION rc=0` 을 **최소 한 번** 확인한다. rc≠0 이면 요약의
   파일별 표를 보고 **심 문제인지 실제 코드 결함인지 먼저 가른다** — 심 문제면 해당 심 파일을
   고치는 것이 먼저이고, 게이트는 그다음이다.
2. 그 스텝에서 `continue-on-error: true` · 본문의 `set +e` · 마지막 `:` 를 뺀다.
   `timeout 420` 은 **그대로 둔다**(잡 타임아웃 방어는 게이트가 돼도 필요하다).
3. `runs-on` 은 이미 `ubuntu-24.04` 로 고정돼 있다 — 건드릴 것 없다.
4. 이 절과 `AGENTS.md` 를 함께 갱신한다.

**한 번에 두 단계를 넣지 마라.** 프로브 → 관측 → 게이트를 각각 별도 커밋으로 밀어야
어느 단계에서 어긋났는지 한 번의 실행으로 갈린다.

**게이트가 돼도 이 도구는 macOS CI 를 대체하지 않는다**(한계 ①③④⑤ 참조). 차단하는 것은
"스코프·타입 오류가 리눅스에서도 보이는 부류" 하나뿐이다.

## 심을 고쳐야 할 때

- **커버 대상이 새 프레임워크 API 를 쓰기 시작하면** `cannot find X in scope` 로 즉시 드러난다
  (조용한 실패가 없다). 해당 심 파일에 선언을 보태고 **실제 시그니처를 주석으로 남겨라.**
- **심 시그니처가 틀렸다고 의심되면** macOS `swift build` 가 유일한 심판이다. 심이 통과시킨
  코드가 macOS 에서 깨졌다면 그 자리를 심에 반영하고 이 문서의 "확신도" 목록을 갱신해라.
- **새 소스 파일을 추가하면** 스크립트가 목록 불일치로 실패한다. `COVERED` 나 `EXCLUDED` 에
  넣고 이 문서의 표를 갱신해라.
