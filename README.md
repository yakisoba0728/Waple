# Waple

[![CI](https://github.com/yakisoba0728/Waple/actions/workflows/ci.yml/badge.svg)](https://github.com/yakisoba0728/Waple/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform: macOS 14+](https://img.shields.io/badge/Platform-macOS%2014%2B%20(Apple%20Silicon)-lightgrey)

A macOS reimplementation of [Wallpaper Engine](https://www.wallpaperengine.io/). Waple plays the
Wallpaper Engine workshop projects you already have on disk — `scene.pkg`, video and web — as a
native desktop wallpaper.

Scene wallpapers are **not** a stretched preview image. Waple renders the real scene data inside the
package with Metal: WE's GLSL shaders are translated to Metal Shading Language and executed on the
GPU, including particles, 3D meshes, puppet warp and audio-reactive effects.

> **Unofficial project.** Not affiliated with Valve, Steam or Wallpaper Engine; Wallpaper Engine is a
> trademark of its respective owner. Waple bypasses no authentication and no ownership check: scene,
> video and web playback runs on files already present on your disk, workshop browsing uses the Steam
> Web API with *your own* API key, and workshop downloads shell out to *your own* `steamcmd` using
> *your own* cached Steam session (Waple never stores your Steam password).

## Wallpaper type support

| Type | Playback | Notes |
| --- | --- | --- |
| `scene.pkg` scene | ✅ Native Metal renderer | See the [scene feature matrix](#scene-renderer-feature-matrix) |
| `.mp4` `.mov` `.m4v` video | ✅ AVFoundation, direct | HEVC preferred |
| `.webm` `.mkv` `.avi` video | 🟡 Transcoded first | Requires local `ffmpeg`; **only** for video containers found inside a WE background package — raw drag-and-drop import accepts `.mp4`/`.mov`/`.m4v` only |
| `index.html` web | 🟡 Restricted offline WKWebView | Storage is non-persistent by policy (`localStorage`/`IndexedDB` do not survive a remount) |
| `.jpg` `.png` `.gif` image | ❌ Not a top-level type | The type system and renderer factory have no image case. Unrelated to images used *as textures* by layers **inside** a scene |

## Scene renderer feature matrix

Legend: ✅ implemented · 🟡 partial (the gap is named) · ❌ not implemented

| Area | Status | What is covered |
| --- | --- | --- |
| GLSL → MSL transpiler | 🟡 | Source-to-source translation executed on the GPU; ~99.9% of the effect shader variants in the measured local corpus compile. Preprocessor (combos / `#include` / function-like macros), expression-level type inference (HLSL implicit vector truncation), GLSL structs, arrays, `inverse()`. Forward+ light *array* uniforms are registered but fed neutral scalars — no corpus scene enables those combos |
| Textures | 🟡 | Packed `.tex` (LZ4 blocks), DXT1/3/5, RG88, R8, mip chains, sprite-sheet frames (`TEXS0001`–`0003`), condition variants. The `Flags & 0x40` depth bit is unhandled, so depth/volume textures may fail to parse |
| Particles | 🟡 | Sphere/box emitters, bursts, child systems (`eventfollow`/`spawn`/`death`), sprite and trail renderers, `mapsequence`, and the common initializers/operators (movement, lifetime, oscillate, control-point attraction, turbulence, remap, …). Tokens outside that set are dropped with a log rather than emulated |
| Layers | ✅ | Keyframe animation (position, size, rotation, alpha, colour, mirrored ping-pong), property scripts (JS), composition (`_rt_`) layers, all 32 `colorBlendMode` values using the real `common_blending.h` formulas |
| 3D scenes | ✅ | Look-at camera, `.mdl` meshes (`MDLV0023` and variants), billboards, parent transform hierarchy, GPU skinning, Cook–Torrance PBR with point-shadow atlas |
| Puppet warp | ✅ | `MDLV0013` meshes, bones, mirrored bone animation, CPU skinning |
| Text | 🟡 | Fonts, alignment, colour, clock/date/media scripts (JavaScriptCore `update(value)`). In 3D scenes a text billboard animates placement and visibility per frame, but its *string* is rasterized once. `anchor`/`padding`/`backgroundBrightness` are parsed and preserved, not yet drawn |
| Audio | 🟡 | Audio-reactive effects (pulse, spectrum bars) and scene-embedded sound (mp3). Sound is mixed globally in 2D — `spatialization`/`mindistance`/`attenuation` are parsed but not spatialized |
| Mouse | ✅ | Parallax, `g_PointerPosition` cursor reaction, `cursorClick`/`Down`/`Up`/`Move` hooks |
| HDR / bloom | 🟡 | ACES tonemap and bloom (extract → blur → add) for both LDR and HDR paths; the blur pyramid is a 2-step (÷4, ÷8) approximation where WE uses 8 steps |

**Waple does not claim full Wallpaper Engine runtime compatibility.** Most unsupported scene features
are skipped with a log entry, but some paths — for example a layer texture whose bytes are present but
fail to decode, or shader compile validation on a machine with no GPU device — are skipped completely
silently. "It gets logged" is a general design direction, not a guarantee.

Known gaps that are tracked rather than hidden live in [BACKLOG.md](BACKLOG.md) and
[docs/](docs/); a few current examples: `_rt_` composite triangle masks in one corpus scene, word
wrap for very long unwrapped text (an 8192px raster guard can silently drop it), `g_Color1`–`4`
gradient uniforms, and `SHDV0069` shader-cache parsing.

## Requirements

| | Requirement | Notes |
| --- | --- | --- |
| OS | macOS 14 or later, Apple Silicon | The screensaver bundle targets macOS 13+; Intel is untested |
| Build | Xcode 26 / Swift 6.3+ | Zero external package dependencies. `Package.swift` declares `swift-tools-version:5.9`, but that governs the manifest API only — CI builds on Swift 6.3.2 and development on 6.4; older toolchains (Xcode 16 / Swift 6.0 and earlier) are not verified and have failed to type-check this codebase in the past |
| Optional | `ffmpeg` (`brew install ffmpeg`) | Converts `.webm`/`.mkv`/`.avi` found inside scene packages |
| Optional | `steamcmd` + a Steam Web API key | Workshop browse/download tab only. The API key is stored in the Keychain; the download uses your own cached `steamcmd` session |
| Optional | Wallpaper Engine shared base assets | Required for scenes that reference shared textures/shader headers — see below |

### Shared base assets

WE scenes reference shared textures and shader headers (`shaders/common.h`, …) that are *not* inside
the package. Point Waple at that folder so those scenes render completely:

```bash
defaults write kr.yaki.waple waple.baseAssetsPath /path/to/wallpaper_engine/assets
```

If unset, Waple probes `~/Downloads/wallpaper_dev/assets` and `~/Downloads/assets`, validating the
folder by the presence of `shaders/common.h`. These assets are not bundled with the app for copyright
reasons — you have to supply them.

## Install

**From a release** — download `Waple.dmg` from [Releases](https://github.com/yakisoba0728/Waple/releases),
open it and drag `Waple.app` into `/Applications`. Current builds are **ad-hoc signed, not notarized**,
so Gatekeeper will refuse the first launch; approve it once with either:

```bash
xattr -dr com.apple.quarantine /Applications/Waple.app     # or: right-click → Open
```

**From source:**

```bash
swift run Waple                 # run as a menu-bar utility
swift test                      # full test suite + real-scene ground truth
swift build -c release          # release build
bash scripts/package-app.sh     # build Waple.app (bundling the .saver screensaver) + Waple.dmg
```

## Desktop integration

| Feature | What it does |
| --- | --- |
| Library main window | SwiftUI, always dark. Grid browser, search and filters (type/tag/rating/favourite), folder organisation, detail panel (property editing, rating, removal), Now Playing bar, per-display assignment screen |
| Discover / Workshop tab | Four Steam Workshop discover rails (trending, latest, most subscribed, top rated) plus search and an infinite-scroll browser, `steamcmd` download progress UI, tile ratings, API key kept in the Keychain |
| Settings window + tray | Screen fit, occlusion pause, playlists, video volume/speed, launch at login, static-wallpaper sync, screensaver and base assets — all in one window. The tray menu stays at six items (open, recent, pause, next, settings, quit) |
| Above-icon window level | Desktop icons stay visible on top of the wallpaper |
| Occlusion auto-pause (opt-in) | Stops rendering while a window covers the desktop, to save power |
| Set as still wallpaper | Freeze one video frame, a scene capture or an image as the system wallpaper |
| Screensaver | Plays video wallpapers as a macOS screensaver (`.saver`); the previous screensaver is backed up and restored |
| Also | Launch at login, playlist rotation (shuffle, interval), per-monitor wallpaper assignment |

## Project layout

```
Sources/
  WapleCore/     Scene parser, .tex/.mdl decoders, GLSL transpiler, particle simulator (pure, testable)
  WapleRender/   Metal renderer, shaders, texture decode, audio/video/web renderers
  WapleLibrary/  Workshop folder scan/import, library/favourites/folders/playlist persistence
  Waple/         Menu-bar app + native SwiftUI main window (DesignSystem, Shell, Surfaces),
                 desktop window, screensaver control
  WapleCompat/   Compatibility scan, snapshot capture/compare and performance profiling CLI harness
  WapleSaver/    Screensaver .saver bundle source (Objective-C — compiled directly by package-app.sh)
  WapleSnapshot/ Snapshot manifest schema and diff metrics (pure Foundation, unit-verifiable)
Tests/           5 targets, 2,125 tests (synthetic units + real-corpus ground truth)
scripts/         package-app.sh (app/screensaver bundle), window-id.swift (capture ID/bounds lookup),
                 make-icon.sh / make-icon.swift (app .icns), Waple.icns (generated)
```

## How changes are verified

Renderer changes are validated by mounting and capturing the real scene corpus in bulk. Per-scene mean
luma baselines and preview pixel comparisons drive the automatic verdict, and offscreen PNG renders are
inspected directly for particle, effect and 3D visuals. Ground-truth tests that need the local corpus
skip themselves when it is absent (`WAPLE_REAL_PKGS`, `WAPLE_BASE_ASSETS`), so CI runs the synthetic
suite only.

## License

MIT — see [LICENSE](LICENSE). Third-party notices and trademark attribution are in [NOTICE](NOTICE).
