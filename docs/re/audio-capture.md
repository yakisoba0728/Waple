# 오디오 캡처 → FFT → 밴드 축약 — WE 앞단 전수 대조

**조사일 2026-08-21 · WE 2.8.42 `wallpaper64.exe` (imagebase `0x140000000`, sha256 `40e2ce02…`)**
**대상: WASAPI 캡처 초기화 `0x1400cf120–0x1400cf969` · 오디오 스레드 본체 `0x1400d02b0–0x1400d2117`**

§1–§5 는 **앞단**(캡처 파라미터 → FFT → 64밴드 산출)만 다룬다. 뒤단(소비 정규화·스무딩·
2단 MAX)은 `Sources/WapleCore/AudioSpectrumProcessor.swift` 가 실물과 맞춰져 있고, **§7–§8 이
그 뒤단까지 확장한다** — §7.1 의 축약 결함, §8.1 의 전건 재측정, §8.2 의 클램프/dB 부재,
§8.3 의 씬 스크립트 API. §8 은 `bin/scenescript64.dll`(imagebase `0x180000000`)도 쓴다.

## 0. 결론

| 항목 | 실물 | Waple | 판정 |
| --- | --- | --- | --- |
| 캡처 API | WASAPI `IAudioClient` 공유모드 + `AUDCLNT_STREAMFLAGS_LOOPBACK` | ScreenCaptureKit `SCStream(capturesAudio:)` | 등가(플랫폼 차) |
| 샘플레이트 | **요청하지 않는다** — `GetMixFormat()` 이 준 것을 그대로 쓴다 | `SCStreamConfiguration.sampleRate = 48000` 을 **요청**하고, 실제 값은 버퍼 ASBD 에서 읽는다 | 등가(실측값이 진실원인 점이 같다) |
| 샘플 포맷 | 32비트 float 요구(`wBitsPerSample == 32`), 아니면 로그만 남기고 **진행** | CoreAudio 가 float32 를 보장 | 일치 |
| 채널 | mix format 그대로. 실패 시 (채널수, 채널마스크) 10종 폴백 | 2 요청, 실제 버퍼에서 분리 | 등가 |
| 버퍼 길이 | 419.4304 / 104.8576 / 26.2144 ms / 장치 기본 을 순서대로 시도 | SCStream 이 결정 | 통제 불가(무해) |
| 폴 간격 | `Sleep(33 ms)`, 무패킷 1,000 ms 누적 시 강제 무음 | 푸시 콜백(폴링 없음) | **차이 있음** — §4 |
| FFT | **복소** interleaved, 길이 `N = int(max(rate/44100,1)·64·30)`, FFTS(비-2거듭제곱이면 Bluestein) | vDSP packed-real, `N = 2048` 고정 | **차이 있음** — §4 |
| 창 함수 | **없다.** 사각창 `W = int(N − (10/30)·N)`, 오버랩 0 | 동일(절삭 위치까지) | 일치 — §5 에서 1 샘플 정정 |
| 제로패딩 | 0 이 아니라 **무음 DC 값 127**(허수부 1/127)로 채운다 | 0 패딩 | **등가**(§2.4 증명) |
| 시간영역 전처리 | `re = 127·s + 127`, `im = 1/(127·s + 127)` | `re = s`(게인은 맨 뒤 162.56 에 흡수) | 등가, 잔차 ≤ −85 dB(§2.5) |
| 소비 빈 | `i = 1 … B−1`, `B = int(64·10) = 640` **레이트 무관 고정** | `B = binCount(N, rate)`(48k 627 · 44.1k 683) | 설계상 등가(§4) |
| 밴드 매핑 | `min(int(pow(t,0.25)·64) % 64, prev+1)`, `t=(i−1)/(B−1)` | 동일 | 일치 |
| 게인 | `AP[0x0C]·0.001·B/(N/2)` (비정규화 DFT 기준) | `162.56`(= `127·0.001·2·640`) | 일치(§3.4) |
| 버퍼 ×3 | `[Left \| Right \| Mono]`, mono = `0.5·(L+R)` | 동일 | 일치(§3.5) |

**도달**: 설치본에서 오디오 유니폼을 실제로 읽는 자산은 **6개**(2026-08-21 정정 — 종전 7개는
`neon_sunset` 오산), 리포 동봉분으로는 **3개**다(§6). 그리고 그 6개마저 **기본 상태에서는 아무도
오디오를 켜지 않는다** — 활성화 콤보가 동봉·설치 JSON 3,741개 중 **0건**이다(§6.1).
새로 지을 것은 없고, 2026-08-20 라운드는 **어긋난 산술 셋 정정(§4 #1·#2·#10) + 순수부 이관**으로 끝났다.
2026-08-21 재대조는 **소비단 32밴드 축약 결함 1건**을 찾았다(§7.1).
같은 날 2차 라운드는 소비단을 **전건 재측정(정정 0건)** 하고, `scenescript64.dll` 의
`registerAudioBuffers` 를 떠서 §7.2(b) 의 미해결을 닫았다 — 씬 스크립트 오디오 버퍼는
**접지 않고**, 셋째 배열의 실물 이름은 `average`(= mono 사분면)다(§8.3). 더해서
**상한 클램프도 dB 변환도 없다**는 것을 전수로 확인했고(§8.2), 32·16밴드의 **빈/주파수 경계표**를
처음 적었다(§8.4 — 16밴드 0…6 이 정확히 등간격 91.875 Hz).

---

## 1. 캡처 경로 — 명령 단위

`0x1400cf120` 이 초기화 전부다. 반환은 `bool`(성공). 인자 10개의 실측 대응:

| 인자 | 캐리어 | 넘기는 곳 | 의미 |
| --- | --- | --- | --- |
| 1 rcx | `AP+0xE4` | `0x1400d0512` | 상수 4개 묶음(지수·틸트·N계수·B계수) |
| 2 rdx | `AP+0x100` | `0x1400d04fc` | 장치 이름 `std::string`(빈 문자열/`"default"` → 기본 장치) |
| 3 r8 | `AP+0xE0` | `0x1400d050a` | out 채널 수 |
| 4 r9 | `AP+0x08` | `0x1400d04f3` | out 플래그(bit0 = **비**루프백, `0x1400cf8dc`) |
| 5 | `AP+0xF4` | `0x1400d052c` | out FFT 길이 N |
| 6 | `AP+0xF8` | `0x1400d0503` | out 소비 빈 수 B |
| 7 | `AP+0xC8` | `0x1400d050d` | `IMMDeviceEnumerator*` |
| 8 | `AP+0xD0` | `0x1400d0520` | `IAudioClient*` |
| 9 | `AP+0xD8` | `0x1400d04ee` | `IAudioCaptureClient*` |

> **오프셋 기준선 주의.** 생성자 `0x1400c0c80` 의 `this` 와 오디오 스레드 `0x1400d02b0` 의
> `rdi` 는 **8바이트 어긋나 있다**. 생성자가 `lea rbx,[rcx+8]` 로 잡아 0x200 바이트 밴드
> 버퍼를 심는 자리(`0x1400c0cb4`)가 스레드에서는 `[rdi+0]`(`0x1400d1f4d` 의 memset 대상)다.
> 이 문서와 코드 주석은 **스레드 기준**(정본 `spec/engine/effect-fbo-audio.json` 과 같은 기준)을
> 쓴다 — 생성자 즉시값 VA 를 인용할 때 오프셋이 8 커 보이는 것은 그래서다.

### 1.1 장치 선택

```
0x1400cf1a5  CoCreateInstance(CLSID_MMDeviceEnumerator, NULL, CLSCTX_ALL, IID_IMMDeviceEnumerator, &e)
```
GUID 는 `0x140482ac8` = `BCDE0395-E52F-467C-8E3D-C4579291692E`,
`0x140482ad8` = `A95664D2-9614-4F35-A746-DE8DB63617E6` — 원시 바이트를 직접 읽어 확인했다.

- **이름이 비었거나 `"default"`**(`memcmp` @`0x1400cf1e4`) → 열거를 건너뛰고
  `0x1400cf54e` 의 `GetDefaultAudioEndpoint(eRender=0, eConsole=0, &dev)`. `eRender` 라
  **출력단**이고, 그래서 루프백이다.
- 그 외 → `0x1400cf239` 의 `EnumAudioEndpoints(dataFlow, DEVICE_STATE_ACTIVE=1, …)` 를
  `dataFlow ∈ {eRender=0, eCapture=1}` 두 번 돌며(`cmp r12d, 2` @`0x1400cf4c3`)
  `PKEY` 표시 이름을 UTF-8 로 바꿔(`WideCharToMultiByte`, `CP_UTF8=0xfde9` @`0x1400cf35a`)
  비교한다. 매치된 장치가 **eRender 면 루프백, eCapture 면 아니다**
  (`test r13d,r13d` / `sete r14b` @`0x1400cf4d9`).

### 1.2 포맷 요구 — 오류 문자열 두 개가 나오는 자리

```
0x1400cf5ab  hr = client->GetMixFormat(&wf)        ; vtable +0x40
0x1400cf5bb  cmp word [wf+0x0E], 0x20              ; WAVEFORMATEX.wBitsPerSample
0x1400cf5c2  → "WASAPI processor requires 32 bit per sample."   (0x140486660)
0x1400cf632  cmp nChannels*4, wf->nBlockAlign
0x1400cf646  → "WASAPI unexpected block align: %i * %i != %i."  (0x140486630)
```

둘 다 **로그일 뿐 중단이 아니다** — 진단 함수(`0x1400986c0`)를 부르고 그대로 진행한다.
즉 32비트가 아니면 뒤의 샘플 읽기(`movss`)가 그대로 오독하게 된다. WASAPI 공유모드
믹스 포맷은 사실상 항상 `IEEE_FLOAT 32`라 실무에서는 안 걸린다.

`GetMixFormat` 이 준 값은 **그대로 쓴다**. `IsFormatSupported` 도, 레이트 요청도 없다.

### 1.3 N 과 B 가 정해지는 자리 (`0x1400cf5d3–0x1400cf630`)

```
eax = wf->nChannels          ; *out_channels
xmm0 = float(wf->nSamplesPerSec) / 44100.0        ; 0x1400cf5ec
if (!(xmm0 > 1.0)) xmm0 = 1.0                     ; 0x1400cf5f4  ← 44.1 kHz 미만은 1 로 클램프
N = (int)(xmm0 * 64.0 * cfg[+8](=30.0))           ; 0x1400cf60b–0x1400cf619
B = (int)(cfg[+0xC](=10.0) * 64.0)                ; 0x1400cf61b–0x1400cf630
```

| rate | N | W = int(N−N/3) | 빈 폭 | 창 길이 | 상한 = bin(B−1) |
| --- | --- | --- | --- | --- | --- |
| 32000 | 1920 | 1280 | 16.667 Hz | 40.00 ms | **10650.0 Hz** |
| 44100 | 1920 | 1280 | 22.969 Hz | 29.02 ms | 14677.0 Hz |
| 48000 | 2089 | 1392 | 22.978 Hz | 29.00 ms | 14682.6 Hz |
| 88200 | 3840 | 2560 | 22.969 Hz | 29.02 ms | 14677.0 Hz |
| 96000 | 4179 | 2786 | 22.972 Hz | 29.02 ms | 14679.1 Hz |
| 192000 | 8359 | 5572 | 22.969 Hz | 29.02 ms | 14677.4 Hz |

설계 의도는 **빈 폭 ≈22.97 Hz · 창 ≈29 ms 고정**이다. 단 `max(…,1)` 클램프 때문에
**44.1 kHz 미만에서는 그 불변식이 깨진다** — 32 kHz 면 상한이 10650 Hz 로 27% 낮다.
종전 우리 주석이 "상한은 레이트와 무관한 상수" 라고 단정했는데 그건 44.1 kHz **이상**에서만
참이다. §5 가 이 한 줄을 고친다.

`N` 은 실무 레이트 전부에서 **2의 거듭제곱이 아니다**(1920·2089·3840·4179·8359).

### 1.4 `Initialize` — 공유모드 · 루프백 · 버퍼 길이 4단 폴백

```
0x1400cf663  esi = (loopback ? 1 : 0) << 17        ; 1<<17 = 0x20000 = AUDCLNT_STREAMFLAGS_LOOPBACK
0x1400cf692  hr = client->Initialize(              ; vtable +0x18
                 ShareMode      = 0,               ; AUDCLNT_SHAREMODE_SHARED  (xor edx,edx)
                 StreamFlags    = esi,
                 hnsBufferDuration = DUR[i],       ; [rbp + i*8 - 8]
                 hnsPeriodicity = 0,
                 pFormat        = wf,              ; GetMixFormat 결과 그대로
                 AudioSessionGuid = NULL)
0x1400cf6a1  i = 0..3 까지 재시도
```

`DUR[]` 는 `0x140492b30`/`0x140492a50` 의 16바이트 상수 둘을 스택에 편 것이다.
원시 바이트 `00004000 00000000 00001000 00000000` / `00000400 00000000 …` 을 u64 로 읽으면:

| i | hns | 실시간 |
| --- | --- | --- |
| 0 | 4194304 | 419.4304 ms |
| 1 | 1048576 | 104.8576 ms |
| 2 | 262144 | 26.2144 ms |
| 3 | 0 | 장치 기본 주기 |

네 번 다 실패하면(그리고 루프백이면) `0x1400cf6f2` 의 **채널 폴백**으로 넘어가
`wf->nChannels` 를 10종으로 바꿔 가며 다시 4단을 돈다. 표는 `0x140492c30`/`0x140492c40`
(채널 수)과 `0x1400cf712–0x1400cf76d`(채널 마스크)에서 읽었다:

| # | nChannels | dwChannelMask | 뜻 |
| --- | --- | --- | --- |
| 0 | 2 | 0x003 | 스테레오 |
| 1 | 1 | 0x004 | 모노(FC) |
| 2 | 3 | 0x007 | L R C |
| 3 | 4 | 0x033 | 쿼드 |
| 4 | 4 | 0x107 | L R C 후방C |
| 5 | 5 | 0x607 | L R C 사이드 |
| 6 | 6 | 0x03F | 5.1 후방 |
| 7 | 6 | 0x60F | 5.1 사이드 |
| 8 | 8 | 0x0FF | 7.1 후방 |
| 9 | 8 | 0x63F | 7.1 사이드 |

바꿀 때 `nBlockAlign = (nChannels·wBitsPerSample + 7)/8`(`0x1400cf7bb–0x1400cf7cc`),
`nAvgBytesPerSec = nBlockAlign · nSamplesPerSec`(`0x1400cf7d4–0x1400cf7dd`) 을 다시 계산하고,
포맷이 `WAVE_FORMAT_EXTENSIBLE`(`cmp word [wf], 0xfffe` @`0x1400cf719`)이면 `+0x16` 의
`dwChannelMask` 도 바꾼다. 이때 `StreamFlags` 는 `0x20000` 으로 **고정**이다
(`0x1400cf804`, `0x1400cf848`).

성공하면 `GetService(IID_IAudioCaptureClient, …)`(`0x1400cf8bd`, GUID `0x140482ab8` =
`C8ADBD64-E71E-48A0-A4DE-185C395CD317`) → `Start()`(`0x1400cf8ca`).

### 1.5 폴 루프와 무음

오디오 스레드(`0x1400d02b0`)는 매 바퀴 `Sleep(AP+0x14)` 한다(`0x1400d0404`, 임포트
`0x140426170` = `KERNEL32!Sleep`). 기본값은 생성자 `0x1400c0ccf` 의 `0x21` = **33 ms**.

```
0x1400d146f  GetNextPacketSize(&n)                    ; vtable +0x28
0x1400d14a8  n == 0 이면 idle += 33 ms
0x1400d14ac  idle > 1000.0 ms → 출력 128 float 을 0 으로 memset      (0x1400d1f5b)
0x1400d1514  GetBuffer(&p, &frames, &flags, 0, 0)     ; vtable +0x18
0x1400d152b  flags & 2 (AUDCLNT_BUFFERFLAGS_SILENT) → 데이터 버리고 무음 처리
0x1400d1b19  ReleaseBuffer(frames)                    ; vtable +0x20  ← **패킷 전체**를 반납
```

**`ReleaseBuffer` 가 항상 패킷 전체를 반납한다는 점이 중요하다.** 창이 `W` 로 찬 뒤에
남은 프레임은 캐리로 넘어가지 않고 **버려진다**(`0x1400d154c` 의 `cmp r13d, N` → `jae` →
바로 반납). 즉 실물의 실효 홉은 창 길이가 아니라 **폴 간격 33 ms** 이고, 그중 앞
29 ms 만 분석에 쓰인다. 나머지 ~4 ms 는 매 폴마다 버려진다.

---

## 2. FFT

### 2.1 어떤 FFT 인가

플랜 객체의 `+0x60` 슬롯이 `transform(plan, in, out)` 이고 그걸 채널마다 한 번씩 부른다:

```
0x1400d1b87  call [plan+0x60]            ; (plan, L_in, L_out)
0x1400d1b93  call [plan+0x60]            ; (plan, R_in, R_out)   ← nChannels >= 2 일 때만
```

플랜 구성은 `0x1400d05dc` 에서 갈린다:

- `test r12, r12-1` → **N 이 2의 거듭제곱이면** FFTS 직행. `N ≥ 32` 는
  `0x140149100`(`ffts_static_transform_f`), 미만은 `0x140146aa0`/`0x140146ac0`/
  `0x140146b70`/`0x140146c90` 의 소형 커널. 정본이 기록한 어서션 `N == 32`
  (`0x14048b2a0`, 파일 `ffts_static.c` `0x14048b240`)는 이 `0x140148de5` 계열 안에 있다.
- 그 외 → **Bluestein(chirp-z)**. `M = 1 << (bsr(2N−1) + 1)`(`0x1400d0651–0x1400d065d`)
  길이의 FFTS 플랜을 만들고(`0x140145e60`), 처프 커널에 `1/M` 을 곱해 둔다
  (`0x1400d084b–0x1400d0853`) — 내부 역변환의 정규화를 커널로 흡수한 것이라
  **바깥에서 본 변환은 정규화 없는 길이 N DFT** 다.

§1.3 표대로 실무 레이트에서는 N 이 한 번도 2의 거듭제곱이 아니므로, **실물은 항상
Bluestein 경로**다(44.1 kHz → N=1920, M=4096 / 48 kHz → N=2089, M=8192).

### 2.2 입력은 실수가 아니라 복소다

샘플 적재 루프(`0x1400d15b0–0x1400d17c7` 스테레오, `0x1400d1880–0x1400d1a0e` 모노):

```
xmm1 = src[(i − base)·nChannels + ch]      ; float32 그대로
xmm1 = xmm1 · 127.0 + 127.0                ; 0x1400d15dd, 0x1400d15e2
buf[2i]     = xmm1                         ; 실수부
buf[2i + 1] = 1.0 / xmm1                   ; 0x1400d15ed  ← 허수부가 실수부의 역수
```

채널 0 은 `r15` 버퍼, 채널 1 은 `rbx`/`r14` 버퍼로 따로 간다. 즉 **채널당 독립 복소 FFT**
이지, 두 실수 신호를 한 복소 변환에 싣는 흔한 트릭이 아니다.

### 2.3 창 함수는 없다 — 있으면 여기 있어야 한다

적재 루프의 샘플당 연산은 `mulss`(127) + `addss`(127) + `divss` 셋뿐이다.
**계수 테이블 인덱싱이 한 번도 없다** — `.rdata` 에서 해닝/블랙먼 계수를 역산할 대상 자체가
없다. 유일한 "창" 은 길이 자르기다:

```
0x1400d1491  xmm10 = 10.0f / 30.0f              ; = 0.33333334
0x1400d1496  xmm10 = xmm10 · float(N)
0x1400d149b  xmm11 = float(N) − xmm10
0x1400d14a0  W = (int)xmm11                     ; 1920 → 1280
```

(세 상수는 매 바깥 루프에서 `0x1400d056a–0x1400d057c` 이 다시 읽는다 — `divss` 가
`xmm10` 을 파괴하므로 그렇게 하지 않으면 매 바퀴 1/3 씩 줄어든다.)

오버랩도 없다. FFT 를 커밋한 직후 채움 카운터를 0 으로 되돌린다(`0x1400d1e21`
`xor r13d,r13d`, 무음 경로는 `0x1400d1f58`).

### 2.4 패딩은 0 이 아니라 127 이다 — 그런데 결과는 0 패딩과 같다

버퍼는 매번 새로 할당되고(`0x1400d13a3` 외 3곳, `N·2·4` 바이트) 곧바로 전 구간을
**무음 값**으로 채운다:

```
0x1400d141d  buf[2k]     = 0x42FE0000   ; 127.0f       = 127·(0 + 1)
0x1400d1425  buf[2k + 1] = 0x3C010204   ; 0.0078740157 = 1/127
```

그래서 `[W, N)` 구간은 "무음이 이어진" 상태이지 계단이 아니다. 결과적으로 버퍼는
`127 + 127·s(t)·1[t<W]` 이고, 상수 127 은 **길이 N 전체에 걸린 상수**라 DFT 에서
`k = 0` 에만 떨어진다. 소비 구간이 `i ≥ 1`(`0x1400d1c17` 의 `ebx = 1`)이므로
**우리의 0 패딩과 비교해 소비 빈에서 차이가 없다.** 즉 `+127` 은 게인이 아니라
"패딩과 신호의 기준선을 맞추는 오프셋" 이고, 실제 게인 127 은 `×127` 쪽이다.

### 2.5 역수 허수부의 크기

`im = 1/(127(1+s))` 는 작은 `s` 에서 `(1/127)(1 − s + s² − …)` 다. 앞항은 실수부와
같은 스펙트럼을 `1/127²` 로 축소해 얹으므로 진폭에 `sqrt(1 + 127⁻⁴)` 배(≈ +2e-9),
나머지는 고조파 왜곡이다. `N=1920 · W=1280` 에서 "127×실수 신호 + 0 패딩" 대비 실측:

| 자극 | 최대 편차 / 최대 빈 |
| --- | --- |
| 사인 A=0.9 | 5.3e-5 (−85.5 dB) |
| 화이트노이즈 (피크 0.975) | 1.2e-4 (−78.2 dB) |
| 4음 합성 (피크 0.955) | 4.9e-5 (−86.1 dB) |
| 사인 A=0.999 | 2.1e-3 (−53.4 dB) |

`s → −1` 에서 `127(1+s) → 0` 이라 역수가 발산하는 것이 유일한 위험이고, 그래서
소비 루프에 `Inf/NaN → 0` 가드(`0x1400d1c62–0x1400d1c77`)가 붙어 있다.
**우리는 재현하지 않는다** — 최대 −53 dB 이고 정상 자극에서는 −85 dB 다.

---

## 3. 밴드 축약

### 3.1 소비 루프 (`0x1400d1bff–0x1400d1d11`)

채널 `c = 0 … min(nChannels, 2) − 1`(`0x1400d1be2`), 빈 `i = 1 … B−1`:

```
p        = re[i]² + im[i]²                          ; 0x1400d1c46–0x1400d1c5e
if (exp(p) == 0xFF) p = 0                           ; 0x1400d1c66  Inf/NaN 배제
t        = (i − 1) / (B − 1)                        ; 0x1400d1c8b
raw      = (int)(powf(t, AP+0xE4) · 64.0)           ; 0x1400d1c90, 0x1400d1c95, 0x1400d1c9d 절삭
raw      = raw mod 64  (부호 보존)                   ; 0x1400d1ca1–0x1400d1cae
band     = min(raw, prev + 1);  prev = band         ; 0x1400d1cbb–0x1400d1cbf
w        = AP+0xE8 − (1 − AP+0xE8)·cosf(π·t)        ; 0x1400d1cb0, 0x1400d1cc2, 0x1400d1ccd–0x1400d1cdb
v        = sqrt(w · p)                              ; 0x1400d1ce2–0x1400d1cee
out[c][band] = max(out[c][band], v)                 ; 0x1400d1d04
```

`π` 는 `0x140492834`, `64.0` 은 `0x1404928e4` 에서 확인했다. `t` 가 **밴드가 아니라 빈**의
정규화값이라는 것(`xmm7` 이 `powf` 호출을 넘어 살아남는 non-volatile 이라는 점)까지 그대로다.

`nChannels == 1` 이면 오른쪽 밴드 배열이 memset 상태로 남아 **우 채널 전 밴드 0** 이다.

### 3.2 밴드 → 빈 대응표 (B = 640, 44.1 kHz)

| 밴드 | 빈 | 개수 | Hz |
| --- | --- | --- | --- |
| 0…28 | 1…29 | 각 1 | 23.0 … 689.1 |
| 29 | 30–31 | 2 | 689.1 – 735.0 |
| 30 | 32–36 | 5 | 735.0 – 849.8 |
| 31 | 37–40 | 4 | 849.8 – 941.7 |
| 32 | 41–46 | 6 | 941.7 – 1079.5 |
| 33 | 47–51 | 5 | 1079.5 – 1194.4 |
| 34 | 52–58 | 7 | 1194.4 – 1355.2 |
| 35 | 59–64 | 6 | 1355.2 – 1493.0 |
| 36 | 65–72 | 8 | 1493.0 – 1676.7 |
| 37 | 73–80 | 8 | 1676.7 – 1860.5 |
| 38 | 81–89 | 9 | 1860.5 – 2067.2 |
| 39 | 90–98 | 9 | 2067.2 – 2273.9 |
| 40 | 99–108 | 10 | 2273.9 – 2503.6 |
| 41 | 109–119 | 11 | 2503.6 – 2756.2 |
| 42 | 120–131 | 12 | 2756.2 – 3031.9 |
| 43 | 132–143 | 12 | 3031.9 – 3307.5 |
| 44 | 144–157 | 14 | 3307.5 – 3629.1 |
| 45 | 158–171 | 14 | 3629.1 – 3950.6 |
| 46 | 172–186 | 15 | 3950.6 – 4295.2 |
| 47 | 187–203 | 17 | 4295.2 – 4685.6 |
| 48 | 204–220 | 17 | 4685.6 – 5076.1 |
| 49 | 221–239 | 19 | 5076.1 – 5512.5 |
| 50 | 240–258 | 19 | 5512.5 – 5948.9 |
| 51 | 259–279 | 21 | 5948.9 – 6431.2 |
| 52 | 280–301 | 22 | 6431.2 – 6936.6 |
| 53 | 302–324 | 23 | 6936.6 – 7464.8 |
| 54 | 325–349 | 25 | 7464.8 – 8039.1 |
| 55 | 350–375 | 26 | 8039.1 – 8636.2 |
| 56 | 376–403 | 28 | 8636.2 – 9279.4 |
| 57 | 404–432 | 29 | 9279.4 – 9945.5 |
| 58 | 433–462 | 30 | 9945.5 – 10634.5 |
| 59 | 463–494 | 32 | 10634.5 – 11369.5 |
| 60 | 495–528 | 34 | 11369.5 – 12150.5 |
| 61 | 529–563 | 35 | 12150.5 – 12954.4 |
| 62 | 564–600 | 37 | 12954.4 – 13804.2 |
| 63 | 601–639 | 39 | 13804.2 – 14700.0 |

**선형도 로그도 아니다.** 저역 1:1 구간은 별도 규칙이 아니라 `prev+1` 클램프의 결과이고,
그 길이(여기서는 29)는 `B` 에 따라 변한다 — `B ∈ 623…688` 에서만 29 다.
빈 0(DC, 0–23 Hz)은 어느 밴드에도 안 들어간다.

### 3.3 좌/우 분리 규약

채널별로 **입력 버퍼도 출력 밴드 배열도 완전히 분리**돼 있다. 프로듀서 출력은
`[rbp+0x40]`(왼쪽 64 float)과 `[rbp+0x140]`(오른쪽 64 float)이 붙어 있는 128 float 이고,
그대로 `AP+0` 의 0x200 바이트 버퍼로 복사된다(`0x1400d1e30`, `0x1400d1eb0`).
모노 입력이면 오른쪽 절반은 0 이다(`0x1400d1e92` 의 `cmovge` 가 소스 오프셋을 0 으로 둔다).

### 3.4 게인 (`0x1400d1d25–0x1400d1df6`)

```
g = AP[0x0C] · 0.001 · float(B) / (float(N) · 0.5)
band[0..127] *= g                                  ; 4 float × 16 회 × 2 배열
```

`AP[0x0C]` 는 생성자 `0x1400c0cc4` 가 심은 `1.0`, `0.001` 은 `0x140492608`, `0.5` 는
`0x1404926c0`, 루프 상한 `0x40`(=64 밴드)은 `0x1400d1df3`.

이 `g` 는 **비정규화 DFT 진폭**에 걸리고, 시간영역에서 이미 127 이 곱해져 있다. 진폭을
`|DFT|/N` 규약으로 옮기면

```
gain_norm = 127 · 0.001 · B / (N/2) · N = 127 · 0.002 · B = 0.254 · B  →  B=640 에서 162.56
```

이고 `N` 이 상쇄된다. 창 길이가 항상 `2N/3` 이라 **밴드 레벨은 N 과도 무관**해지고, 결국
만스케일 사인 하나의 밴드 값은 `127·0.001·B·(2/3)·A = 54.19·A`(B=640)다.
`AudioSpectrum.gain = 162.56` 이 B=640 을 고정값으로 담고 있는 것이 맞다 —
우리 `B`(627/683)는 "같은 주파수 구간을 다른 격자로 덮는 개수" 이지 실물의 B 가 아니다.

### 3.5 소비단 버퍼의 ×3 은 [Left | Right | Mono] 다

세 버퍼 `0x300`/`0x180`/`0xc0` 바이트(`0x14011540c`, `0x140115420`, `0x140115434`)의
셋째 사분면이 무엇인지 확정했다:

```
0x1401126a4  xmm0 = buf[i + 0x100/4]     ; = buf[i + 64]   (Right)
0x1401126ad  xmm0 += buf[i]              ;                  (Left)
0x1401126b6  xmm0 *= xmm6 (= 0.5)
0x1401126ba  buf[i + 0x200/4] = xmm0     ; = buf[i + 128]  (Mono)
```

즉 64밴드 버퍼는 `[L 0..63 | R 64..127 | M 128..191]` 이고, 32/16 밴드 축약은 192 → 96 → 48
로 **세 사분면을 통째로** 접는다(`0x1401128d1` 의 `cmp r8d, 0x60`).

**mono 사분면은 셰이더 유니폼이 아니다.** 유니폼 등록표(`0x140003df7–0x140003e9e`)에
오디오는 정확히 6개뿐이다 — `g_AudioSpectrum{16,32,64}{Left,Right}`(id 0x62…0x67).
동봉 셰이더의 `g_AudioSpectrum16`(접미사 없음) 2건은 둘 다 **주석 처리된 줄**이라
바인딩 대상이 아니다. 이 사분면의 읽는 쪽은 찾지 못했다 — 우리 구현이
`Output.spec*` 에 그대로 두되 유니폼으로 노출하지 않는 현재 상태가 맞다.

### 3.6 무음 게이트는 채널 0 만 본다

```
0x1400d1a15  xmm5 = AP+0x10 (threshold)
0x1400d1a1b  threshold <= FLT_EPSILON 이면 게이트 비활성
0x1400d1a36  stride = nChannels · 4                  ; ← 채널 0 만 훑는다
0x1400d1a95  running max, 시작값 0.0 (부호 있는 max, 절댓값 아님)
0x1400d1ad6  threshold > peak → 이 창을 무음 처리
```

우리 `windowPeak` 은 좌·우 둘 다 봤다. 실물은 **왼쪽만** 본다 — 하드 우측 팬 신호는
실물에서 무음으로 판정된다. 기본 threshold 가 0(비활성)이라 실사용 영향은 없지만,
파리티는 파리티다. §5 에서 맞췄다.

---

## 4. Waple 대조 — 어긋난 것

| # | 항목 | 실물 | 종전 Waple | 영향 | 조치 |
| --- | --- | --- | --- | --- | --- |
| 1 | 44.1 kHz 미만 상한 주파수 | `639·rate/1920`(32 k → 10650 Hz) | `topFrequency` 상수 14677 Hz → B=940 | 32 kHz 입력에서 밴드 배치가 통째로 어긋난다(상한 37% 초과) | **정정**(§5) |
| 2 | 무음 게이트 피크 | 채널 0 만 | L·R 최대 | 하드 팬 신호에서 판정이 갈린다(기본값에선 비활성) | **정정**(§5) |
| 3 | 창 누적기 위치 | — | `WapleRender`(리눅스 테스트 불가) | 회귀를 macOS CI 왕복으로만 잡을 수 있었다 | **WapleCore 이관**(§5) |
| 4 | FFT 길이 | `int(max(rate/44100,1)·1920)`, 복소, Bluestein | 2048 고정, packed-real | 빈 폭 21.53/23.44 vs 22.97 Hz. 밴드 경계 최대 0.92빈(48 k)·2.00빈(44.1 k) 이동 | **유지** — vDSP 가 임의 길이 실수 FFT 를 못 한다. 주파수 축을 맞추는 현행 타협이 최선 |
| 5 | 실효 홉 | 폴 33 ms, 창 29 ms, 나머지 폐기 | 푸시 콜백 + 전량 캐리(홉 = 창 28.5 ms) | 시간 지터만 다르다. 우리 쪽이 샘플을 안 버린다 | **유지** — 도달 없는 열화 |
| 6 | 시간영역 허수부 | `1/(127(1+s))` | 없음 | ≤ −85 dB(최악 −53 dB) | **유지**(§2.5) |
| 7 | 패딩 값 | 127 / (1/127) | 0 | 소비 빈에서 정확히 등가 | **유지**(§2.4) |
| 8 | 레이트 요청 | 안 함(GetMixFormat) | 48000 요청 + 실측 사용 | 없음 — 우리도 실측값으로 비닝한다 | 유지 |
| 9 | 모노 입력 우채널 | 전 밴드 0 | 좌를 복제 | 모노 장치에서 갈린다 | **유지** — 우리 쪽이 낫고, 소비단이 L/R 을 평균하므로 실물이 오히려 −6 dB 다. 여기 적어 둔다 |
| 10 | 창 길이 절삭 위치 | `int(N − (10/30)·N)` — 차에 절삭 | `n − n/3` — 몫에 절삭 | `N % 3 ≠ 0` 이면 1 샘플. N=2048 에서 1366 vs 1365 | **정정**(§5) |

---

## 5. 이번 라운드에 옮긴 것 / 고친 것

**WapleCore(리눅스 테스트 가능)로 이관·신설:**

- `AudioSpectrum.windowLength(fftLength:)` — 절삭 위치를 실물에 맞췄다(`0x1400d149b`-`0x1400d14a0`
  의 `subss` → `cvttss2si`) → **어긋남 #10 해소**. 우리 N=2048 의 창이 1366 → **1365** 가 된다.
  절대 레벨 오라클(`testAbsoluteOutputLevelOfFullScaleSine`)은 0.5% 허용오차 안에서 그대로 통과한다
  (한 샘플은 0.073%).
- `AudioSpectrum.engineFFTLength(sampleRate:)` — 실물 N. float32 순서까지 그대로.
- `AudioSpectrum.engineWindowLength(sampleRate:)` — 실물 W.
- `AudioSpectrum.engineTopFrequency(sampleRate:)` — `bin(B−1)` 의 주파수. 44.1 kHz 미만
  클램프를 포함한다. `binCount(fftLength:sampleRate:)` 가 이걸 쓰도록 바꿨다 → **어긋남 #1 해소**.
- `AudioSpectrum.engineRawBandGain(binCount:fftLength:)` — 실물 게인식 그대로.
  `sampleBias(=127) · engineRawBandGain(640, N) · N == gain(162.56)` 을 테스트가 고정한다.
- `AudioWindowAccumulator` — `WapleRender` 에서 그대로 옮겨 왔다(동작 무변경).
  `WapleRender` 는 타입 별칭으로 재수출하므로 호출부·기존 테스트는 그대로다.
- `AudioCaptureGate` — 무음 게이트 순수부. `windowPeak` 이 **채널 0 만** 보도록
  실물에 맞췄다 → **어긋남 #2 해소**. 폴 간격 33 ms·무패킷 1,000 ms 상수도 여기 둔다.

**경계(리눅스에서 못 도는 것)** — `SystemAudioSpectrumProvider` 에 남는다:
`SCStream` 구성/시작/정지, `CMSampleBuffer` → 채널 분리, `vDSP` FFT, `UserDefaults` 설정.
이 넷은 macOS 전용 API 라 `swift test`(macOS)에서만 검증된다.

---

## 6. 도달 — 오디오반응을 쓰는 자산

> **[정정 2026-08-21] 7개가 아니라 6개다.** 아래 표에 `neon_sunset` 이 들어가 있었는데
> `neongrid.vert:16-17` 의 두 유니폼 선언은 **주석 처리된 줄**(`//uniform float …`)이고, 그 파일
> 어디에서도 오디오 토큰이 더 나오지 않는다(파일 전체 grep `Audio|audio` 2건 = 그 두 주석뿐).
> 바로 아래 "세다가 틀리기 쉬운 것" 절이 `techno` 에 대해 경고한 것과 **정확히 같은 함정**에
> 이 표 자신이 빠져 있었다. 주석 줄을 뺀 실사용 출현 수가 그 증거다 — `16Left` 32→**31**,
> `16Right` 12→**11**(빠진 각 1건이 `neongrid.vert` 다).

**세었더니 6개다.** 설치본 `/wallpaper_engine` 전수 grep 기준, 오디오 유니폼을 **실제로 읽는**
자산은 이게 전부다.

| 자산 | 유니폼을 읽는 파일 | 쓰는 유니폼 | 어떻게 쓰나 |
| --- | --- | --- | --- |
| `defaultprojects/audiophile` | `audiophile.vert` | 16 L/R | `L[int(u·16+0.01)] + L[int(u·16+0.51)]`, `mix(L,R,step(0,a_Position.x))`, ×0.5, saturate — **16밴드 전부** |
| `defaultprojects/audiophile` | `audiophileglow.vert` | 16 Left | `min(1, L[0])` — **밴드 0 하나만** |
| `defaultprojects/demon_core` | `core.vert` | 16 Left | `Σ L[0..15]/16` 로 색, 그리고 `pow(saturate(L[spectrumIndex])·0.75, 2)` 로 변위 — **전 밴드 + 인덱스 1개** |
| `defaultprojects/razer_bedroom` | `shaders/effects/pulse.vert` | 16 L/R | `CreateAudioResponse` → varying `v_AudioPulse` |
| `assets/effects/pulse` | `shaders/effects/pulse.vert` | 16 L/R | `CreateAudioResponse` → varying `v_Pulse` |
| `assets/effects/shake` | `shaders/effects/shake.vert` | 16 L/R | `CreateAudioResponse` → varying `v_AudioPulse` |
| `assets/zcompat/scene/shaders/2084198056` | `Simple_Audio_Bars.frag` | 16 **또는** 32 **또는** 64 L/R | `RESOLUTION` 콤보로 셋 중 하나만 — §6.2 |

> `razer_bedroom` 의 `pulse.frag` 는 종전 표에 같이 적혀 있었지만 **유니폼을 읽지 않는다** —
> `v_AudioPulse` varying 을 받을 뿐이다(`grep g_AudioSpectrum pulse.frag` = 0건). 자산 수는
> 그대로지만 "어느 파일이 유니폼을 읽는가" 열은 `.vert` 하나다.

**세다가 틀리기 쉬운 것 셋을 갈라 둔다.**

- `supportsaudioprocessing` 은 **능력 플래그**이지 사용이 아니다. 설치본 전체에서 이 키는 5건
  (프로젝트 4개: `audiophile` 2파일 · `demon_core` · `corsair_o_tron` · `techno`)뿐이고, **양방향으로
  어긋난다** — `corsair_o_tron` 은 `true` 인데 셰이더가 오디오 유니폼을 한 번도 안 읽고,
  `razer_bedroom` 은 키가 **아예 없는데** 셰이더가 읽는다.
- 주석 처리된 선언: `techno/technohex.vert:7`, `audiophile/audiophileglow.vert:23`,
  `neon_sunset/neongrid.vert:16-17`. 느슨한 grep 은 이 셋을 다 세어 자산 수를 8개로 부풀린다.
- 씬 레이어 프로퍼티 `"audioprocessing"` 은 설치본 전체에서 **0건**이다. 즉 실물 경로는 전부
  셰이더 유니폼이다.

유니폼 출현 빈도(주석 줄 제외, 설치본 `ui/` 제외 전수): `g_AudioSpectrum16Left` **31** ·
`16Right` **11** · `32Left/Right` 각 2 · `64Left/Right` 각 2 — **실사용은 16밴드에 몰려 있다**.
그리고 이름 문자열은 바이너리 `.rdata` 에 여섯 개가 **각각 한 번씩만** 있다(§6.3).

리포에 실제로 동봉된 자산(`Sources/WapleRender/Resources/WEAssets`, 2,940 파일) 기준으로는
**3개**로 더 좁아진다:

| 파일 | 쓰는 유니폼 |
| --- | --- |
| `effects/pulse/shaders/effects/pulse.vert` | 16 L/R |
| `effects/shake/shaders/effects/shake.vert` | 16 L/R |
| `zcompat/scene/shaders/2084198056/Simple_Audio_Bars.frag` | `RESOLUTION` 이 고르는 한 벌 |

동봉 `assets/shaders/` 137파일은 설치본과 **md5 전건 동일**하다(2026-08-21 재확인, 137/137).
그 137개 중 오디오 유니폼을 읽는 것은 **0개**다 — 오디오는 전부 `effects/`·`zcompat/`·`projects/`
쪽에 있다.

### 6.1 그런데 기본 상태에서는 아무도 안 켠다

`AUDIOPROCESSING` 은 **콤보**이고 세 셰이더 전건이 `"default":0` 으로 선언한다
(`// [COMBO] {"material":"ui_editor_properties_audio_response","combo":"AUDIOPROCESSING","type":"audioprocessingoptions","default":0}`).
0 이면 `#if AUDIOPROCESSING` 블록이 통째로 컴파일에서 빠져 유니폼 자체가 없다.

**전수 실측(2026-08-21).** 설치본(`ui/` 제외) + 동봉 = **JSON 3,741개**(그중 **63개는
엄격 파서가 거부해 JSONC 관용 파싱 — 주석·트레일링 콤마**)를 전수로 걸었다:

| 찾은 것 | 건수 | 범위 |
| --- | --- | --- |
| `combos` 안의 `AUDIOPROCESSING` (또는 `AUDIO*` 아무거나) | **0** | 3,741 JSON |
| `constantshadervalues` 안의 `audiobounds`/`audioexponent`/`audioamount`/`frequencymin`/`frequencymax` | **0** | 3,741 JSON |
| 파티클 `audioprocessingmode`/`…frequencystart`/`…frequencyend`/`…bounds`/`…exponent` | **0** | 두 트리 전 파일형식 |
| 서로 다른 `combos` 키 | 66종 (`REFRACT` 86 · `VERTICAL` 46 · `RENDERING` 32 …) | 3,741 JSON |

즉 **`AudioResponse.compute` 도 `ParticleSystem.AudioProcessing` 도 동봉·설치 자산만으로는
한 번도 활성화되지 않는다.** 활성화 경로는 오직 (a) 에디터가 씬에 `combos` 를 써 넣는 것,
(b) 워크샵 자산이다 — 둘 다 이 저장소 안에 없다. **그래서 이 두 경로는 골든 프레임으로
회귀를 잡을 수 없고, 순수 계산 테스트로만 잠긴다**(§7 참조).

### 6.2 `Simple_Audio_Bars` 의 `RESOLUTION` 기본값은 32 다

```
// [COMBO] {"material":"Frequency Resolution","combo":"RESOLUTION","type":"options",
//          "default":32,"options":{"16":16,"32":32,"64":64}}
```

`#if RESOLUTION == 16/32/64` 가 유니폼 선언 자체를 가르고, 본문은 `#define u_AudioSpectrumLeft …`
로 하나만 별칭한다. 따라서 **한 변형은 셋 중 한 벌만 바인딩한다.** 종전 표기 "16·32·64 L/R 전부"
는 소스에 세 벌이 **적혀 있다**는 뜻이지 동시에 쓰인다는 뜻이 아니다.

결과적으로 **동봉·설치 자산의 기본 상태에서 `g_AudioSpectrum64Left/Right` 의 도달은 0 이고,
`32Left/Right` 의 도달은 이 자산 하나**다. 16밴드만 실사용에 몰려 있다는 위 결론은 그대로다.

### 6.3 유니폼 등록표 — id 0x62…0x67 (재현)

이름 문자열 6개는 `.rdata` 에 각각 정확히 한 번씩 있다(UTF-16LE 사본 0건):

| 이름 | 문자열 VA | 등록 사이트 | **id** |
| --- | --- | --- | --- |
| `g_AudioSpectrum16Left` | `0x14048da38` | `0x140003df7` | `0x62` (98) |
| `g_AudioSpectrum16Right` | `0x14048da20` | `0x140003e17` | `0x63` (99) |
| `g_AudioSpectrum32Left` | `0x14048da08` | `0x140003e37` | `0x64` (100) |
| `g_AudioSpectrum32Right` | `0x14048d9f0` | `0x140003e57` | `0x65` (101) |
| `g_AudioSpectrum64Left` | `0x14048da98` | `0x140003e77` | `0x66` (102) |
| `g_AudioSpectrum64Right` | `0x14048da80` | `0x140003e97` | `0x67` (103) |

xref 는 `.text` 전 구간 disp32 바이트 스캔으로 떴다(브리프 함정 12 — `lea` 선형 스캔이 아니다).
6개 이름 각각에 xref가 **정확히 하나씩**이다.

> **함정 16 이 여기서 실제로 발동한다.** 등록 패턴은
> `lea r8,[rsp+X]` / `mov dword [rsp+X], id` / `lea rdx, <이름>` / `lea rcx, <슬롯>` / `call 0x14016f7a0`
> 이고, **id 스토어가 자기 이름 `lea` 보다 앞에 온다**. "이름 뒤에 오는 `mov imm`" 으로 순진하게
> 읽으면 표 전체가 한 칸 밀려 `16Left`→0x63 이 된다. 위 표는 앞쪽 imm 을 짝지은 것이고,
> 경계 검증으로 `0x61`→`g_LightSkylightColor`, `0x68`→`g_PointerPositionLast` 가 맞는지 확인했다.

오디오 유니폼은 **정확히 이 6개뿐**이다 — mono 사분면에 대응하는 유니폼은 등록표에 없다(§3.5 확인).

---

## 7. 2026-08-21 전수 재대조 — 찾은 것

앞의 §1–§5 는 **재검증만 했다**(아래 §7.3). 새로 나온 것은 이 절이 전부다.

### 7.1 [결함] 32밴드 유니폼이 MAX 가 아니라 평균으로 나간다

`Sources/WapleRender/SceneRenderer.swift` 의 `setSpectrum64(left:right:)`(2026-08-21 기준 2284-2289 — 이 파일은 동시 편집 중이라 줄번호보다 심볼로 찾아라):

```swift
public func setSpectrum64(left: [Float], right: [Float]) {
    left64  = Array(left.prefix(64))  + [Float](repeating: 0, count: max(0, 64 - left.count))
    right64 = Array(right.prefix(64)) + [Float](repeating: 0, count: max(0, 64 - right.count))
    left32  = (0..<32).map { (left64[$0 * 2]  + left64[$0 * 2 + 1])  / 2 }   // ← 평균
    right32 = (0..<32).map { (right64[$0 * 2] + right64[$0 * 2 + 1]) / 2 }   // ← 평균
}
```

실물은 **MAX** 다. `0x1401128e0` 의 원시 바이트를 직접 읽어 확인했다:

```
0x1401128e0  f3 0f 5f 04 8b     maxss xmm0, dword ptr [rbx + rcx*4]     ; spec32[j] = max(spec64[2j], spec64[2j+1])
0x140112b6f  f3 0f 5f 00        maxss xmm0, dword ptr [rax]             ; spec16[j] = max(spec32[2j], spec32[2j+1])
```

두 번째 접기(32→16)는 `0x140112c94` 이후에 **완전히 언롤된 `maxss` 사슬**로도 한 번 더 나온다
(`maxss [rax+0x5c],[rax+0x58]` → `[rdi+0x2e0]+0x2c` …) — 독립 증거 둘이다.

**요점은 `AudioSpectrumProcessor` 가 이미 옳게 계산해 둔 값을 호출부가 버리고 다시 접는다는 것이다.**
`process()` 가 반환하는 `Output.spec32` 는 `reduce()` 에서 `Swift.max` 로 접힌 96 float 인데,
`SceneRenderer` 는 `out.left64`/`out.right64` 만 받아 자기 식으로 32밴드를 만든다. 원인은 단순하다 —
`Output` 에 `left16/right16/left64/right64` 는 있었는데 **`left32`/`right32` 가 없었다.**

**영향 범위.** 인접 두 밴드 중 하나만 뜨는 신호(순음 저역이 정확히 그 모양)에서 평균은 MAX 의
**절반**이다. 도달은 `g_AudioSpectrum32Left/Right` 를 읽는 자산 — 설치본에서 `Simple_Audio_Bars`
하나이고, 그 자산의 `RESOLUTION` **기본값이 32** 라 하필 기본 경로다(§6.2). 16밴드 유니폼은
`out.left16/right16` 을 그대로 쓰므로 **영향 없다**. 64밴드도 무변환이라 영향 없다.

**조치.** `Output.left32`/`right32`/`mono64`/`mono32`/`mono16` 접근자를 신설했다
(`Sources/WapleCore/AudioSpectrumProcessor.swift`). `SceneRenderer` 는 소유 밖이라 못 고쳤다 —
정정안은 아래 §7.2. 신설 접근자와 "평균이면 정확히 2배 갈린다" 는 성질은
`AudioSpectrumProcessorTests` 의 `testLeft32AndRight32SliceTheMaxReducedQuadrants` ·
`test32BandFoldIsMaxAndDivergesFromMeanByTwoX` 가 고정한다(돌연변이로 둘 다 잡히는 것 확인).

### 7.2 넘기는 정정안 (소유 밖)

**(a) `Sources/WapleRender/SceneRenderer.swift`** — 32밴드를 소비단 출력에서 직접 받는다.

```swift
// 공급자 콜백(2026-08-21 기준 1950): setSpectrum64 대신 32밴드까지 넘긴다
renderer.setSpectrumBands(out)

// setSpectrum64 를 대체: 평균을 걷어내고 MAX 로 접힌 값을 슬라이스만 한다
public func setSpectrumBands(_ out: AudioSpectrumProcessor.Output) {
    left64 = out.left64;  right64 = out.right64
    left32 = out.left32;  right32 = out.right32     // 0x1401128e0 이 maxss 다 — 평균이 아니다
}
```

`spec` 이 128 미만인 모노 폴백 경로(같은 클로저의 `else` 가지)는 `AudioSpectrum16.groupMax(spec, binCount: 32)` 를 쓰면
같은 규약이 된다(`downsample16` 과 동일 프리미티브).

**(b) `Sources/WapleRender/TextScriptEngine.swift` 의 `__setAudioData` 안 `avg(...)` 호출 4줄**(2026-08-21 기준 1763-1766) — 씬 스크립트의
`__audioBuffer.left32/right32/left16/right16` 도 `avg(...)` 로 접는다. `g_AudioSpectrum32Left` 등이
2797-2800 에서 그 배열을 별칭하므로 **셰이더 유니폼과 값이 갈린다**. 다만 WE 의 JS
`engine.audioBuffer` 축약 규약을 실물에서 확인하지 못했다 — **[미해결]**. 유니폼 별칭
(2797-2800)만이라도 `maxss` 규약으로 맞추는 것이 정합적이지만, 근거 없이 바꾸지 말고 먼저
`registerAudioBuffers` 경로를 떠 봐야 한다.
>
> **[2026-08-21 2차 · 해소]** 그 경로를 떴다 — §8.3. `registerAudioBuffers` 는 `scenescript64.dll`
> 에 있고(`0x181655170–0x18165580f`), **아무것도 접지 않는다**. 스크립트가 보는 `left/right` 는
> 소비단이 `maxss` 로 접어 둔 값 그대로이고 셋째 배열의 이름은 `average`(= mono 사분면)다.
> 즉 위 `avg(...)` 4줄은 **MAX 여야 한다**. 정정안 전체는 §8.5(a).

**(c) `Sources/WapleRender/SceneRendererResources.swift` 의 `audioParams(for:)`**(2026-08-21 기준 2015-2035) — `audioParams` 의 폴백이
`pulse.vert` 의 선언 기본값만 담고 있다. **`shake.vert` 는 `audiobounds` 기본값이 다르다**:

| 셰이더 | `frequencymin` | `frequencymax` | `audioexponent` | `audiobounds` | `audioamount` |
| --- | --- | --- | --- | --- | --- |
| `assets/effects/pulse` | 0 | 1 | 1.0 | **`"0.5 1.0"`** | 1 |
| `projects/…/razer_bedroom` | 0 | 1 | 1.0 | **`"0.5 1.0"`** | 1 |
| `assets/effects/shake` | 0 | 1 | 1.0 | **`"0.0 1.2"`** | 1 |

Waple 은 셰이더 어노테이션 기본값을 파싱하지 않고 `?? [0.5, 1.0]` 을 하드코딩하므로, `shake` 를
`audiobounds` 없이 쓰는 이펙트 인스턴스는 실물과 갈린다. `bounds` 가 `(0.0, 1.2)` 면 `smoothstep`
의 기울기와 하한이 모두 다르다 — 작은 신호에서 실물은 반응하고 우리는 0 이다.
**도달은 현재 0 이다**(§6.1 — `constantshadervalues` 에 오디오 키가 0건이고 콤보도 0건),
그래서 무회귀 정정이다. 정공법은 셰이더별 어노테이션 기본값을 읽는 것이고, 최소 조치는
이펙트 이름이 `shake` 일 때만 `(0.0, 1.2)` 로 갈아 주는 것이다.

> **[2026-08-21 2차]** 이 표를 `AudioResponse.declaredDefaults(effectName:)` 로 코어에 옮기고
> 테스트로 잠갔다(`Sources/WapleCore/AudioResponse.swift`). 호출부 한 줄 정정안은 §8.5(b).
> 전수 재확인: `audiobounds` 를 선언하는 파일은 설치본(`ui/` 제외) **3개**, 동봉 `WEAssets`
> **2개**뿐이고 `uniform vec2 g_AudioBounds` 선언도 같은 3줄이라 형제 키는 없다.

### 7.3 `scripts/spec/measure_effect_fbo_audio.py` 가 **검사하지 않는** 것

그 스크립트의 오디오 관련 하드 검사는 **`AP_CONSTANTS` 4건 + `BYTE_CHECKS` 12건**(전체 14건 중
`0x1401E7586`/`0x1401E7590` 두 건은 이펙트 FBO 쪽)이다. 16건 전부를 이번에 **독립적으로 다시 읽어
전건 일치**를 확인했다. 그 밖은 `보고` 등급이거나 아예 안 본다:

| 영역 | 스크립트가 보나 | 이번에 확인했나 |
| --- | --- | --- |
| 밴드 축약 `maxss` `0x1400d1d04` | ✅ 바이트 | ✅ 재확인 |
| 창 길이 4명령 `0x1400d1491`–`0x1400d14a0` | ✅ 바이트 | ✅ 재확인 |
| 패딩 `127.0` / `1/127` | ✅ 바이트 | ✅ 재확인 |
| 생성자 상수 4개 + `mov rdi,rcx` | ✅ 바이트+값 | ✅ 재확인 |
| **N·B 유도** (`0x1400cf5ec` `divss …,44100` / `comiss`·`ja` 클램프 / ×64 ×30 / `cvttss2si`) | ❌ | ✅ 디스어셈블 |
| **시간영역 `×127`,`+127`,`1/x`** (`0x1400d15dd`/`15e2`/`15ed`) | ❌ | ✅ 디스어셈블 |
| **`p = re²+im²`** 와 인터리브 스트라이드 (`0x1400d1c40`–`c5e`) | ❌ | ✅ 디스어셈블 |
| **Inf/NaN → 0 가드** (`0x1400d1c62`–`c77`, `and eax,0x7f800000`) | ❌ | ✅ 디스어셈블 |
| **밴드 매핑 전체** (`t=(i−1)/(B−1)`, `powf`, ×64, 절삭, 부호보존 `% 64`, `cmovle` prev+1) | ❌(보고) | ✅ 디스어셈블 |
| **틸트** (`1−C` 를 `subss` 로 만드는 것, cos 인자가 **빈** 인덱스라는 것, `sqrt(w·p)`) | ❌(보고) | ✅ 디스어셈블 |
| **게인 식** (`AP[0x0C]·0.001·B/(N·0.5)`, `shufps` 브로드캐스트, `cmp ecx,0x40`) | ❌(보고) | ✅ 디스어셈블 |
| **채널 스트라이드 0x100** (좌 `[rbp+0x40]` / 우 `[rbp+0x140]`) | ❌ | ✅ 디스어셈블 |
| **무음 게이트** (`FLT_EPSILON` 활성 조건 · stride `nChannels*4` · 부호 max · 0 바닥) | ❌ | ✅ 디스어셈블 |
| **소비단 전체**(§3.5·`AudioSpectrumProcessor`): `0.333`·`1e-4`·리시드 1.0·상승 1.0/하강 −0.5·바닥 0.001·`20`·`40`·mono 0.5·**두 `maxss`** | ❌ **한 건도 안 본다** | ✅ 디스어셈블 |
| **유니폼 등록표**(id 0x62…0x67, 이름 6개) | ❌ | ✅ 바이트 스캔 + 디스어셈블(§6.3) |

**가장 큰 구멍은 소비단이다.** 정본 `spec/engine/effect-fbo-audio.json` 의 `engine.audio.pipeline`
항목은 `"smoothing": "생산 단계에 없음"` 이라고만 적고 **소비단 스테이지의 존재 자체를 기록하지
않는다**. `AudioSpectrumProcessor.swift` 가 상수 9개와 순서 10단계를 들고 있는데 정본에는 그 중
한 글자도 없다 — 즉 **spec 게이트가 소비단 회귀를 못 잡는다.** §7.1 의 결함이 이 공백에서 나왔다.

**넘기는 정정안(소유 밖 — `scripts/**`).** `BYTE_CHECKS` 에 최소 이 넷을 더하면 소비단 축약과
엔벨로프가 잠긴다(바이트는 전부 이번에 직접 읽어 확인했다):

```python
(0x1401128E0, "f30f5f048b", "`maxss xmm0,[rbx+rcx*4]` — spec32 = MAX(spec64 2쌍), 평균이 아니다"),
(0x140112B6F, "f30f5f00",   "`maxss xmm0,[rax]`       — spec16 = MAX(spec32 2쌍)"),
(0x1401126B6, "f30f59c6",   "`mulss xmm0, xmm6(0.5)`  — mono = 0.5·(L+R)"),
(0x140111EF7, "f30f1015ad0a3800", "`movss xmm2, [0x1404929ac]` = -0.5 — 엔벨로프 하강은 상승의 절반"),
```

그리고 `AP_CONSTANTS` 의 라벨이 이 문서와 **8 어긋나 있다**. 스크립트는 `0x1400C0D59` 를
"AudioProcessor+0xEC" 라 부르는데, 그 스토어의 베이스 `rdi` 는 **바깥 객체**의 `this` 다
(`0x1400C0CA0: 48 8b f9  mov rdi, rcx`). 같은 생성자가 바로 다음에
`0x1400C0CA6: 48 8d 59 08  lea rbx, [rcx+8]` 로 **AudioProcessor 부분객체(this+8)** 를 잡고,
캡처 초기화가 그 `rbx` 기준으로 `[rbx+8]`=30.0 · `[rbx+0xc]`=10.0 을 읽는다(`0x1400cf60f`,
`0x1400cf61b`). 즉 AudioProcessor 기준 오프셋은 **0xE4/0xE8/0xEC/0xF0** 이고, 스크립트 라벨은
바깥 객체 기준이다. 값 검사·바이트 검사는 둘 다 옳으니 **라벨만** 고치면 된다:
`"AudioProcessor+0xEC"` → `"객체+0xEC = AudioProcessor+0xE4"` 식으로 두 기준을 함께 적을 것.
(이 문서 §1 의 "오프셋 기준선 주의" 박스가 이미 그 8을 설명하고 있는데, 스크립트가 만드는
정본 JSON 만 다른 기준을 쓰고 있어 대조하는 사람이 반드시 걸린다.)

### 7.4 `CreateAudioResponse` — 원문 전수 대조

이 함수는 **공유 헤더에 없다.** `assets/shaders/*.h` 14개 어디에도 없고, 세 셰이더가 각자
**복사본**을 갖는다. 세 본문을 `awk '/^float CreateAudioResponse/,/^}/'` 로 잘라 md5 를 뜨면
**3건 전건 동일**(`14685dc6…`)이다. 규약은 이게 전부다:

```glsl
float audioFrequencyEnd = max(g_AudioFrequencyMin, g_AudioFrequencyMax);   // ← 죽은 변수. 아무도 안 쓴다
float audioResponse = 0.0;
#if AUDIOPROCESSING == 1 / 2 / 3
  for (int a = int(g_AudioFrequencyMin); a <= int(g_AudioFrequencyMax); ++a)
      audioResponse += bufferLeft[a];            // 1
      audioResponse += bufferRight[a];           // 2
      audioResponse += bufferLeft[a] + bufferRight[a];   // 3
  audioResponse /= (g_AudioFrequencyMax - g_AudioFrequencyMin + 1.0);        // 1·2
  audioResponse /= (g_AudioFrequencyMax - g_AudioFrequencyMin + 1.0) * 2.0;  // 3
#endif
audioResponse = smoothstep(g_AudioBounds.x, g_AudioBounds.y, audioResponse);
audioResponse = saturate(pow(audioResponse, g_AudioPower)) * g_AudioMultiply;
```

`AudioResponse.compute` 는 이것과 일치한다. 재대조에서 새로 못 박은 두 가지:

- **`saturate` 는 `pow` 만 감싸고 `× multiply` 는 그 바깥이다.** `g_AudioMultiply` 의 선언 범위가
  `[0,2]` 라 반환값의 상한은 1 이 아니라 **2** 다. 이걸 잠그는 테스트가 없었다
  (`testMultiplyAndExponent` 는 `power=2` 라 우연히 0.5 로 돌아와 이 성질을 안 건드린다) —
  `testMultiplyIsAppliedOutsideSaturateSoOutputCanExceedOne` 로 추가했다.
- **루프 경계는 `int()` 절삭인데 분모는 원시 float 이다.** 같은 유니폼 쌍을 두 도메인에서 읽는다.
  `0.5 … 5` 면 합산 항은 6개(`a=0…5`)인데 분모는 5.5 다. 어노테이션이 `"int":true` 라 실사용
  도달은 없지만 규약은 이렇게 어긋나 있고 우리 구현이 재현한다 —
  `testFractionalRangeSumsByTruncationButDividesByRawFloat` 로 추가했다.

`g_Audio*` 유니폼의 총 출현(설치본, `ui/` 제외)은 `FrequencyMin`/`Max` 각 24 · `Bounds` 9 ·
`Power`/`Multiply` 각 6 이고, 이는 3파일 × (선언 1 + 사용 7/2/1) 로 **정확히 떨어진다** —
즉 이 파라미터 집합을 쓰는 셰이더는 그 셋이 전부다.

### 7.5 파티클 오디오 경로 (읽기만 — 재확인)

`ParticleSimulator.audioResponseScale` 이 `reduction: .peak` 로 부르는 근거를 실물에서 다시 떴다.
`0x14022a8a0`(범위 `0x14022a8a0–0x14022ab28`, `primary` 실측):

```
0x14022a8b5  mov r8d, [r9]           ; mode 디스패치: -1/je → 1, -1/je → 2, cmp 1/jne → 3
0x14022a8d6  mov ecx, [r9+0x10]      ; freqStart (int32)
0x14022a8da  mov r8d, [r9+0x14]      ; freqEnd   (int32)
0x14022a8de  cmp ecx, r8d / ja …     ; 빈 구간이면 peak = 0 그대로
0x14022a903  movss xmm0, [rdx+rax*4+0x40]   ; Right  (+0x40 = +16 float → **16밴드 배열**)
0x14022a909  addss xmm0, [rdx+rax*4]        ; + Left
0x14022a90e  comiss xmm0, xmm3 / movaps     ; 러닝 MAX — **나눗셈 없음**
0x14022a97c  mulss xmm3, [0x1404926c0]      ; 모드 3 만 ×0.5
```

모드 2(`0x14022a989`)는 `[rdx+rax*4+0x40]` 만 훑고 ×0.5 가 없다. 전부 현행 구현과 일치한다.
**두 가지를 덧붙인다**: (1) 버퍼는 좌 `+0`, 우 `+0x40` 인 **16밴드**다 — 파티클 경로는 64밴드를
안 본다. (2) `freqStart`/`freqEnd` 는 `mov …, dword ptr` 로 **int32** 로 읽힌다. 우리는 `Float` 로
들고 `bin()` 에서 절삭하므로 정수 입력에서는 같지만 소수 입력에서 갈릴 수 있다 —
**도달 0 이라 무해**(§6.1: `audioprocessingmode` 가 두 트리에 0건).

### 7.6 §1–§5 재검증 결과

이번 라운드에 **독립적으로 다시 뜬** 것과 그 판정:

| 대상 | 판정 |
| --- | --- |
| `AP_CONSTANTS` 4건 + `BYTE_CHECKS` 12건(오디오분) 원시 바이트 | **전건 일치** |
| N·B 유도(§1.3) — 클램프·×64·×30/×10·절삭 **순서까지** | **일치**. `engineFFTLength` 의 `scale × 64 × 30` 곱셈 순서가 실물과 같다 |
| 시간영역 `×127`/`+127`/`1/x`(§2.2) | **일치** |
| 소비 루프 전체(§3.1) — `ebx=1` 시작, `p=re²+im²`, Inf/NaN 가드, `powf`·×64·절삭·부호보존 `%64`·`cmovle prev+1`, 틸트 cos 인자가 **빈** 인덱스(`xmm7` 이 non-volatile 이라 `powf` 를 넘어 생존), `sqrt(w·p)`, `maxss` 저장 | **일치** |
| 게인(§3.4) — `AP[0x0C]·0.001·B/(N·0.5)`, 64밴드 두 배열 | **일치** |
| 채널 분리(§3.3) — 좌 `+0x40` / 우 `+0x140`, 스트라이드 0x100 | **일치** |
| 무음 게이트(§3.6) — 채널 0 만, 부호 max, 0 바닥, `FLT_EPSILON` 활성 | **일치** |
| mono 사분면(§3.5) + 유니폼 6개뿐 | **일치**(§6.3 에서 id 까지 재현) |
| 소비단 상수 9개(`AudioSpectrumProcessor`) | **전건 일치** |
| §6 도달 표 | **오류 1건 — 정정함**(neon_sunset) |

`w = C − (1−C)cos(πt)` 는 `C=0.501` 에서 항상 `[0.002, 1.0]` 이라 `sqrt` 인자가 음수가 될 수 없다.
실물에는 음수 분기(`0x1400d1ce9` 의 `ja` → 라이브러리 `sqrtf`)가 있지만 **도달 불가**이고,
우리 `tiltAmplitudeWeights` 의 `w > 0 ? sqrtf(w) : 0` 클램프는 도달 가능 영역에서 등가다.

---

## 8. 2026-08-21 (2차) — 소비단 전건 재측정 · 밴드 경계표 · 씬 스크립트 오디오 API

**바이너리 둘을 썼다**: `wallpaper64.exe`(imagebase `0x140000000`) 와
`bin/scenescript64.dll`(imagebase `0x180000000`). 후자는 이 문서에서 처음 쓴다.

### 8.1 소비단 전건 재측정 — 정정 0건

§7 의 값을 베끼지 않고 **함수 시작에서 선형으로 다시 떴다**. `primary(0x140110630)` 는
`0x140110630–0x140110867` 짜리 조각이라 그대로 쓰면 안 되고(브리프 함정 1),
`merged` 가 주는 `0x140110630–0x140113bc0`(7조각)이 실제 범위다. 2,797개 명령을 전부 훑은 결과:

| 항목 | 재측정 근거 | 판정 |
| --- | --- | --- |
| 그룹 크기 = 연속 8 float | 적재 오프셋 `{0x00,0x20,…,0x1e0}`(16개, 스트라이드 0x20)에서 `K+0/4/8/0xc`, 카운터 `add ecx,4`(`0x140111b81`) · `cmp ecx,8`(`0x140111baf`) → 4×2 = 8 | 일치 |
| 비율 하한 0.333 | `0x140111c7d` `mulss xmm2, [0x140492698]` = 0.333 → `maxps` 4개(`0x140111c99`·`ca4`·`caf`·`cb3`)로 16그룹 | 일치 |
| 무음 임계 1e-4 | `0x140111c72` `movss xmm6, [0x1404925fc]`, `0x140111c8c` `comiss` + `setae r9b` | 일치 |
| 리시드 조건은 `env[0]` 하나 | `0x140111ca1` `comiss xmm6, [rax]` → `jb`(`0x140111cc3`) + `test r9b,r9b`(`0x140111cc9`) | 일치 |
| 리시드 값 1.0 × 16 | `0x140111cd2`–`0x140111da3` 의 `mov dword [rax+n], 0x3f800000` 16개(오프셋 0x00…0x3c) | 일치 |
| 스냅 / 상승 1.0 / 하강 −0.5 | `andps`(abs, 마스크 `0x140492fc0`) → `comiss xmm2, xmm6` → `jbe` 스냅(`0x140111f18`, 피크를 그대로 복사) / `comiss xmm3, xmm7(=0)` → `jbe` 면 `−0.5`(`0x1404929ac`), 아니면 `xmm11`(=1.0, `0x140492704`) | 일치 |
| 스텝 `min(dt,1)` | `0x140111e68` `minss xmm1, xmm11` | 일치 |
| 분모 바닥 0.001 + `rcpps` | `0x1401121b8` `movss xmm1, [0x140492608]`, 16개 `comiss`/`jbe` 후 `shufps …,0` + `rcpps`, 결과를 `[rbp+0x170 + 16g]` 에 적재 | 일치 |
| 1-pole 계수 `min(dt·20,1)` | `0x140112363` `mulss xmm10, [0x14049288c]`(=20.0) → `comiss xmm11, xmm10`/`ja` | 일치 |
| 슬루 `±min(dt·40,1)` | `0x1401123f0` `[0x1404928c4]`(=40.0) 와 `0x14011240f` `[0x140492a10]`(=−40.0), 하한은 `[0x1404929b8]`(=−1.0) | 일치 |
| 슬루 분기 형태 | `maxps`(음수쪽) + `minps`(양수쪽) + `cmpltps 0, delta` 마스크 + `andps`/`andnps`/`orps` — 즉 `delta==0` 은 음수 가지로 떨어져 0 | 일치(우리 `min(max(d,−s),s)` 와 등가) |
| 출력이 `[rbx]` 에 in-place | `0x1401124ba` `movups [rbx+rdx*4], xmm3` | 일치 |
| `prev = out` 전체 복사 | `0x1401125e2`–`0x140112642`: `[r15+0x1a0]` ← `rbx`, 0x80B × 4 = **0x200B(128 float)** | 일치 |
| 무음이면 출력만 memset | `0x14011242f` `je 0x140112646` → `memset(rbx, 0, 0x200)`; **prev 복사를 건너뛴다** | 일치 |
| mono = 0.5·(L+R) | `0x1401126a4` `[rbx+…+0x100]` + `[rbx+…]`, `mulss xmm6`(0.5, `0x1404926c0`), 저장 `+0x200` | 일치 |
| 64→32 MAX | `0x1401128da` `movss xmm0,[rbx+rax*4+4]` / `0x1401128e0` `maxss xmm0,[rbx+rcx*4]` → `[[rdi+0x2d8]+rcx*4]` | 일치 |
| 32→16 MAX | `0x140112b6f` 부터 완전 언롤 `maxss` 사슬, 마지막 쌍이 `[rax+0x170]`·`[rax+0x178]`(=96 float 버퍼의 끝) → 48 출력 = **세 사분면 전부** | 일치 |
| 버퍼 멤버 | `[obj+0x2d0]`=spec64(0x300B) · `[+0x2d8]`=spec32(0x180B) · `[+0x2e0]`=spec16(0xc0B) — `0x140115403`–`0x14011543a` | 일치 |
| 유니폼 등록표 id 6개(§6.3) | 이름 6개 각각 ASCII **1건**·UTF-16LE **0건**·`.text` disp32 xref **1건**. 표는 `0x140003dcf`부터 선형으로 다시 떴다 — `mov [rsp+X], id` 가 자기 이름 `lea` **앞**에 오고, 슬롯 `lea rcx,[rbp+…]` 는 0x28 간격. 경계로 `0x61`=`g_LightSkylightColor`, `0x68`=`g_PointerPositionLast` 확인 | **일치**(0x62…0x67 = 16L·16R·32L·32R·64L·64R) |

**정정 0건.** `AudioSpectrumProcessor.swift` 의 상수 9개·순서 10단계는 전부 실물과 같다.

### 8.2 상한 클램프도 dB 변환도 없다

새로 못 박은 두 가지다(§0 표에도 §7 에도 없던 항목).

- **출력 클램프 없음.** 오디오 구간 `0x140111662–0x1401131bf` 의 `minss`/`minps` 는 **13개뿐**이고
  전부 시간 계수·슬루다: `min(dt,1)` 1개(`0x140111e68`), 엔벨로프 스텝 `min(step,|d|)` **명령
  8개** = 8배 언롤(`0x140111eeb`·`f43`·`f9e`·`ff9`·`0x140112054`·`0af`·`10a`·`165`; 바깥 루프가
  2회 돌아 16그룹), 슬루 상한 `minps` 4개(`0x140112495`·`500`·`562`·`5c4`).
  계수 셋(α·±슬루)은 `comiss`/`ja`/`movaps` 분기형이라 `minss` 로 세지 않는다.
  **출력값을 1.0 으로 자르는 자리는 없다** — 엔벨로프가 초당 1.0 으로만 쫓아오므로 급격히 커진
  대역은 1.0 을 넘겨 나가는 것이 정상이다.
- **dB 없음.** 프로듀서 소비 루프 `0x1400d1bff–0x1400d1e00` 의 라이브러리 호출은 정확히 셋 —
  `powf`(`0x1400d1c90`) · `cosf`(`0x1400d1ccd`) · `sqrtf` 폴백(`0x1400d1cf7`) — 이고 `log` 계열은
  없다. 진폭은 `sqrt(w·p)` 선형 그대로 게인만 곱해 나간다.
- **무신호 바닥값은 0** 이다(`0x140112646` 의 memset). `0.001` 바닥은 **분모에만** 걸린다.

### 8.3 [해소] §7.2(b) — 씬 스크립트 오디오 버퍼는 접지 않는다

`scenescript64.dll` 에 `registerAudioBuffers` 가 있다(ASCII 1건, `0x1819a3630`; UTF-16LE 사본 0건).
오류 문자열 둘이 규약을 그대로 말해 준다:

```
0x1819a3af8  "registerAudioBuffers can only be called from global scope."
0x1819a3b38  "Resolution must be either 16, 32 or 64."
```

구현은 `0x181655170–0x18165580f`(merged 9조각). 두 오류 문자열이 **이 함수 안에서만** 참조되는
것으로 먼저 잡았고, 등록표 쪽에서 독립으로 확인했다 — `0x18164938e` 가 이름
`"registerAudioBuffers"` 를 `lea` 하고 **바로 다음 항목**의 함수 포인터 `lea` 가
`0x1816493d5: lea r8, 0x181655810` 인데, 그 `0x181655810` 이 정확히 이 함수의 **끝 다음 바이트**다.
(즉 등록표는 여기서도 한 칸 밀려 있다 — 브리프 함정 16. 이름 뒤의 `lea` 를 그 이름의 구현으로
읽으면 `registerAsset` 을 집는다.) 등록 대상 객체는 `AUDIO_RESOLUTION_*` 상수와 **같은 객체**이고
(둘 다 `[rbp+0x98]` 을 `rcx` 로 받아 `0x1800090f0` 호출), 문자열 테이블에서 세 상수 바로 뒤에
`engine` 이 온다 — 그래서 `engine.registerAudioBuffers` 로 적는다(객체 **이름**은 그 인접성에
기댄 **추정**이다). 읽은 그대로:

```
0x181655216  cmp dword [rcx], 0        ; argc
0x181655221  mov r15d, 0x10            ; ← **인자 없으면 16** (argc 검사보다 앞에 있다)
0x181655227  jle <스킵>
0x18165527a  r15d = (int32)arg0
0x18165527e  mov  eax, 0xfffffff0
0x181655283  add  eax, r15d            ; eax = res − 16
0x181655286  test eax, 0xffffffcf      ; {16,32,48,64} 만 통과
0x18165528b  jne  <throw>
0x18165528d  cmp  r15d, 0x30           ; 48 은 여기서 따로 걷어낸다
0x181655291  jne  <ok>
```

버퍼는 **미리 9개를 잡아 둔다** — `0x181655360`–`0x1816553ca` 의 3회 루프가 `rol r14d,4`
(=16→32→64) × 4바이트로 크기를 만들고 매 바퀴 `alloc` 을 세 번 불러
`[ctx+0x630]`, `[+0x638]`, `[+0x640]` … `[+0x670]` 에 채운다. 호출 때는
`r15d >>= 5`(`0x1816553e2`) · `eax = 3·r15`(`0x1816553f6`) 로 한 벌을 고른다
— 16→`0x630`, 32→`0x648`, 64→`0x660`.

그 셋에 붙는 **프로퍼티 이름 셋을 확정했다.** 스크립트 컨텍스트 셋업
`0x181647aa0–0x18164abef`(merged 2조각, `registerAudioBuffers` 라는 전역 이름을 등록하는 바로 그
함수)이 인터닝된 이름을 슬롯에 심는다:

| 슬롯 | 이름 | 심는 자리 | `registerAudioBuffers` 가 읽는 자리 | 물리는 버퍼 |
| --- | --- | --- | --- | --- |
| `ctx+0x2b0` | `enabled` | `0x18164891c` | (읽는 자리 못 찾음) | — |
| `ctx+0x2b8` | `left` | `0x18164895b` | `0x181655642` | `+0x630` |
| `ctx+0x2c0` | `right` | `0x18164899a` | `0x181655679` | `+0x638` |
| `ctx+0x2c8` | `average` | `0x1816489d9` | `0x1816556a0` | `+0x640` |

`enabled` 는 문자열 테이블에서 `left`/`right`/`average` 바로 앞에 붙어 있고 슬롯도 연속이라
같은 오디오 객체의 넷째 프로퍼티로 **보이지만**, `registerAudioBuffers` 는 이 슬롯을 읽지 않는다 —
어디서 쓰는지 못 찾았다(**추정**). 나머지 셋은 읽는 자리까지 확인했다.

같은 함수가 상수도 심는다 — `AUDIO_RESOLUTION_16/32/64` = `0x10`/`0x20`/`0x40`
(`0x181649c05`/`0x181649c65`/`0x181649cc5` 의 `mov r8d, imm` 이 각 이름 `lea` **앞**에 온다 —
함정 16 이 여기서도 걸린다. 이름 뒤의 imm 으로 읽으면 한 칸 밀린다).

**결론 셋.**

1. **스크립트 쪽 축약은 없다.** `registerAudioBuffers` 는 해상도 하나로 미리 접어 둔 버퍼 한 벌을
   고를 뿐이다. 즉 스크립트가 보는 `left/right` 는 소비단이 **`maxss` 로 접어 둔** `spec16/32/64`
   그대로다 — §7.2(b) 가 미해결로 남겨 둔 질문의 답이고, `TextScriptEngine` 의 `avg(...)` 는 틀렸다.
2. **셋째 배열의 실물 이름이 `average` 다.** §3.5 가 "읽는 쪽을 찾지 못했다" 고 남겨 둔 mono
   사분면의 소비처가 이것이다. 셰이더 유니폼으로는 안 나가지만(등록표 6개 확정, §6.3)
   스크립트에는 나간다.
3. **`average32/16` 은 `average64` 를 MAX 로 접은 것**이지 접힌 L/R 을 다시 평균한 것이 아니다.
   32→16 언롤 사슬이 96 float 버퍼의 셋째 사분면(`[rax+0x160]`…`[rax+0x178]`)까지 도는 것이 근거다.
   두 순서는 갈린다 — L=[1,0], R=[0,1] 이면 실물 0.5, 뒤바꾼 순서 1.0.

**[미해결]**: 이 9개 버퍼를 **누가 언제 채우는지**(호스트 → 스크립트 푸시 경로)는 못 떴다.
크기(해상도당 3×res float)와 셋째 이름(`average`)이 소비단 `[L|R|M]` 사분면과 정확히 맞으므로
소비단 출력이 그대로 들어간다는 것이 자연스러운 해석이지만, **복사 자리를 눈으로 보지는 못했다 —
추정이다.** 좁히지 못한 이유는 오프셋이 흔해서다: `wallpaper64.exe` `.text` 에서 disp32 가
`0x2d0`/`0x2d8`/`0x2e0` 인 메모리 오퍼랜드 **후보**가 각각 230/366/224건 나오고, 그중 이
클래스의 것이 어느 것인지는 베이스 레지스터만으로 가려지지 않는다.

### 8.4 32밴드·16밴드가 실제로 덮는 주파수

§3.2 는 64밴드 표만 있었다. 32·16 은 **인접 2개씩 `maxss` 로 접은 것**이므로 경계가 64밴드
경계의 부분집합이고, 그래서 아래 표는 §3.2 에서 **유도**된다(§3.2 자체를 `bandOfBin` 재구현으로
독립 재현해 대조했다 — 64밴드 64개, 1:1 구간 밴드 0…28 의 29개까지 일치).
기준은 원본 조건 `B = 640`, 44.1 kHz(빈 폭 22.96875 Hz).

**32밴드** — 하위 14개가 각 2빈(≈46 Hz)이고 그 위가 급격히 벌어진다.

| 밴드 | 빈 | 개수 | Hz |
| --- | --- | --- | --- |
| 0…13 | 각 2빈 (1–2, 3–4, … 27–28) | 2 | 23.0 – 666.1 |
| 14 | 29–31 | 3 | 666.1 – 735.0 |
| 15 | 32–40 | 9 | 735.0 – 941.7 |
| 16 | 41–51 | 11 | 941.7 – 1194.4 |
| 17 | 52–64 | 13 | 1194.4 – 1493.0 |
| 18 | 65–80 | 16 | 1493.0 – 1860.5 |
| 19 | 81–98 | 18 | 1860.5 – 2273.9 |
| 20 | 99–119 | 21 | 2273.9 – 2756.2 |
| 21 | 120–143 | 24 | 2756.2 – 3307.5 |
| 22 | 144–171 | 28 | 3307.5 – 3950.6 |
| 23 | 172–203 | 32 | 3950.6 – 4685.6 |
| 24 | 204–239 | 36 | 4685.6 – 5512.5 |
| 25 | 240–279 | 40 | 5512.5 – 6431.2 |
| 26 | 280–324 | 45 | 6431.2 – 7464.8 |
| 27 | 325–375 | 51 | 7464.8 – 8636.2 |
| 28 | 376–432 | 57 | 8636.2 – 9945.5 |
| 29 | 433–494 | 62 | 9945.5 – 11369.5 |
| 30 | 495–563 | 69 | 11369.5 – 12954.4 |
| 31 | 564–639 | 76 | 12954.4 – 14700.0 |

**16밴드** — 실사용이 몰려 있는 해상도다(§6: 유니폼 출현 31/11 대 2/2/2/2).

| 밴드 | 빈 | 개수 | Hz | 폭 |
| --- | --- | --- | --- | --- |
| 0 | 1–4 | 4 | 23.0 – 114.8 | 91.9 |
| 1 | 5–8 | 4 | 114.8 – 206.7 | 91.9 |
| 2 | 9–12 | 4 | 206.7 – 298.6 | 91.9 |
| 3 | 13–16 | 4 | 298.6 – 390.5 | 91.9 |
| 4 | 17–20 | 4 | 390.5 – 482.3 | 91.9 |
| 5 | 21–24 | 4 | 482.3 – 574.2 | 91.9 |
| 6 | 25–28 | 4 | 574.2 – 666.1 | 91.9 |
| 7 | 29–40 | 12 | 666.1 – 941.7 | 275.6 |
| 8 | 41–64 | 24 | 941.7 – 1493.0 | 551.3 |
| 9 | 65–98 | 34 | 1493.0 – 2273.9 | 780.9 |
| 10 | 99–143 | 45 | 2273.9 – 3307.5 | 1033.6 |
| 11 | 144–203 | 60 | 3307.5 – 4685.6 | 1378.1 |
| 12 | 204–279 | 76 | 4685.6 – 6431.2 | 1745.6 |
| 13 | 280–375 | 96 | 6431.2 – 8636.2 | 2205.0 |
| 14 | 376–494 | 119 | 8636.2 – 11369.5 | 2733.3 |
| 15 | 495–639 | 145 | 11369.5 – 14700.0 | 3330.5 |

**선형도 로그도 아니다** — 하위 7밴드가 **정확히 등간격 91.875 Hz**(= 4빈)이고 그 위가
`pow(t,0.25)` 매핑대로 벌어진다. 그 등간격 구간은 별도 규칙이 아니라 §3.2 의 `prev+1` 클램프가
64밴드 0…28 을 1빈씩으로 묶어 둔 결과의 그림자다. 그래서 **길이가 `B` 에 딸려 변한다** —
`B ∈ 623…688` 에서만 "16밴드 0…6 이 4빈" 이고, 96 kHz(B=314)나 32 kHz(B=940)에서는 달라진다.

**바로 따라오는 것 하나.** `CreateAudioResponse` 의 선언 기본값 `frequencymin=0`,
`frequencymax=1`(§7.4)은 **밴드 0–1 = 23.0–206.7 Hz** 다. 즉 스톡 오디오 이펙트의 기본 반응은
서브베이스~베이스 두 칸이고, 전 대역이 아니다. `audiophileglow.vert` 가 쓰는 `L[0]` 은
**23–115 Hz 한 칸**이다.

우리 구현은 48 kHz·N=2048 에서 `B=627`(빈 폭 23.4375 Hz)이라 위 표의 **구조는 같고**
(1:1 구간 29 → 16밴드 0…6 이 각 4빈) 경계 주파수만 최대 0.92빈(≈21.6 Hz) 밀린다 —
이 절충의 근거는 `AudioSpectrum.swift` 헤더에 있다.

### 8.5 Waple 반영과 넘길 것

**이번에 고친 것(소유 안).**

- `Sources/WapleCore/AudioSpectrumProcessor.swift`
  - `ScriptResolution`(16/32/64 · `fallback = 16` · `validate` 가 실물의 두 게이트를 그대로 태운다)
  - `Output.scriptBuffers(_:)` → `(left, right, average)`
  - 상한 클램프/dB 부재, 그룹 크기 8의 근거를 주석에 명시
- `Sources/WapleCore/AudioResponse.swift`
  - `ShaderDefaults` + `pulseDefaults`/`shakeDefaults` + `declaredDefaults(effectName:)`
    (§7.2(c) 의 표를 코어로 옮겨 테스트로 잠갔다)
- `Sources/WapleCore/AudioSpectrum.swift` — `bandOfBin` 주석에 32·16밴드 경계 유도(§8.4) 포인터.
- 테스트 6개 추가(`AudioSpectrumProcessorTests` 3 · `AudioResponseTests` 2 ·
  `AudioSpectrumWEParityTests` 1), 돌연변이 5/5 검출.

**넘기는 것(소유 밖).**

**(a) `Sources/WapleRender/TextScriptEngine.swift`** — `__setAudioData` 안 세 곳.

```js
// ① 64→32/16 은 평균이 아니라 MAX 다 (0x1401128e0 / 0x140112b6f)
function fold(src, dst, group) {
    for (var i = 0; i < dst.length; i += 1) {
        var m = src[i * group];
        for (var j = 1; j < group; j += 1) { if (src[i * group + j] > m) { m = src[i * group + j]; } }
        dst[i] = m;
    }
}
fold(__audioBuffer.left64,  __audioBuffer.left32,  2);
fold(__audioBuffer.right64, __audioBuffer.right32, 2);
fold(__audioBuffer.left64,  __audioBuffer.left16,  4);
fold(__audioBuffer.right64, __audioBuffer.right16, 4);

// ② average 는 **먼저 섞고 그 다음 접는다** — 접힌 L/R 을 다시 평균하면 안 된다
for (var m = 0; m < 64; m += 1) { __audioBuffer.average64[m] = (__audioBuffer.left64[m] + __audioBuffer.right64[m]) / 2; }
fold(__audioBuffer.average64, __audioBuffer.average32, 2);
fold(__audioBuffer.average64, __audioBuffer.average16, 4);
```

③ `registerAudioBuffers(res)` 의 **무인자 폴백은 64 가 아니라 16** 이다(`0x181655221` 의
`mov r15d, 0x10` 이 argc 검사보다 앞). 그리고 실물은 16/32/64 가 아니면 **던진다** — 지금 코드는
조용히 64 로 떨어진다. 다만 `__audioBuffer.average = __audioBuffer.average64` 쪽 별칭은
`engine.audio.average` 라는 **Waple 자체 확장**이라 실물 근거가 없다 — 그건 그대로 둬도 된다
(실물에서 `average` 는 `registerAudioBuffers` 반환 객체의 프로퍼티로만 확인됐다).
(도달은 0 이라 무회귀 정정이다 — §6.1.)

호출부는 `AudioSpectrumProcessor.Output.scriptBuffers(_:)` 를 쓰면 코어와 규약이 하나로 붙는다.

**(b) `Sources/WapleRender/SceneRendererResources.swift` 의 `audioParams(for:)`** — §7.2(c) 를
코어 표로 대체한다(하드코딩 제거):

```swift
let d = AudioResponse.declaredDefaults(effectName: eff.name)
let bounds = c["audiobounds"] ?? [d.bounds.x, d.bounds.y]
return AudioParams(
    mode: mode,
    freqMin: c["frequencymin"]?.first ?? d.freqMin,
    freqMax: c["frequencymax"]?.first ?? d.freqMax,
    bounds: SIMD2<Float>(bounds.count > 0 ? bounds[0] : d.bounds.x,
                         bounds.count > 1 ? bounds[1] : d.bounds.y),
    power: c["audioexponent"]?.first ?? d.power,
    multiply: c["audioamount"]?.first ?? d.multiply)
```

**(c) `scripts/spec/measure_effect_fbo_audio.py`** — §7.3 의 `BYTE_CHECKS` 4건 제안은 그대로
유효하다(이번에 다시 읽어 바이트 전건 재확인). 라벨 8 어긋남 정정도 그대로.

**(d) 정본 공백 하나 더.** `spec/engine/uniform-feed.json` 에는 **오디오 항목이 0건**이다
(전수 확인: 키·값 어디에도 `udio` 문자열 없음). `scripts/spec/measure_uniform_feed.py` 역시
`audio`/`0x62`/`0x66` 을 한 번도 언급하지 않는다. 즉 "id 0x62…0x67 이 소비단 버퍼의 어느
사분면에서 오는가" 는 정본이 기록하지 않는다. 등록표(이름↔id)는 §6.3·§8.1 에서 확정했지만
**매 프레임 피드 사이트는 이번에도 못 찾았다 — [미해결]**. 좌=사분면 0 이라는 것은
프로듀서가 채널 0 을 `[rbp+0x40]`(좌 절반)에 싣는다는 §3.3 에서 **간접**으로 온다.
`uniform-feed` 계열은 소유 밖이라 넘긴다.

