# `sprite` 씬 오브젝트 — 하드웨어 오클루전 쿼리로 구동되는 렌즈플레어

**조사일 2026-08-21 · WE 2.8.42 `wallpaper64.exe` (md5 `438cb215f20a8f6c38f57fbc3d9da588`, imagebase `0x140000000`)**

선행 스윕(T11)의 미확인 주장을 손으로 재검증한 결과다.

> WE 의 스프라이트(파티클) 클래스는 0x270 바이트이고, occlusion query 로 구동되는
> 밝기(brightness) 채널이 있다.

## 0. 결론

| 주장 | 판정 | 확신 |
| --- | --- | --- |
| 하드웨어 오클루전 쿼리가 존재한다 | **확인** | **확정** — `D3D11_QUERY_DESC{Query=1}` 이 `0x14009ae63` 에 리터럴로 박혀 있고, `GetData` 의 `DataSize=8`(`0x1400f00ac`)까지 `D3D11_QUERY_OCCLUSION` 규약과 일치 |
| 그 결과가 밝기 채널을 구동한다 | **확인** | **확정** — 픽셀수 → `g_Alpha` 매핑 전문을 `0x1402567cc–0x1402568e5` 에서 복원했다 |
| 대상 클래스가 **0x270 바이트** | **확인** | **확정** — `mov ecx, 0x270` @ `0x140190304` 직후 ctor `0x140256560` 호출 |
| 그 클래스가 **파티클(스프라이트) 클래스**다 | **반증** | **확정** — 0x270 은 씬 오브젝트 타입 `"sprite"` 전용 클래스다. 같은 팩토리에서 **파티클은 0x960**(`mov ecx, 0x960` @ `0x1401901e9`)이다. 이름 충돌의 출처는 §6 |
| 파티클/트레일/로프 렌더러에도 적용된다 | **반증** | **확정** — 바이너리 전체에서 오클루전 쿼리를 만드는 호출지점은 **정확히 1곳**(`0x1402566ea`)이고 그건 `sprite` ctor 안이다 |
| 밝기에 슬루/보간(감쇠 상수)이 있다 | **반증** | **확정** — 시간 보간이 전혀 없다. 매 프레임 쿼리 결과에서 직접 재계산한다(§4) |

한 줄 요약: **주장의 메커니즘은 실재하지만, 주체를 잘못 짚었다.** 오클루전 밝기는
파티클 시스템의 기능이 아니라 `scene.json` 의 `"sprite"` 오브젝트 하나만이 가진 기능이다.

---

## 1. 자산 쪽 근거 — 오클루전 프로브 머티리얼이 평문으로 배포된다

바이너리보다 먼저 볼 것이 있었다. WE 설치본에 프로브용 머티리얼과 셰이더가 그대로 들어 있다.

`assets/materials/util/occlusiontest.json`

```json
{
	"passes": [{
		"shader": "occlusiontest",
		"cullmode" : "nocull",
		"depthwrite": "disabled"
	}]
}
```

`assets/shaders/occlusiontest.vert`

```glsl
attribute vec3 a_Position;
attribute vec2 a_TexCoord;
uniform vec3 g_ViewUp;
uniform vec3 g_ViewRight;
uniform mat4 g_ModelViewProjectionMatrix;

void main() {
	vec3 position = a_Position +
		(g_ViewRight * (a_TexCoord.x-0.5) +
		g_ViewUp * (a_TexCoord.y-0.5)) * 0.5;
	gl_Position = mul(vec4(position, 1.0), g_ModelViewProjectionMatrix);
#if REVERSEDEPTH
	gl_Position.z = 0.0000001;
#else
	gl_Position.z = 0.999 * gl_Position.w;
#endif
}
```

`assets/shaders/occlusiontest.frag` 는 `gl_FragColor = vec4(1,1,1,1);` 한 줄이다.

읽을 것 셋:

1. **정점 위치를 셰이더가 만든다.** `a_Position` 은 네 정점이 전부 같고, `a_TexCoord`
   코너로 `g_ViewRight`/`g_ViewUp` 을 태워 빌보드로 펼친다. 즉 **이 두 유니폼을 스케일하면
   프로브 쿼드의 크기가 바뀐다** — 아래 §4 에서 엔진이 정확히 그 짓을 한다.
2. **깊이를 far 로 밀어 넣는다**(`z = 0.999w`, 리버스 뎁스면 `z ≈ 0`). 앞에 뭐가 있으면
   전부 뎁스 테스트에서 탈락하므로, 통과한 샘플 수 = "안 가려진 정도"다.
3. `depthwrite: disabled` — 프로브는 뎁스를 오염시키지 않는다.

문자열 `"materials/util/occlusiontest.json"` 은 `.rdata` `0x140491658` 에 1회 존재하고,
참조도 `0x1402566bf` 단 1곳이다.

> 리포의 `scripts/re/xref.py` 로는 이 문자열이 안 잡힌다(경로 문자열의 **부분 문자열**을
> 찾는 모드가 없다). NUL 종단 전체 경로로 찾아야 한다.

---

## 2. 팩토리 — `"sprite"` 는 0x270 바이트짜리 씬 오브젝트다

씬 오브젝트 팩토리는 `0x14018ff60–0x1401909b1` 이다. JSON 오브젝트에서 콘텐츠 키를
순서대로 찾아 해당 클래스를 `new` 한다.

```
0x1401902cd  lea  r8,  [rip+0x2fe332]        ; 0x14048e606  ("sprite" 끝)
0x1401902d7  lea  rdx, [rip+0x2fe322]        ; 0x14048e600  "sprite"
0x1401902de  call 0x140087490                ; Json::Value::find(json, "sprite")
0x1401902e6  je   0x140190332                ; 없으면 "text" 분기로
0x1401902f9  call 0x140086de0                ; json["sprite"]
0x1401902fe  cmp  byte [rax+8], 4            ; 값이 string 인지
0x140190302  jne  0x140190332
0x140190304  mov  ecx, 0x270                 ; ← 클래스 크기
0x140190309  call 0x14028af20                ; operator new
0x14019030e  mov  rdx, [r14+0xd8]            ; = 씬
0x140190315  mov  r8,  rsi                   ; = JSON 노드
0x14019031b  call 0x140256560                ; sprite::sprite(this, scene, json)
```

같은 팩토리의 형제 타입 크기 — **0x270 은 파티클이 아니다**:

| 타입 | `mov ecx, size` VA | 크기 |
| --- | --- | --- |
| `model` | `0x14019013c` | 0x320 |
| **`particle`** | `0x1401901e9` | **0x960** |
| `image` | `0x14019029f` | 0x4d0 |
| **`sprite`** | `0x140190304` | **0x270** |
| `text` | `0x14019034d` | 0x5d0 |
| `light` | `0x1401903ba` | 0x3a0 |
| `sound` | `0x140190593` | 0x320 |
| `camera` | `0x140190693` | 0x360 |
| `shape` | `0x140190795` | 0x460 |
| (폴백) | `0x1401907e0` | 0x2c0 |

`model`/`particle`/`image` 키는 SSO(15바이트 이하) 라 `lea` 가 없고 스택에 바이트로
조립된다(`0x14018ff7a` = `"mode"`+`"l"`, `0x140190001` = `"particle"`, `0x140190083` =
`"imag"`+`"e"`). `scripts/re/README.md` 가 경고한 그 함정 그대로다.

**`"sprite"` 는 에디터 UI 에 노출되지 않는다.** `locale/ui_en-us.json` 의
`ui_editor_properties_sprite` 는 "sprite **sheet**" 체크박스이고(`ui/dist/scripts/scripts.js`),
동봉 씬 JSON 1,698건 중 `sprite` **오브젝트**를 쓰는 것은 0건이다. 즉 저작 도구가 안 만드는
내부/레거시 타입이다.

---

## 3. 클래스 레이아웃 0x270 과 ctor

ctor `0x140256560–0x140256706`. 시그니처는 `(this, CScene* scene, Json::Value* json)`.

| 오프셋 | 내용 | 근거 VA |
| --- | --- | --- |
| `0x000` | vtable = `0x140491680` | `0x14025657c`, `0x14025658a` |
| `0x000–0x23f` | 씬 오브젝트 공통 베이스(ctor `0x1401ddbb0`) | `0x140256575` |
| `0x0c8` | `CScene*` (베이스가 심음) | `0x1401ddc02` |
| **`0x240`** | 플레어 머티리얼 — `json["sprite"]` 문자열이 곧 머티리얼 경로 | 로드 `0x1402565df`, 저장 `0x1402565e4` |
| **`0x248`** | 지오메트리(정점 4 · 인덱스 6) | 생성 `0x1402566bc`, 저장 `0x1402566c6` |
| **`0x250`** | `materials/util/occlusiontest.json` 머티리얼 | 로드 `0x1402566d4`, 저장 `0x1402566d9` |
| **`0x258`** | **오클루전 쿼리 객체**(0x20 바이트) | 생성 `0x1402566ea`, 저장 `0x1402566f0` |
| **`0x260`** | `int` — 마지막으로 쿼리를 발행한 프레임 번호 | 0 초기화 `0x1402565b3` |
| `0x264–0x26f` | 패딩(할당은 0x270) | — |

vtable `0x140491680` 는 슬롯 21개이고 이 클래스가 **덮어쓰는 것은 둘뿐**이다:
슬롯 0(= 소멸자, `0x140256710`)과 **슬롯 `0x50`(= 렌더, `0x140256780`)**. 나머지는 전부
베이스 구현을 그대로 쓴다. 즉 이 오브젝트의 유일한 고유 행동이 §4 의 오클루전 플레어다.

디스패처는 `0x14018aac0` 의 `call qword ptr [rax+0x50]`(`0x14018ae12`, `0x14018aebc`)이다.

### 지오메트리(프로브/플레어 공용 쿼드)

ctor 가 스택에 20개 float 를 깔아 정점 버퍼로 넘긴다(`r9d=4` @ `0x14025663f`,
인덱스 6개 @ `0x1402566aa`):

| 상수 VA | 값 |
| --- | --- |
| `0x140492b60` | `(-1, 0, 1, 0)` |
| `0x140492e00` | `(0, -1, 0, 1)` |
| `0x140492ba0` | `(1, 0, -1, 0)` |
| `0x140493020` | `(1, 1, 1, -1)` |
| `0x140492df0` | `(0, 1, 0, 1)` |

스택 배치 순서(`0x140256645`/`0x140256667`/`0x140256657`/`0x140256683`/`0x14025667b`)대로
평탄화하면 `[-1,0,1, 0,0][-1,0,1, 1,0][-1,0,1, 1,1][-1,0,1, 0,1]` — 정점당 5 float
(`vec3 a_Position`, `vec2 a_TexCoord`)로 읽으면 **정점 4개가 위치를 공유하고 UV 만
(0,0)(1,0)(1,1)(0,1)** 로 다르다. §1 셰이더의 빌보드 확장과 정확히 맞물린다
(공유 위치값 자체는 `(-1, 0, 1)` 이고 모델 행렬이 실제 배치를 결정한다).

---

## 4. 오클루전 쿼리 — 생성·발행·회수

### 4.1 생성: 확실히 `D3D11_QUERY_OCCLUSION` 이다

ctor 는 디바이스 추상화(`scene+0x1518`)의 vtable 슬롯 `+0x80` 을 호출한다
(`0x1402566ea`). 디바이스 vtable 은 `0x140485b90` 이고 `+0x80` = `0x140485c10` →
**`0x14009ae40`**:

```
0x14009ae40  ; CDevice::CreateOcclusionQuery()
0x14009ae4d  mov   ecx, 0x20                 ; 쿼리 객체 0x20 바이트
0x14009ae52  call  0x14028af20               ; operator new
0x14009ae57  mov   rcx, [rbx+0x70]           ; D3D11 디바이스 래퍼
0x14009ae5b  lea   rdx, [rsp+0x38]           ; &D3D11_QUERY_DESC
0x14009ae63  mov   qword [rsp+0x38], 1       ; ★ {Query = 1, MiscFlags = 0}
0x14009ae6c  lea   rax, [rip+0x3ec275]       ; vtable 0x1404870e8
0x14009ae73  lea   r8,  [rdi+0x10]           ; &ppQuery
0x14009ae86  mov   rcx, [rcx]                ; ID3D11Device*
0x14009ae8c  call  qword [r9+0xc0]           ; ID3D11Device::CreateQuery
```

> **과제 지시의 힌트가 틀렸다.** `D3D11_QUERY_OCCLUSION` 은 **1**이다(3은
> `TIMESTAMP_DISJOINT`, 5가 `OCCLUSION_PREDICATE`). 그래서 `mov dword [x], 3` 패턴으로는
> 안 잡힌다. 실제 코드는 두 UINT 필드를 `mov qword …, 1` 하나로 합쳐 쓴다.

`+0xc0` 은 `ID3D11Device` vtable 의 `CreateQuery` 슬롯이다.

### 4.2 쿼리 래퍼 클래스 (0x20 바이트, vtable `0x1404870e8`)

| 오프셋 | 내용 |
| --- | --- |
| `0x00` | vtable |
| `0x08` | D3D11 디바이스 래퍼(`[0]`=`ID3D11Device*`, `[8]`=`ID3D11DeviceContext*`) |
| `0x10` | `ID3D11Query*` |
| `0x18` | `bool` — Begin 을 한 적이 있는가 |

| vtable 슬롯 | 구현 | 하는 일 |
| --- | --- | --- |
| `0x00` | `0x1400effa0` | 소멸자. `ID3D11Query` Release @ `0x1400effc5`, 크기 0x20 @ `0x1400effe0` |
| `0x08` | `0x1400f0000` | **Begin** — `[this+0x18]=1`(`0x1400f000d`), `ctx->Begin(query)` @ `0x1400f003c` (`[vt+0xd8]`) |
| `0x10` | `0x1400f0050` | **End** — `ctx->End(query)` @ `0x1400f006d` (`[vt+0xe0]`) |
| `0x18` | `0x1400f0090` | **GetResult** — `ctx->GetData(query, &out, 8, 0)` @ `0x1400f00c1` (`[vt+0xe8]`) |

`GetResult` 의 세부가 결정적이다:

```
0x1400f0090  sub   rsp, 0x38
0x1400f0094  cmp   byte [rcx+0x18], 0      ; Begin 안 했으면
0x1400f0098  je    0x1400f00d0             ;   → 0 반환
0x1400f00a7  lea   r8, [rsp+0x40]          ; pData
0x1400f00ac  mov   r9d, 8                  ; ★ DataSize = 8  → UINT64
0x1400f00b2  mov   dword [rsp+0x20], 0     ; GetDataFlags = 0 (DONOTFLUSH 아님)
0x1400f00c1  call  qword [rax+0xe8]        ; GetData — HRESULT 를 버린다
0x1400f00c7  mov   eax, dword [rsp+0x40]   ; UINT64 의 하위 32비트만 사용
```

`DataSize = 8` 은 `D3D11_QUERY_OCCLUSION`(UINT64 샘플 수)에서만 맞는 값이다.
`OCCLUSION_PREDICATE` 였다면 `BOOL`(4)이어야 한다. **§4.1 의 `Query=1` 과 여기 `8` 이
서로를 확인해 준다.**

> **취약점 하나.** `[rsp+0x40]` 은 이 함수가 초기화하지 않는다(호출자 홈 영역).
> `GetData` 가 `S_FALSE`(아직 미완료)를 내면 D3D 는 `pData` 를 쓰지 않으므로 **스택
> 잔값을 밝기로 읽는다.** 통상 1프레임 지연이라 대개 완료되어 있지만, 한 프레임에
> 스프라이트가 2회 이상 렌더되면(멀티 뷰포트) 2회차부터는 이 경로에 걸린다.

### 4.3 렌더 — 발행/회수 순서와 밝기 매핑

렌더는 `0x140256780` 에서 시작해 `0x1402567ad–0x140256a90` 조각으로 이어진다.

```
0x140256780  mov  rdi, [rcx+0xc8]              ; rdi = scene
0x140256799  cmp  byte [rdi+0x12eb], 2         ; 통상 렌더 경로가 아니면
0x1402567a0  jne  0x140256a90                  ;   → 아무것도 안 함
0x1402567a6  mov  rcx, [rcx+0x258]             ; 쿼리
0x1402567cc  call qword [rax+0x18]             ; ★ GetResult()  — 발행보다 먼저 읽는다
```

**픽셀 수 → 밝기.** 상수는 전부 VA 로 못박아 둔다.

```
0x1402567cf  mov      ecx, dword [rdi+0x1a8]   ; lvl = MSAA 지수 (§5)
0x1402567d5  mov      r8d, 1
0x1402567db  cdq
0x1402567dc  shl      r8d, cl                  ; samples = 1 << lvl
0x1402567df  sub      eax, edx
0x1402567e1  sar      eax, 1                   ; n / 2      (부호 있는 정수 나눗셈)
0x1402567e3  cdq
0x1402567e4  idiv     r8d                      ; cov = (n/2) / samples
0x1402567f2  movss    xmm0, dword [rdx+0x78]   ; H = scene+0x78 = g_Screen.y = 화면 높이(px)
0x140256806  mulss    xmm0, xmm0               ; H*H
0x140256810  cvtdq2ps xmm4, xmm4               ; (float)cov
0x140256813  divss    xmm4, xmm0               ; cov / (H*H)
0x14025681a  mulss    xmm4, [0x140492934]      ; ★ × 512.0     (상수 VA 0x140492934)
0x140256829  minss    xmm4, [0x140492704]      ; ★ min(…, 1.0) (상수 VA 0x140492704)
0x140256839  movaps   xmm2, xmm4
0x140256844  addss    xmm2, xmm4               ; 2b
0x140256848  mulss    xmm4, xmm4               ; b²
0x14025685a  shufps   xmm3, xmm3, 0            ; (2b,2b,2b,2b)
```

정리하면

```
n    = query.GetData()                      // 뎁스 테스트를 통과한 "샘플" 수
lvl  = scene[0x1a8]                         // MSAA: none=0, x2=1, x4=2, x8=3
cov  = (int)(n / 2) / (1 << lvl)            // 둘 다 정수 나눗셈, 0 방향 절사
b    = min( 512.0f * (float)cov / (H*H), 1.0f )      // H = 화면 높이(px)
```

`1 << lvl` 은 **샘플 → 픽셀 환산**이다(오클루전 쿼리는 픽셀이 아니라 통과 샘플을 센다).
`/2` 는 그 위에 얹힌 별도의 고정 계수다 — 즉 총 분모는 `2 · samples · H²`, 분자는
`512 · n`. 포화(=1.0)는 `cov ≥ H²/512` 에서다. 1080p·MSAA off 라면
`H²/512 = 2278` 픽셀, 즉 원시 샘플 `n ≈ 4557` 부터 완전 밝기다.

**밝기를 어디에 싣는가.** 시간 보간·슬루는 **없다**. 매 렌더마다 위 `b` 로 씬 유니폼 3종을
그 자리에서 덮고, 그리고 나서 원복한다.

```
; 원본 백업: xmm6..8 = g_ViewUp(scene+0x178..0x180), xmm9..11 = g_ViewRight(scene+0x16c..0x174)
0x14025685e … 0x14025688c   ; 백업
0x140256899  movss  [rax+0x178], xmm0      ; g_ViewUp   *= 2b
0x1402568ac  movsd  [rax+0x17c], xmm0      ;   (나머지 2성분)
0x1402568ce  movss  [rax+0x16c], xmm2      ; g_ViewRight *= 2b
0x1402568d6  movsd  [rax+0x170], xmm0
0x1402568e5  movss  [rax+0x120], xmm4      ; ★ g_Alpha = b²
```

즉 **밝기가 두 갈래로 나간다**:

* **크기** — `g_ViewRight`, `g_ViewUp` 에 `2b` 를 곱한다. §1 셰이더가 이 둘로 쿼드를
  펼치므로 플레어 쿼드의 변 길이가 `2b` 배가 된다(가려질수록 작아진다).
* **불투명도** — `g_Alpha = b²`. 제곱이라 반쯤 가려지면 밝기는 1/4 로 떨어진다.

**모델 행렬 스택 조작.** 그리기 전에 `scene+0x38` 스택을 푸시하고(`0x1402567ee`,
`0x14025680a`, 복사 `0x140256817–0x14025684c`) **평행이동 행을 `(0,0,0,1)` 로 지운다**
(`0x1402568f8`/`0x140256906`/`0x140256914`/`0x140256922`). 행렬 더티 플래그
`scene+0x1ca = 1`(`0x1402567f7`), 끝나면 스택 팝(`0x140256a84`)과 더티 재설정(`0x140256a89`).

**드로우 순서**(가장 중요한 부분 — 지연이 여기서 결정된다):

```
0x140256930  call 0x140155fc0              ; bind(플레어 머티리얼 = this+0x240)
0x14025693f  call qword [rax+8]            ; draw  (this+0x248)           ← 눈에 보이는 플레어
0x140256949  call 0x140157430              ; unbind

0x140256955  mov  ecx, [rax+0x144]         ; scene 프레임 카운터
0x14025695b  cmp  [rbx+0x260], ecx         ; 이번 프레임에 이미 발행했나?
0x140256961  je   0x140256a19              ;   → 발행 스킵
0x140256967  movss xmm2, [0x14049267c]     ; ★ 0.2  (상수 VA 0x14049267c)
0x140256972  mov  [rbx+0x260], ecx         ; 발행 프레임 기록
0x14025697c–0x1402569d2                    ; g_ViewRight, g_ViewUp = 원본 × 0.2
0x1402569e4  call qword [rax+8]            ; query.Begin()
0x1402569ee  call 0x140155fc0              ; bind(occlusiontest = this+0x250)
0x1402569fd  call qword [rax+8]            ; draw  (같은 쿼드)            ← 프로브
0x140256a07  call 0x140157430              ; unbind
0x140256a16  call qword [rax+0x10]         ; query.End()

0x140256a19–0x140256a6e                    ; g_ViewRight/g_ViewUp 원본 복구
```

* **프로브 크기 = 기준 빌보드의 0.2배**(상수 `0x14049267c`). 플레어는 `2b`배이므로
  완전 밝기일 때 프로브는 플레어의 1/10 크기다 — "광원 중심이 보이는가"를 묻는 셈이다.
* **발행은 프레임당 1회**로 게이트된다(`scene+0x144` ↔ `this+0x260`). 회수(`GetResult`)에는
  게이트가 없다.
* **지연은 정확히 1프레임이다.** 회수(`0x1402567cc`)가 발행(`0x1402569e4`)보다 **먼저**
  일어난다. 프레임 N 에서 읽는 값은 프레임 N−1 에 발행한 쿼리의 결과다. 다중 뷰포트로
  한 프레임에 여러 번 렌더되면 2회차부터는 방금 닫힌(아직 미완료일) 쿼리를 읽어
  §4.2 의 미초기화 스택을 읽게 된다.

---

## 5. 씬(`CScene`) 필드 — 어떻게 확정했나

씬 ctor 는 `0x14017c6d0–0x14017d723`. `sceneObject+0xc8` 가 이 객체라는 것은 베이스 ctor
`0x1401ddc02`(`mov [r14+0xc8], rbx`)로 확정된다. 씬은 컨테이너 객체의 `+0x10` 에 놓인
서브오브젝트다(`lea rcx,[rax+0x10]` @ `0x140110ae1` 직후 ctor 호출 `0x140110ae8`) — 이걸
모르면 `0x14017fcfc` 계열 함수의 오프셋이 전부 0x10 어긋나 보인다.

유니폼 이름 ↔ 씬 오프셋은 **추측이 아니라 빌트인 유니폼 업로더의 점프 테이블**로 확정했다.
업로더는 `0x1400d8300` 이고, `movzx edx, word [rsi+r9*2]` (`0x1400d83b3`) 로 유니폼 id 를
읽어 인덱스 테이블 `0x1400daaac` → 점프 테이블 `0x1400da984` 로 분기한다(`0x1400d83c1`,
`0x1400d83ca`). 이름 ↔ id 는 등록 함수 `0x140002860–0x140004321` 에서 나온다(엔트리
stride 0x28, `{int id; std::string name;}`).

| 유니폼 | 스위치 암 VA | 씬 오프셋 | 형 |
| --- | --- | --- | --- |
| `g_Alpha` | `0x1400d83d7` | **`+0x120`** | float |
| `g_Color` | `0x1400d83ef` | `+0x124` | vec3 |
| `g_Color4` | `0x1400d8415` | `(+0x124, +0x128, +0x12c, +0x120)` | vec4 |
| `g_Screen` | `0x1400d84e7` | `(+0x74, +0x78, +0x74/+0x78)` | vec3 = (폭, **높이**, 종횡비) |
| `g_ViewForward` | `0x1400d96b9` | `+0x160` | vec3 |
| **`g_ViewRight`** | `0x1400d96df` | **`+0x16c`** | vec3 |
| **`g_ViewUp`** | `0x1400d9705` | **`+0x178`** | vec3 |
| `g_OrientationForward` | `0x1400d972b` | `+0x184` | vec3 |
| `g_OrientationRight` | `0x1400d9751` | `+0x190` | vec3 |
| `g_OrientationUp` | `0x1400d9777` | `+0x19c` | vec3 |

교차 검증 2건:

* 카메라 갱신 `0x14017fa70–0x1401816cc` 가 뷰 행렬에서 세 벡터를 뽑아 `+0x160`(부호 반전
  `0x14018018c`/`0x140180194`) · `+0x16c`(열 0, `0x140180214`) · `+0x178`(열 1,
  `0x1401802b6`) 순으로 쓴다 — forward/right/up 순서와 일치한다.
  (이 함수의 베이스 레지스터는 컨테이너 객체라 씬보다 `0x10` 낮다 — 위 오프셋은 씬 기준으로
  환산한 값이다. 원문은 각각 `[rsi+0x170]`/`[rsi+0x17c]`/`[rsi+0x188]`.)
* id `0x20` 이후 10개(`g_Texture0..9`)가 전부 기본 암(`0x1400da8ee`)으로 떨어지고,
  그 다음 10개씩 묶음이 `Rotation`/`Translation`/`Resolution`/`Texel`/`MipMapInfo` 공용 암으로
  간다 — 등록 순서와 정확히 겹친다. 이 정렬이 맞지 않으면 위 표는 성립하지 않는다.

그 밖에 이 문서가 쓰는 씬 필드:

| 오프셋 | 뜻 | 근거 |
| --- | --- | --- |
| `+0x38` | 모델 행렬 스택 top(베이스 `this+0x4f0`, 1단 0x40바이트) | ctor `0x14017c72e` |
| `+0x78` | 화면 높이(px). 기본 1.0 | ctor `0x14017c776`, `g_Screen` 암 `0x1400d84e7` |
| `+0x120` | `g_Alpha`. 기본 1.0 | ctor `0x14017c7e7` |
| `+0x144` | 프레임/렌더 사이클 카운터 | 스프라이트 게이트 `0x14025695b`, 드로우 기록 복사 `0x1401b35a2` |
| `+0x1a8` | **MSAA 지수** | ctor `0x14017c88c` ← cfg `0x1401108b7` ← `app+0x240` |
| `+0x1ca` | 행렬 더티 플래그 | 스택 push/pop 마다 세움(`0x140181029`, `0x1401815c8` …) |
| `+0x12eb` | 렌더 패스 종류 바이트 | 기록자는 `0x1401965c9`(=0), `0x140196664`(=2) 둘뿐 |
| `+0x1518` | 그래픽 디바이스 추상화 | ctor `0x14017d01e` |
| `+0x1630` | 머티리얼 매니저 | ctor 소비처 `0x1402565d8`, `0x1402566cd` |

### MSAA 지수의 출처

설정 파서 `0x14010ecb1` 이 설정 키 `"msaa"`(문자열 `0x140476e68`, 바이너리 내 기본값
`"x2"` @ `0x140476e70`)를 읽어 `app+0x240` 에 넣는다:

| 값 | 저장 | VA |
| --- | --- | --- |
| `none`(기본 대입) | 0 | `0x14010ece4` |
| `x2` | 1 | `0x14010ed08` |
| `x4` | 2 | 비교 `0x14010ed2a`, 대입 `0x14010ed3a`(`r15d` — `0x14010ea6e` 에서 2) |
| `x8` | 3 | `0x14010ed68` |

UI 쪽 근거: `locale/ui_en-us.json:808` `ui_settings_gfx_antialiasing`,
`ui/dist/scripts/scripts.js` 의 `antiAliasingOptions = [none, x2, x4, x8]`.
`1 << lvl` = MSAA 샘플 수라는 해석과 정확히 맞는다.

### 패스 게이트(`scene+0x12eb == 2`)

`0x140196530` 이 오프스크린 레이어 렌더 구간에서 이 바이트를 0 으로 내렸다가
(`0x1401965c9`) 구간이 끝나면 2 로 되돌린다(`0x140196664`). 머티리얼 바인드
`0x140155fc0` 는 값이 2 면 단일 패스 직행 경로(`0x1401570f8`)를 타고, 아니면 이 값을
머티리얼 `passes` 배열 인덱스로 쓴다(`0x140156037`). 결과적으로 **스프라이트는
오프스크린/보조 패스에서 그려지지 않고 통상 경로에서만 그려진다.**

---

## 6. 적용 범위 — 왜 파티클이 아닌가

바이너리 전체에서 `call qword [reg+0x80]`(디바이스 vtable 의 `CreateOcclusionQuery` 슬롯)
을 하면서 수신자를 `[reg+0x1518]`(= 씬의 디바이스)에서 얻는 지점을 전수 조사했다.
**결과는 1건**:

```
0x1402566ea  (fn 0x140256560 = sprite::sprite)
```

파티클 시스템(0x960), 파티클 렌더러(sprite / spritetrail / rope / ropetrail), 이미지,
텍스트, 모델 어디에도 오클루전 쿼리가 없다.

**이름 충돌의 출처**는 `locale/ui_en-us.json:3328–3335` 다:

```
ui_editor_particle_element_renderer_rope         : "Rope"
ui_editor_particle_element_renderer_ropetrail    : "Rope trail"
ui_editor_particle_element_renderer_sprite       : "Sprite"   ← 파티클 "렌더러" 이름
ui_editor_particle_element_renderer_spritetrail  : "Sprite trail"
```

파티클 **렌더러 종류** 이름이 `sprite` 이고, 씬 **오브젝트 타입** 이름도 `sprite` 다.
T11 은 이 둘을 같은 것으로 본 것으로 보인다. 0x270 과 0x960 은 별개 클래스다.

---

## 7. 미해결 — 프로브의 컬러 라이트

`occlusiontest.frag` 는 불투명 흰색을 쓴다. 머티리얼 스키마에는 `colorwrite`/`writemask`
키가 없다(바이너리 문자열 0건; `blending`/`cullmode`/`depthwrite`/`depthtest`/
`alphawriting` 만 존재 — 키 클러스터 `0x14048b638` 인근). 그런데도 화면에 흰 사각형이
보이지 않는다면 어딘가가 컬러 라이트를 막는다는 뜻이다.

찾은 흔적: 쿼리 `Begin`/`End` 가 각각 어떤 상태 객체의 vtable `+0xd8` 을 `(0,0)` /
`(1,0)` 으로 호출한다(`0x1400f001d`, `0x1400f0088`). 디바이스 vtable 의 같은 슬롯 구현은
`0x14009aff0` 로, 렌더 스테이트 워드 `device+0x28` 의 **bit9**(0x200)과 **bit3**(0x8)을
두 인자로 세팅한다. bit9 소비처는 `0x140099ff8`:

```
0x140099ff8  movzx eax, word [rdi+0x28]
0x140099ffc  bt    ax, 9
0x14009a001  jae   0x14009a009
0x14009a003  movzx ecx, byte [rdi+0x26]   ; bit9 = 1 → 머티리얼의 블렌드 인덱스
0x14009a009  mov   ecx, 4                 ; bit9 = 0 → 고정값 4
0x14009a015  or    eax, ecx               ; 블렌드 스테이트 캐시 키
```

즉 bit9 이 내려가면 머티리얼 블렌드 대신 고정 상태 4번을 쓴다 — 전형적인
"쿼리 중에는 컬러 라이트 끔" 관용구로 읽힌다. **다만 확정하지 못했다**: 프로브를 그리기
직전의 머티리얼 바인드(`0x1402569ee` → `0x140155fc0`)가 `0x14015726a` 에서 같은 슬롯을
`(1, …)` 로 다시 호출해 bit9 을 도로 세운다. 상태 4번의 실제 내용(블렌드 스테이트 desc)까지는
추적하지 않았다.

이식에서는 어차피 프로브가 색을 남기면 안 되므로 **컬러 라이트 마스크를 명시적으로 끄면
된다**(§8). 이 미해결은 이식의 정확도에 영향을 주지 않는다.

---

## 8. Waple 대조와 Metal 이식 설계

### 8.1 현재 상태

`grep -rn -i "occlusion\|flare" Sources/` 는 113건이 나오지만 **전부 `NSWindow.occlusionState`**
(창 가림 → 영상/웹 일시정지)다. 렌더러 쪽 오클루전 쿼리는 0건이고
`MTLVisibilityResultMode` 사용도 0건이다.

씬 파스에는 이미 자리표시가 있다 — `Sources/WapleCore/SceneDocument.swift:1444` 의
`parseNode` 가 `"sprite"` 를 **콘텐츠 키**로 인정해서 트랜스폼-온리 노드로 흡수되는 것을
막아 둔다. 즉 현재는 "인식은 하되 그리지 않는" 상태다. 이 문서는 그 주석의 두 주장
(0x270, `occlusiontest.json` 로드)을 독립적으로 재확인했고, 나머지 메커니즘 전부를 채운다.

### 8.2 Metal 대응물

| WE / D3D11 | Metal |
| --- | --- |
| `ID3D11Device::CreateQuery(D3D11_QUERY_OCCLUSION)` | 별도 객체 없음. `MTLRenderPassDescriptor.visibilityResultBuffer` 에 `MTLBuffer` 를 물린다 |
| `ctx->Begin(q)` / `ctx->End(q)` | `encoder.setVisibilityResultMode(.counting, offset: k*8)` … `.disabled` |
| `GetData(..., 8, 0)` → UINT64 샘플 수 | 커맨드 버퍼 완료 후 버퍼의 `k*8` 위치에서 `UInt64` 를 읽는다 |
| `D3D11_QUERY_OCCLUSION_PREDICATE` | `.boolean` — **쓰지 말 것**. WE 는 개수를 센다 |
| MSAA 샘플 → 픽셀 환산 `1 << lvl` | `.counting` 도 통과 **샘플**을 세므로 규칙이 그대로 이식된다. 분모는 `rpd.rasterSampleCount` |

`visibilityResultBuffer` 는 렌더 패스 **디스크립터** 속성이라 인코더 단위로만 붙일 수 있다.
Waple 의 2D 경로는 `acc` 텍스처 하나에 인코더를 계속 이어 붙이므로, 프로브를 그리려면
`runOrtho3DMeshes`(`Sources/WapleRender/SceneRendererFrameEncoder.swift:892` 부근)와 같은
**인코더 분할** 패턴을 써야 한다. 마침 프로브는 **뎁스 어태치먼트가 필수**이고
(`resume2D()` 는 "색만 load, 뎁스 없음"), 뎁스가 없으면 가릴 대상 자체가 없으므로 분할은
선택이 아니라 필연이다.

### 8.3 손댈 파일과 함수

**1) `Sources/WapleCore/SceneDocument.swift`**

* `parseSound`(:1408) 옆에 `parseSprite(_ obj: [String: Any]) -> SceneSprite?` 를 추가한다.
  WE 는 `obj["sprite"]` 를 **문자열 = 머티리얼 경로**로 읽는다(타입 검사 `0x1402565c1`–
  `0x1402565d4`, 로드 `0x1402565df`). 문자열이 아니면 팩토리가 이 분기를 건너뛴다
  (`cmp byte [rax+8], 4` @ `0x1401902fe`) — 같은 관용도로 파스한다.
* `SceneSprite` 는 `origin/angles/scale/parent/visible/order` + `material: String`.
  `parseNode`(:1442)의 콘텐츠 키 목록은 이미 `"sprite"` 를 포함하므로 그대로 둔다.

**2) `Sources/WapleRender/SceneRenderer.swift`**

* `DrawItem.Kind`(:643) 에 `case sprite` 추가.
* `drawPlan` 조립(:1531–1534)에 `sprites` 를 `order` 로 끼워 넣는다.
* `depthTextures`(:1149, 크기별 `.depth32Float` 풀)를 프로브 패스의 뎁스로 재사용한다.

**3) `Sources/WapleRender/SceneRendererResources.swift`**

* `visibilityBuffers: [MTLBuffer]` (링 2개) 를 만든다. 길이 = `max(1, spriteCount) * 8`,
  `.storageModeShared`. 오프셋은 **8바이트 정렬 필수**.
* 링이 2개인 이유가 곧 WE 의 1프레임 지연이다: 프레임 N 은 `buf[N%2]` 에 쓰고
  `buf[(N+1)%2]`(= 프레임 N−1 결과)를 읽는다. `waitUntilCompleted` 로 동기화하면
  WE 와 동작이 달라지고 파이프라인도 멈춘다.

**4) `Sources/WapleRender/SceneRendererFrameEncoder.swift`**

* `encodeDrawPlan`(:789) 의 `switch item.kind` 에 `case .sprite:` 를 추가하고
  `runSprite(...)` 로 인코더를 분할한다(`runOrtho3DMeshes` 반환 규약 그대로:
  `-> MTLRenderCommandEncoder?`).
* `runSprite(_ s: GPUSprite, idx: Int, acc:cb:ending:device:time:camOffset:aspectScale:)`:

  1. `enc.endEncoding()`
  2. `rpd`: color = `acc`(`.load`/`.store`), depth = 공용 뎁스(`.load`, store `.dontCare`),
     `rpd.visibilityResultBuffer = visibilityBuffers[frame % 2]`
  3. `let n = visibilityBuffers[(frame + 1) % 2].contents()
        .load(fromByteOffset: idx * 8, as: UInt64.self)`
  4. 밝기 — §4.3 을 그대로:
     ```swift
     let samples = rpd.rasterSampleCount              // WE 의 1 << msaa 에 대응
     let cov     = Int(n) / 2 / samples               // 정수 나눗셈 순서까지 동일
     let h       = Float(sceneHeightPx)               // = WE 의 g_Screen.y
     let b       = min(512.0 * Float(cov) / (h * h), 1.0)
     ```
  5. 플레어 드로우 — `viewRight * 2b`, `viewUp * 2b`, `alpha = b * b`.
     모델 행렬은 평행이동 행을 `(0,0,0,1)` 로 지운 복사본을 쓴다(`0x1402568f8`–`0x140256922`).
  6. 프로브 드로우 — `viewRight * 0.2`, `viewUp * 0.2`,
     `enc.setVisibilityResultMode(.counting, offset: idx * 8)` → draw →
     `.disabled`. 프레임당 1회로 게이트한다(WE 의 `this+0x260` ↔ `scene+0x144`).
  7. `resume2D()` 와 동일하게 2D 인코더 재개.

**5) 셰이더 — `Sources/WapleRender/QuadShaders.swift` (또는 신규 `SpriteFlareShaders.swift`)**

occlusiontest.vert 이식. 정점은 §3 의 "위치 4개 동일 + UV 코너" 그대로 상수 배열이면 된다.

```metal
float3 p = a_Position + (g_ViewRight * (uv.x - 0.5) + g_ViewUp * (uv.y - 0.5)) * 0.5;
float4 c = mvp * float4(p, 1.0);
c.z = 0.999 * c.w;      // 클립 far 로 밀어 넣기
```

Metal NDC 의 z 는 D3D 와 같은 `[0,1]`(0 = near) 이고 Waple 의 뎁스 스테이트는
`depthCompareFunction = .less` + `clearDepth = 1.0`(`Sources/WapleRender/SceneRenderer3D.swift:1169`,
`:1585`)이므로 **WE 의 비-REVERSEDEPTH 분기(`0.999 * w`)를 그대로 쓴다.**
`REVERSEDEPTH` 분기는 필요 없다.

프로브 파이프라인 상태:

* `isDepthWriteEnabled = false` (`occlusiontest.json` 의 `depthwrite: disabled`)
* `depthCompareFunction = .less` (기본 뎁스 테스트 — 이게 곧 오클루전 판정이다)
* `cullMode = .none` (`cullmode: nocull`)
* `colorAttachments[0].writeMask = []` — §7 의 미해결을 안전하게 우회한다. 프로브는
  가시성만 재고 색은 남기면 안 된다.

### 8.4 이식하지 말아야 할 것

* **`GetData` 의 HRESULT 무시**(§4.2). Metal 링 버퍼는 완료 전 값이 이전 프레임 값이라
  잔값 문제가 없다 — 굳이 재현할 이유가 없다.
* **씬 전역 유니폼을 덮었다 되돌리는 방식**. WE 는 `g_ViewRight`/`g_ViewUp`/`g_Alpha` 라는
  **공유** 씬 상태를 임시로 스케일한다(`0x140256899`–`0x1402568e5`, 복구 `0x140256a19`–
  `0x140256a6e`). Waple 은 드로우별 유니폼 버퍼를 쓰므로 스프라이트 인스턴스의 값만
  계산해 넘기면 된다. 결과는 동일하고 재진입 위험이 사라진다.

---

## 9. 재현

```bash
# 자산
cat /path/to/wallpaper_engine/assets/materials/util/occlusiontest.json
cat /path/to/wallpaper_engine/assets/shaders/occlusiontest.vert

# 경로 문자열(1회 등장)
grep -abo "materials/util/occlusiontest.json" wallpaper64.exe     # → 파일오프 4785240 = VA 0x140491658

# MSAA 설정 키
grep -abo "msaa" wallpaper64.exe                                  # → VA 0x140476e68, 기본값 "x2" @ 0x140476e70
```

디스어셈은 `scripts/re/disasm.py <VA> <length>` 로 위 VA 들을 그대로 확인할 수 있다.
`scripts/re/xref.py` 는 짧은 유니폼 이름(`g_ViewUp` 등)의 SSA 조립 적재까지 잡아 준다:

```bash
python3 scripts/re/xref.py g_ViewUp g_ViewRight g_Alpha
```
