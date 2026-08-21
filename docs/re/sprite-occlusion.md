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

> **이름이 겹치는 세 번째 것이 있다 — 스프라이트*시트*(`.tex` TEXS) 애니메이션.**
> "스프라이트 오클루전" 을 물으면 대개 그쪽을 뜻한다. 결론부터: **프레임 간 오클루전이라는
> 규약은 없다**(한 드로우 = 한 프레임, 겹치는 자리는 `mix()` 크로스페이드, 시트 머티리얼은
> 뎁스 테스트·기록 둘 다 off). 프레임 선택·블렌드·알파 임계값·TEXS 테이블 배선은
> **[§10](#10-2026-08-21-추가-스프라이트시트-애니메이션--프레임-간-오클루전은-없다)** 에 있다.

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
동봉 씬 JSON **172건**(`Sources/WapleRender/Resources/WEAssets/**/{scene,gifscene}.json`) 중
`sprite` **오브젝트**를 쓰는 것은 0건이다.

> **[2026-08-21 정정] 두 가지를 고친다.**
> 1. **분모가 틀렸다.** 이전 판은 "동봉 씬 JSON **1,698건**" 이라 적었는데, 1,698 은
>    `WEAssets` 아래 **`.json` 전체** 수(머티리얼·이펙트·프리셋 포함)다. 그중 씬 문서
>    (`scene.json`+`gifscene.json`)는 **172건**이다. 빈도수에는 반드시 맞는 범위 라벨을 붙여야
>    한다 — 분모가 10배 부풀면 "0건" 의 무게가 실제보다 커 보인다.
> 2. **"저작 도구가 안 만든다" 는 과했다.** 동봉 트리는 설치본 `assets/` 만 비추는데,
>    **설치본 전체 씬 186건**으로 넓히면 `projects/defaultprojects/arsenal/scene.json` 이
>    `sprite` 오브젝트를 **2개** 갖고 있다(둘 다 `name: ""`). 즉 WE 가 **출하하는 기본
>    프로젝트에 실제로 들어 있다.** 형제 문서
>    [`scene-object-model.md`](scene-object-model.md) §2.1 의 `sprite` 행(F=1 · O=2)이 같은 값이다.
>
> 그래서 정확한 문장은 이것이다: **동봉(`assets/`) 도달 0 · 설치본 도달 1파일 2오브젝트.**
> 에디터 UI 에 노출되지 않는다는 결론 자체는 유지된다(로케일·UI 스크립트 근거는 그대로).
> 다만 "레거시라 무시해도 된다" 로 읽지 마라 — 출하 프로젝트가 쓴다.

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
읽어 인덱스 테이블 `0x1400daaac`[VA-데이터표] → 점프 테이블 `0x1400da984` 로 분기한다(`0x1400d83c1`,
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

---

## 10. [2026-08-21 추가] 스프라이트**시트** 애니메이션 — "프레임 간 오클루전" 은 없다

§1–§9 는 씬 오브젝트 타입 `"sprite"`(0x270, 하드웨어 오클루전 쿼리)를 다뤘다. 이 절은
이름이 겹치는 **다른 것** — 스프라이트시트(`.tex` TEXS) 애니메이션 — 의 규약을 잰다.
과제 문구가 "스프라이트시트 애니메이션이 프레임 간에 서로를 가리는 규약" 을 물었기 때문이다.

### 10.0 판정

| 물음 | 답 | 확신 |
| --- | --- | --- |
| 시트 프레임이 서로를 **가리는가**(오클루전) | **아니다.** 한 드로우는 언제나 **한 프레임**만 그린다. 두 프레임이 동시에 등장하는 유일한 자리는 `mix()` **크로스페이드**다 | **확정** — 셰이더 전문(§10.2)과 콤보 게이트(§10.3) |
| 정렬(z) 기준이 있는가 | **없다.** 시트 머티리얼은 `depthtest: disabled` + `depthwrite: disabled` 다 — 뎁스가 아예 관여하지 않는다 | **확정** — 엔진 템플릿 3종 + 실물 시트 머티리얼 전건(§10.1) |
| 알파 테스트 임계값 | 고정기능 알파테스트는 **없다**. `blending:"alphatocoverage"`(열거 3) 일 때만 셰이더가 `discard`, 임계값 **0.5**. 그와 별개로 `CUTOUT` 콤보의 `smoothstep(0.1, 0.2)` 는 discard 가 아니라 알파 감쇠다 | **확정**(§10.5) |
| 같은 프레임 안에서의 그리기 순서 | 레이어 `order` 오름차순. 시트 **진행**은 씬 프레임 카운터로 프레임당 1회만 게이트된다 — 한 프레임에 두 번 그려도 시트가 밀리지 않는다 | **확정**(§10.4.3) |
| `.tex` TEXS 프레임 테이블과 어떻게 물리나 | 이미지 경로: TEXS 프레임의 지오메트리 6개가 **그대로** `g_TextureNRotation`(2×2) + `g_TextureNTranslation`(평행이동) 유니폼이 된다. 파티클 경로: TEXS 를 안 쓰고 `g_RenderVar1` 의 **균일 격자** 가정을 쓴다 | **확정**(§10.4, §10.2) |

한 줄 요약: **"프레임 간 오클루전" 이라는 규약은 실재하지 않는다.** 물어야 할 것은
(a) 프레임 선택, (b) 인접 프레임 **블렌드**, (c) 뎁스가 꺼져 있다는 사실 셋이다.

### 10.1 자산부터 (x86 앞에 — 함정 7)

엔진이 에디터 임포트 템플릿으로 출하하는 스프라이트시트 머티리얼은
`assets/shaders/declarations.json` 의 세 항목이다(`animatedimageshaders`,
`animatedimageshaderssmooth`, `animatedimageshadersn`). **셋 다 동일**:

```json
{ "value": "imagegenericspritesheet", "shader": "genericimage4",
  "blending": "translucent", "depthtest": "disabled", "depthwrite": "disabled",
  "cullmode": "nocull", "combos": { "SPRITESHEET": 1 } }
```

실물 시트 머티리얼도 전건 같다 — 동봉 `scenes/gifs/materials/background.json`(1건),
설치본 `projects/defaultprojects/dino_run/materials/*.json` 9건 +
`projects/templates/gif/materials/background.json` 1건 + `assets/` 사본 1건.
전건이 `depthtest: disabled` · `depthwrite: disabled` · `cullmode: nocull` 이다.

> **뎁스를 읽지도 쓰지도 않으므로 z 정렬이라는 개념 자체가 성립하지 않는다.**
> 시트 레이어끼리의 앞뒤는 오직 그리기 순서(레이어 `order`)가 정한다.

### 10.2 셰이더가 프레임을 고르는 두 방식

**(a) 이미지 경로 — 아핀 UV 변환 하나.** `genericimage4.vert:176`(형제:
`genericimage.vert:29` · `genericimage2.vert:101` · `genericimage3.vert:152` ·
`clippingmaskimage4.vert:110` · `passthrough.vert:4,21`):

```glsl
#if SPRITESHEET
    v_TexCoord.xy = g_Texture0Translation
                  + a_TexCoord.x * g_Texture0Rotation.xy
                  + a_TexCoord.y * g_Texture0Rotation.zw;
#else
    v_TexCoord.xy = a_TexCoord;
#endif
```

**한 드로우에 프레임 하나**다. 프레임 전환은 유니폼 두 개를 바꾸는 것이 전부이고,
프레임 사이에 블렌드도 없다. 이름이 `Rotation` 인 이유는 그것이 2×2 행렬이기 때문이고,
회전해 패킹된 아틀라스 프레임이 바로 이 2×2 로 표현된다(§10.4.4).

**(b) 파티클 경로 — 균일 격자 + 크로스페이드.** `common_particles.h` 의
`ComputeSpriteFrame(lifetime, out uvs, out uvFrameSize, out frameBlend)`:

```glsl
float numFrames  = g_RenderVar1.z;
float frameWidth = g_RenderVar1.x;
float frameHeight= g_RenderVar1.y;
float currentFrame = floor(lifetime * numFrames);
float nextFrame    = min(numFrames - 1.0, currentFrame + 1.0);
uvs.y = floor(currentFrame * frameWidth) * frameHeight;   // 행
uvs.x = frac (currentFrame * frameWidth);                 // 열
uvs.w = floor(nextFrame    * frameWidth) * frameHeight;
uvs.z = frac (nextFrame    * frameWidth);
frameBlend = frac(lifetime * numFrames);
```

`g_RenderVar1 = (frameWidth, frameHeight, numFrames, textureRatio)` 이고
`frameWidth = 1/열수`, `frameHeight = 1/행수` 인 **정규화 격자**다.
`genericparticle.vert:94` 는 위상으로 `frac(in_ParticleLifeTime)` 을 넣는다 —
즉 파티클 한 마리가 제 수명 동안 시트를 정확히 한 바퀴 돈다.

그리고 **인접 두 프레임이 한 화면에 동시에 나오는 유일한 자리**가
`genericparticle.frag:73–77` 이다:

```glsl
#if SPRITESHEETBLEND
    // This is wrong because it can sample colors that are invisible on one frame
    // but changing this can negatively impact additive particles
    vec4 color = v_Color * mix(ConvertTexture0Format(texSample2D(g_Texture0, v_TexCoord.xy)),
                               ConvertTexture0Format(texSample2D(g_Texture0, v_TexCoord.zw)),
                               v_TexCoordBlend);
#else
    vec4 color = v_Color * ConvertTexture0Format(texSample2D(g_Texture0, v_TexCoord.xy));
#endif
```

**가리는 게 아니라 섞는다.** 원저자 주석까지 "한쪽 프레임에서 보이지 않는 색을 샘플할 수
있어 틀렸다" 고 적어 두었다 — 오클루전이 아니라 알파 오염이 이 자리의 실제 문제다.
지오메트리 셰이더 경로(`genericparticle.geom:83`)도 같은 `ComputeSpriteFrame` 을 쓴다.

### 10.3 세 콤보를 켜는 것은 무엇인가 (바이너리)

문자열: `SPRITESHEET` `0x140490180` · `SPRITESHEETBLEND` `0x140490190` ·
`SPRITESHEETBLENDNPOT` `0x140490110`. 파티클 머티리얼 콤보 조립 함수
`0x1401d2340`–`0x1401d3644` 안:

```
0x1401d2d89  test dword ptr [r15+8], 0x1000000   ; ★ 시트 게이트
0x1401d2d91  je   0x1401d2ea0                    ;   아니면 세 콤보 전부 건너뜀
0x1401d2d97  movsd xmm0, [0x140490180]           ; "SPRITESH"  (SSO — 함정 10)
0x1401d2da4  mov   eax, [0x140490187]            ; "HEET"
0x1401d2dc1  mov   qword [rsp+0x40], 0xb         ; 길이 11
0x1401d2dd8  call  0x14015a440                   ; 콤보 맵 슬롯
0x1401d2de2  mov   dword [rax], 1                ; SPRITESHEET = 1
0x1401d2def  lea   rdx, [0x140490190]            ; "SPRITESHEETBLEND"
0x1401d2e27  mov   ecx, [rbp-0x30]
0x1401d2e2a  mov   [rax], ecx                    ; SPRITESHEETBLEND = ecx
0x1401d2e48  lea   rdx, [0x140490110]            ; "SPRITESHEETBLENDNPOT"
0x1401d2e80  movzx ecx, byte ptr [rbp+0x78]
0x1401d2e84  mov   [rax], ecx                    ; SPRITESHEETBLENDNPOT = ecx
```

같은 세 벌이 `0x1401d301f`(이름 조립) / `0x1401d3076`(BLEND `lea`) / `0x1401d30be`(NPOT `lea`)
에 한 번 더 있다(두 번째 렌더 경로).

**`SPRITESHEET` 게이트 비트(0x1000000)를 세우는 자리는 바이너리 전체에서 1곳이다:**

```
0x1401d049c  call 0x14015c470                    ; CTexture::IsSpriteSheet()
0x1401d04a1  test al, al
0x1401d04a5  or   dword ptr [r13+8], 0x1000000
```

그 술어는 4명령 리프다(`.pdata` 엔트리 없음 — 앞뒤가 `cc` 패딩으로 둘러싸여 경계가 자명하다,
`0x14015c460` 부터 `5d c3 cc…cc | 8b 41 1c c1 e8 02 24 01 c3 cc…`):

```
0x14015c470  mov   eax, dword ptr [rcx+0x1c]     ; .tex 헤더 flags
0x14015c473  shr   eax, 2
0x14015c476  and   al, 1                          ; = flags & 0x4  (IsGif / TEXS 존재)
0x14015c478  ret
```

곧 **`SPRITESHEET` 콤보는 `.tex` 헤더의 `flags & 0x4` 하나로 결정된다.** 그 비트가
TEXS 섹션 존재와 **440/440 일치**한다는 것은 형제 문서
[`tex-format.md`](tex-format.md) §4.1 의 실측이다.

**`SPRITESHEETBLEND` = `animationmode != "randomframe"`.** 두 겹으로 인코딩돼 있다.

파스(파티클 def, `0x1401c5490`–`0x1401d152c` 안):

```
0x1401c5717  lea  rdx, [0x14048fd10]              ; "randomframe"
0x1401c5727  mov  dword ptr [r13+0x30], 1         ; 일치
0x1401c5731  mov  dword ptr [r13+0x30], 0         ; 불일치(키 부재 포함)
...
0x1401c57d7  cmp  dword ptr [r13+0x30], 1
0x1401c57de  or   eax, 2                          ; 시스템 flags bit1
0x1401c57e1  mov  dword ptr [r13+8], eax
```

VM 쪽 콤보 결정(`r13d = [r15+8]`):

```
0x1401d24d2  test r13b, 2                         ; randomframe 이면
0x1401d24d6  jne  0x1401d24e6                     ;   → BLEND = 0
0x1401d24d8  cmp  dword ptr [r15+0x30], 0
0x1401d24dd  mov  dword ptr [rbp-0x30], 1
0x1401d24e4  je   0x1401d24ed                     ; [r15+0x30] == 0 → 1 유지
0x1401d24e6  mov  dword ptr [rbp-0x30], 0
```

즉 `randomframe`(스폰 시 한 프레임 고정)이면 크로스페이드를 **끈다** — 고정 프레임에
다음 프레임을 섞으면 틀리기 때문이다. `sequence` 와 키 부재는 **켠다**.

**`SPRITESHEETBLENDNPOT` = 텍스처가 패딩됐는가.**

```
0x1401d24f2  mov  r9d, dword ptr [rcx+0x18]       ; 포맷
0x1401d24f6  mov  eax, dword ptr [rcx+0x20]
0x1401d24f9  cmp  dword ptr [rcx+0x2c], eax
0x1401d2505  setb byte ptr [rbp+0x78]             ; unpadded < alloc → NPOT
```

`common_particles.h` 의 `unpaddedWidth = g_Texture0Resolution.z / g_Texture0Resolution.x`
와 정확히 같은 판정이다(`.z` = 이미지 폭, `.x` = alloc 폭).

### 10.4 TEXS 프레임 테이블 ↔ 유니폼 — 이미지 경로 전문

함수 **`0x14015f0d0`–`0x14015f326`**(`.pdata` 5조각: `…f0d0`/`…f120`/`…f15d`/`…f27c`/`…f2f5`).
서명은 `f(this = CTexture*, edx = 텍스처 슬롯 i)`.

#### 10.4.1 진입 게이트

```
0x14015f0d6  cmp  qword ptr [rcx+0xe0], 0     ; 대체 소스(비디오 등)면
0x14015f0e9  cmp  qword ptr [rcx+0xd8], 0     ;   → 0x14015f2f5 로 위임
0x14015f0f7  test byte ptr [rcx+0x1c], 4      ; ★ 같은 IsGif 비트
0x14015f0fb  je   0x14015f110                 ;   아니면 [st+0x98]=0 하고 리턴
0x14015f0fd  mov  rdx, qword ptr [rcx+0xc0]   ; 프레임 벡터 end
0x14015f104  mov  r11, qword ptr [rcx+0xb8]   ; 프레임 벡터 begin  (stride 0x20)
0x14015f125  mov  rbx, qword ptr [rcx+8]      ; rbx = 유니폼/렌더 상태 오브젝트("씬")
```

프레임 수는 `(end − begin) >> 5` 다(`sar rdx, 5` @`0x14015f13a`) — 인메모리 레코드가
**32바이트**라는 뜻이고, `TexImage.swift` 가 적어 둔 `(f32 frametime, i32 imageId, 6×f32)`
레이아웃과 맞는다.

#### 10.4.2 강제 프레임(시간 무시) — `scene+0x132c`

```
0x14015f129  movsxd rcx, dword ptr [rbx+0x132c]
0x14015f132  js   0x14015f154                 ; 음수면 시간 진행 경로로
0x14015f13e  cmp  rcx, rdx                    ; 범위 밖이면
0x14015f141  cmovae ecx, r9d                  ;   → 0
```

기본값은 씬 ctor 가 심는 **−1** 이다(`0x14017ceac  mov dword ptr [rdi+0x132c], 0xffffffff`).
바이너리 전체에서 이 필드를 쓰는 곳은 5자리뿐이고, 쓰는 쪽은 이미지 레이어 렌더
`0x140206430` 하나다 — 드로우 직전에 레이어의 오버라이드 값을 넣고(`0x1402065a6`)
드로우 뒤 −1 로 되돌린다(`0x1402065bb`).

#### 10.4.3 시간 진행 — 프레임당 1회, 한 번에 한 프레임

```
0x14015f154  mov   eax, dword ptr [rbx+0x144]  ; 씬 프레임 카운터
0x14015f162  cmp   dword ptr [r8+0xa4], eax    ; 이번 프레임에 이미 진행했나
0x14015f169  je    0x14015f175                 ;   → dt = 0
0x14015f16b  movss xmm0, dword ptr [rbx+0x14c] ; dt [추정 — §10.8 참조]
...
0x14015f1b2  addss xmm0, [r8+0xa0]             ; acc += dt
0x14015f1c4  movss xmm1, dword ptr [r10]       ; 현재 프레임의 frametime
0x14015f1c9  comiss xmm0, xmm1
0x14015f1cc  jb    0x14015f26a                 ; acc < ft → 그대로
0x14015f1d2  inc   edi                         ; ★ 딱 한 프레임만 전진
0x14015f1d8  subss xmm0, xmm1                  ; acc -= ft
0x14015f1ef  cmp   rax, rcx
0x14015f1f4  mov   dword ptr [r8+0x9c], r9d    ; 끝을 넘으면 0 으로 랩
0x14015f208  minss xmm0, dword ptr [r10]       ; ★ 잉여를 새 프레임 길이로 자른다
0x14015f275  mov   dword ptr [r8+0xa4], eax    ; 이번 프레임 표시
```

상태는 `[st+0x9c]` 프레임 인덱스 · `[st+0xa0]` 누적시간 · `[st+0xa4]` 마지막 진행 프레임번호다.
읽을 것 셋:

1. **프레임당 1회 게이트.** `scene+0x144`(프레임 카운터) ↔ `[st+0xa4]`. §4.3 의
   `sprite` 오브젝트가 `scene+0x144` ↔ `this+0x260` 으로 쿼리 발행을 게이트한 것과 **같은 관용구**다.
   한 프레임에 같은 시트를 여러 번 그려도 시트는 한 칸만 간다.
2. **루프가 아니라 단발 전진 + 잉여 절사.** `minss` 가 남은 누적시간을 새 프레임의 길이로
   자르므로, **시트는 화면 갱신률보다 빠르게 재생될 수 없고** 초과분은 버려진다.
3. **`frametime == 0` 이면 렌더 프레임당 정확히 한 프레임 전진한다.** `comiss acc, 0` 이
   `jb` 를 안 타고, `subss` 가 0 을 빼고, `minss acc, 0` 이 0 으로 되돌린다.
   → 이것이 `Sources/WapleCore/TexImage.swift` 의 `fallbackFrameTime` 주석이
   "**WE 가 이 자리에 쓰는 값은 RE 로 확정하지 못했다**" 라고 남긴 [미해결]의 답이다:
   **WE 는 아무 값도 안 쓴다. 0 은 "매 렌더 프레임 한 칸" 이라는 뜻이 된다**(디스플레이 종속).
   그 파일은 이 과제 소유가 아니라 손대지 않았다 — 넘길 패치안은 §10.7.

역방향도 대칭으로 있다(`dt < 0` → `0x14015f20f` 분기: `acc += dt`, 0 미만이면 인덱스를 하나
내리고 `addss` 로 이전 프레임 길이를 더한 뒤 `maxss 0`). 즉 **되감기 재생이 규약에 있다.**

#### 10.4.4 업로드 — 지오메트리 6개가 곧 2×2 + 평행이동

```
0x14015f2a3  mov   dword ptr [rbx+rcx*8+0x1cc], eax   ; eax = [r10+0x10]
0x14015f2aa  movss dword ptr [rbx+rcx*8+0x1d0], xmm0  ; xmm0 = [r10+0x14]
0x14015f2b3  movss dword ptr [rbx+rcx*8+0x1d4], xmm1  ; xmm1 = [r10+0x18]
0x14015f2bc  movss dword ptr [rbx+rcx*8+0x1d8], xmm2  ; xmm2 = [r10+0x1c]
0x14015f2c5  mov   rcx, qword ptr [r8+8]              ; 같은 오브젝트
0x14015f2d3  mov   dword ptr [rcx+rsi*8+0x26c], eax   ; eax = [r10+0x08]
0x14015f2da  movss dword ptr [rcx+rsi*8+0x270], xmm0  ; xmm0 = [r10+0x0c]
0x14015f2e8  mov   dword ptr [r8+0x98], r9d           ; r9d = [r10+4] = imageId
```

(`rcx = 2·i`, `rsi = i` 이므로 스트라이드는 각각 16바이트·8바이트다.)

**유니폼 슬롯의 정체는 추측이 아니라 업로더 점프 테이블로 확정했다.** 빌트인 유니폼
업로더 `0x1400d8300` 이 유니폼 id 로 인덱스 표 `0x1400daaac`[VA-데이터표] 를 찍고(`0x1400d83c1`)
점프 표 `0x1400da984` 로 분기한다(`0x1400d83ca`):

| id 범위 | 암 | 읽는 곳 | 뜻 |
| --- | --- | --- | --- |
| `0x20`–`0x29` | `0x1400da8ee`(기본) | — | `g_Texture0..9`(샘플러, 업로드 없음) |
| `0x2a`–`0x33` | **`0x1400d979d`** | `[scene + 16·id − 0xd4]` → id `0x2a` = **`scene+0x1cc`** | `g_TextureNRotation` (vec4) |
| `0x34`–`0x3d` | **`0x1400d97b7`** | `[scene + 8·id + 0xcc]` → id `0x34` = **`scene+0x26c`** | `g_TextureNTranslation` (vec2) |
| `0x3e`–`0x47` | `0x1400d97d5` | — | `g_TextureNResolution` |

> **함정 16 실사례.** 유니폼 등록 함수(`0x140002860`–`0x140004321`)에서
> `mov dword ptr [rbp+0x698], 0x29` 는 `lea rdx, "g_Texture0Rotation"`(`0x1400032f6`)
> **바로 앞**에 있지만 그 `0x29` 는 `g_Texture9` 의 id 다. 이름 `lea` 주변만 읽으면 한 칸
> 밀린다. 위 표는 점프 테이블에서 되짚어 확정한 값이다.

그래서 프레임 하나의 **6개 지오메트리 float** 가 이렇게 착지한다
(TEXS 파일 필드 순서: `x, y, width, widthY, heightX, height`):

| 인메모리 오프셋 | TEXS 필드 | 유니폼 |
| --- | --- | --- |
| `[frame+0x08]` | `x / w` | `g_TextureNTranslation.x` |
| `[frame+0x0c]` | `y / h` | `g_TextureNTranslation.y` |
| `[frame+0x10]` | `width / w` | `g_TextureNRotation.x` |
| `[frame+0x14]` | `widthY / h` | `g_TextureNRotation.y` |
| `[frame+0x18]` | `heightX / w` | `g_TextureNRotation.z` |
| `[frame+0x1c]` | `height / h` | `g_TextureNRotation.w` |
| `[frame+0x04]` | `imageId` | `[st+0x98]`(어느 mip 체인을 바인드할지) |

셰이더식과 합치면

```
uv = (x, y)/dims + u·(width, widthY)/dims + v·(heightX, height)/dims
```

**즉 프레임 사각형은 아핀 2×2 다.** `width` 또는 `height` 가 0 이고 크기가 `heightX`/`widthY`
에서 오는 **회전 프레임**이 여기서 공짜로 처리된다 — `TexImage.TexFrame.rotationQuarters`
가 도출하는 것과 같은 정보다.

그리고 **분모는 이미지 픽셀이 아니라 decode(=alloc) dims** 다. TEXS 리더
(`0x14015e1d0`–`0x14015e57b`, 나눗셈 `0x14015e498`–`0x14015e4eb`)가 **읽는 시점에 이미
나눠서** 넣으므로 위 유니폼은 곧바로 0..1 UV 다 — 이 절은 그 확정 사실과 정합하며,
소비 지점에서 그것을 독립적으로 확인해 준다(런타임에 추가 나눗셈이 **없다**).

**파티클 경로는 이 함수를 안 탄다.** 파티클은 TEXS 프레임 테이블 대신 `g_RenderVar1`
(균일 격자 3값)만 받는다(§10.2b) — 즉 파티클 시트는 "모든 셀이 같은 크기" 를 가정한다.
`.tex-json` 의 `spritesheetsequences[].width/height` 반올림 때문에 저장된 셀 폭이
격자보다 아주 조금 큰 실물이 있다는 형제 문서 [`tex-format.md`](tex-format.md)의 관측과
맞물리는 자리다. **[미해결]** — `g_RenderVar1` 의 세 값을 굽는 코드는 특정하지 못했다
(씬 오프셋 `+0xb8` 로 쓰는 자리를 전수 훑었으나 파티클 렌더 경로에서 못 찾았다).

### 10.5 알파 테스트 임계값

머티리얼 스키마에 알파테스트 키가 **없다**. 키 문자열 클러스터
(`0x14048b560`–`0x14048b6c0`)에 있는 것은 `passes` `keepaspect` `usertextures`
`constantshadervalues` `usertexturereference` `textures` `usershadervalues`
`blending` `shadowcaster` `usershortcut_` `cullmode` `depthwrite` `depthtest`
`alphawriting` 뿐이고, 같은 클러스터의 `ALPHATOCOVERAGE`(`0x14048b5a0`)·
`ADDITIVE`(`0x14048b628`)는 키가 아니라 **셰이더 콤보 이름**이다.

`ALPHATOCOVERAGE` 콤보를 세우는 자리는 셋이고 **조건이 셋 다 같다**:

```
0x140154bc1  cmp byte ptr [r15+0x1f0], 3        ; 머티리얼 로드
0x1401564a4  cmp byte ptr [r12+0x1f0], 3        ; 머티리얼 바인드
0x14020ad1d  cmp byte ptr [rax+0x1f0], 3        ; 레이어 경로 (0x14020ad4a 가 이름 lea)
```

`+0x1f0` 은 `blending` 열거값이고 **3 = `alphatocoverage`** 다(형제 문서
[`material-blend.md`](material-blend.md) §3.2 의 문자열↔열거 표). 그때 셰이더 꼬리가 도는 것은

```glsl
#if ALPHATOCOVERAGE
    gl_FragColor.a = (gl_FragColor.a - 0.5) / max(fwidth(gl_FragColor.a), 0.0001) + 0.5;
#if GLSL
    if (gl_FragColor.a < 0.5) discard;
#endif
#endif
```

이고 **임계값은 0.5** 다(`genericparticle.frag:133`, `genericimage4.frag:223`,
`genericimage3.frag:291`, `generic3.frag:270`, `generic4.frag:185`,
`genericropeparticle.frag:112`, `clippingmaskimage4.frag:24,42`,
`shadowcaster.frag:1,8`, `shadowcasterfoliage4.frag:1,8`,
`base/model_fragment_v1.h:39` — 전 17자리 동일).

`CUTOUT` 은 **다른 것**이다. discard 가 아니라 알파를 부드럽게 깎는다
(`genericparticle.frag:121–123`):

```glsl
color.a = smoothstep(g_CutoutStart, g_CutoutEnd, color.a) * g_CutoutOpacity;
```

기본값은 `g_CutoutStart = 0.1` · `g_CutoutEnd = 0.2` · `g_CutoutOpacity = 1`
(`genericparticle.frag:13–15` 의 애노테이션).

**도달**(§10.6 참조): `blending:"alphatocoverage"` 는 동봉 **0건** · 설치본 **0건**.
`CUTOUT` 콤보를 명시하는 `.json` 은 동봉 11 · 설치본 12.

### 10.6 도달 (범위 라벨 포함)

| 항목 | 동봉 `Sources/WapleRender/Resources/WEAssets/` | 설치본 `wallpaper_engine/` |
| --- | ---: | ---: |
| `.tex` 전체 | 311 | 440 |
| 그중 **TEXS 섹션 보유**(= `flags & 0x4` = SPRITESHEET 대상) | **52** | **61** |
| `SPRITESHEET` 콤보를 명시하는 `.json` | 2 (실물 머티리얼 1 + `shaders/declarations.json`) | 12 (실물 머티리얼 11 + `declarations.json`) |
| `blending: "alphatocoverage"` | **0** | **0** |
| `CUTOUT` 콤보 명시 `.json` | 11 | 12 |
| 파티클 def `animationmode` | `null` 106 · `randomframe` 32 · `sequence` 4 | `null` 108 · `randomframe` 32 · `sequence` 4 |

> **워크샵 코퍼스는 이 컨테이너에 없다.** `/home/user` 어디에도 `431960` 트리가 없어
> 워크샵 도달은 **재지 않았다**(0 이 아니라 **미측정**이다 — 브리프 §2-19).

`animationmode` 값 분포가 그대로 `SPRITESHEETBLEND` 분포다: `randomframe` 32건은
크로스페이드 **꺼짐**, 나머지 110–112건은 **켜짐**.

### 10.7 Waple 대조 · 넘길 것

| WE | Waple 현재 | 판정 |
| --- | --- | --- |
| 이미지 시트 = 아핀 2×2 UV, 한 드로우 한 프레임 | `SceneRendererResources.swift:401` 의 `layer.spritesheet` + `resolveTextureWithFrames` → `spriteSubrect` 서브렉트 | 동치(회전 프레임은 `rotationQuarters` 로 별도 처리) |
| 파티클 시트 = 균일 격자 + `SPRITESHEETBLEND` 크로스페이드 | 크로스페이드 **없음**(프레임 하나만 샘플) | **갭** — 동봉 시트 파티클 다수가 `animationmode` 부재 = 실물은 블렌드 켜짐 |
| `frametime == 0` → 렌더 프레임당 한 칸 | `TexImage.fallbackFrameTime = 0.016` 고정 | 60Hz 에서는 근사 일치(0.016 ≈ 1/62.5). **가변 주사율에서 갈린다** |
| 시트 진행을 씬 프레임 카운터로 1회 게이트 | 시간 기반 `spriteFrameIndex(frames:time:)` — 게이트 없음(멱등이라 무해) | 동치 관측 |
| 시트 머티리얼 `depthtest`/`depthwrite` 둘 다 off | 2D 경로가 뎁스를 안 쓴다 | 동치 |
| `alphatocoverage` → `discard(a < 0.5)` | 3D 만 `alphaCutoff = 0.5` 근사, 2D 미처리 | 동봉 도달 0 이라 무영향([`material-blend.md`](material-blend.md) B2) |

**넘길 패치안 1 — `TexImage.fallbackFrameTime`(소유 밖).** 이 절의 §10.4.3 이
`fallbackFrameTime` doc 주석의 "WE 가 이 자리에 쓰는 값은 확정하지 못했다" 를 닫는다.
주석의 그 문단을 아래로 바꿀 것(값 자체는 그 주석이 이미 적어 둔 이유로 유지):

```
/// **[2026-08-21 해소]** WE 는 이 자리에 **아무 값도 쓰지 않는다.** 시트 진행기
/// (0x14015f0d0–0x14015f326)는 `frametime == 0` 이면 `comiss`(0x14015f1c9)가 통과하고
/// `subss`(0x14015f1d8)가 0 을 빼고 `minss`(0x14015f208)가 누적을 0 으로 되돌려,
/// **렌더 프레임당 정확히 한 프레임** 전진한다(= 디스플레이 종속). 즉 "초/프레임" 이라는
/// 값이 애초에 없다. 헤드리스 결정성이 필요한 Waple 에서는 시간 기반 폴백이 옳고,
/// 60Hz 기준으로 0.016 이 1/62.5 라 관측이 가깝다. 다만 `1.0 / max(1, frameCount)` 가
/// 짝 `.tex-json`(전건 `duration: 1`) 8/8 과 맞는다는 관측은 그대로 유효하다.
```

**넘길 패치안 2 — 파티클 시트 크로스페이드(소유 밖).** `SPRITESHEETBLEND` 가
`animationmode != "randomframe"` 로 켜지므로, `SceneRendererFrameEncoder` 의
`particleSheetFrameIndex` 경로는 현재 프레임 + 다음 프레임(`min(n−1, cur+1)`)을 둘 다
샘플해 `frac(lifetime · n)` 로 `mix` 해야 실물과 같다. `randomframe` 인 def 에서는 꺼야 한다
(`def.animationMode == .randomframe`).

### 10.8 이 절이 못 닫은 것

- **[미해결] `g_RenderVar1`(파티클 시트 격자 3값)을 굽는 코드.** 유니폼 슬롯은
  `scene+0xb8`(업로더 암 `0x1400d9ec0`)로 확정했지만, 파티클 렌더 경로에서 그 자리에
  프레임 수·셀 크기를 넣는 지점을 특정하지 못했다. `+0xb8` 로의 16바이트 스토어는
  이미지 전체에 37자리이고 그중 파티클 경로로 확정되는 것이 없었다.
- **[미해결] `general.spritesheetrefreshsync`(씬 플래그 bit6)의 소비처.**
  프로젝트 플래그 워드 bit11 로 접히는 것까지는 확인했지만(`0x14018339e`), 그 비트를
  읽는 자리를 못 찾았다. 이름으로 보면 §10.4.3 의 프레임 진행을 씬 클록에 묶는 스위치일
  가능성이 크지만 **근거 없음**이다.
- **[미해결] 한 파티클 시스템 안에서 파티클끼리의 그리기 순서.** 뎁스 정렬이 있는지 안 봤다.
  씬 수준의 `transparentsorting` 경로(`0x14018aac0`–`0x14018b22c`)는 형제 문서
  (`SceneDocument.swift` 의 `transparentSorting` 주석)가 이미 [미해결]로 남긴 자리다.
  **[관측 한 줄 보탬]** 그 함수의 FNV-1a(시드 `0xcbf29ce484222325` @`0x14018acbe`,
  소수 `0x100000001b3`)는 **정렬 키가 아니라 오브젝트 포인터 8바이트**를 해싱한다
  (`mov rsi, qword ptr [r14]` @`0x14018ace2` 뒤로 바이트별 `xor`/`imul` 연쇄) — 자료구조
  조회용 해시로 읽힌다. 깊이 정렬 키인지는 여전히 미확정이다.
- **[미해결] `scene+0x14c`(시트 진행에 쓰는 dt)의 기록자.** 이 필드를 **읽는** 자리는
  `0x14015f16b` 하나뿐이고, disp32 스토어는 이미지 전체에 없다(더 큰 블록 이동으로
  쓰이는 것으로 보인다). 단위가 초라는 것은 TEXS `frametime` 과의 직접 비교
  (`comiss` @`0x14015f1c9`)로만 확정했다.

### 10.9 재현

```bash
# 자산 (x86 앞에)
python3 - <<'PY'
import json
j=json.load(open('wallpaper_engine/assets/shaders/declarations.json',encoding='utf-8'))
for k in ('animatedimageshaders','animatedimageshaderssmooth','animatedimageshadersn'):
    print(k, {x:j[k][0].get(x) for x in ('blending','depthtest','depthwrite','cullmode','combos')})
PY
sed -n '61,84p'   wallpaper_engine/assets/shaders/common_particles.h   # ComputeSpriteFrame
sed -n '71,84p'   wallpaper_engine/assets/shaders/genericparticle.frag # SPRITESHEETBLEND mix
sed -n '133,138p' wallpaper_engine/assets/shaders/genericparticle.frag # ALPHATOCOVERAGE 0.5

# 바이너리
python3 scripts/re/disasm.py 0x14015f0d0 0x256    # 시트 진행 + 유니폼 업로드
python3 scripts/re/disasm.py 0x14015c470 0x10     # CTexture::IsSpriteSheet
python3 scripts/re/disasm.py 0x1401d2d89 0x110    # 세 콤보 세팅
```

유니폼 슬롯 확인(추측 금지 — 점프 테이블에서 되짚는다):

```python
from wpe import pe; import struct
idx = pe.read(0x1400daaac, 0x90)   # [VA-데이터표] .text 안 데이터라 디스어셈 대상이 아니다
for i in (0x2a, 0x34, 0x3e):
    a = idx[i]
    rva = struct.unpack('<I', pe.read(0x1400da984 + 4*a, 4))[0]
    print(hex(i), 'arm', hex(0x140000000 + rva))
# 0x2a -> 0x1400d979d (Rotation)  0x34 -> 0x1400d97b7 (Translation)  0x3e -> 0x1400d97d5
```

---

## 11. [2026-08-21 추가] 배선 — Waple 쪽에서 실제로 무엇을 고쳤고 무엇이 남았나

§10 은 규약을 쟀다. 이 절은 그 규약을 Waple 코드에 **얼마나 옮겼는지**를 적는다.
§10 의 본문은 그대로 두고, 이 절이 §10.7 의 "넘길 패치안" 둘을 이어받는다.

> **§10.7 넘길 패치안 1 은 이 절 §11.1 로 대체됐다**(툼스톤 — 값 유지, **사유 교체**).
> **§10.7 넘길 패치안 2 는 이 절 §11.3 으로 대체됐다**(내용 유지, 정확한 패치 전문 추가).

### 11.0 조치표

| §10 이 잰 사실 | Waple 종전 | 이번 라운드 조치 |
| --- | --- | --- |
| `frametime == 0` → 렌더 프레임당 한 칸(값 없음) | `TexImage.swift` 주석이 "**확정 못 했다**" 로 헤지 + "1/frameCount 로 바꿔라" 패치안 | **주석 전면 교체**(§11.1). 헤지는 사실과 다르고 패치안은 **틀렸다** — 값 `0.016` 은 유지 |
| 시트 프레임 쌍 = `floor`/`frac`, `next` 는 **클램프** | 인덱스만 있고 `next`·`blend` 개념 없음 | `TexImage.sheetFramePair(frameCoordinate:frameCount:crossfade:)` 신설 + 리눅스 테스트 9건 |
| `SPRITESHEETBLEND` = `animationmode != "randomframe"` | 게이트 없음 | `SceneRendererFrameEncoder.particleSheetPair` 가 게이트를 진다. **셰이더 배선은 미완**(§11.3) |
| 프레임 지오메트리 = 임의 2×2 아핀 | 축정렬 서브렉트 + `rotationQuarters`(90° 배수) | **배선 안 함** — 일반 아핀 도달이 측정 범위에서 0 이다(§11.4) |
| 시트 게이트 = `.tex` flags bit2 | 파서가 `isGif` 로 이미 읽음 | **배선 불필요** — 동치를 테스트로 잠갔다(§11.5) |

### 11.1 `fallbackFrameTime` — 헤지를 걷어내고, 종전 패치안을 철회한다

종전 `Sources/WapleCore/TexImage.swift` 의 `fallbackFrameTime` 주석은
"**WE 가 이 자리에 쓰는 값은 RE 로 확정하지 못했다**" 라고 적고 있었다. 그 문장은 "값이
있는데 못 찾았다" 로 읽히고, **전제가 틀렸다.** 진행기(`0x14015f0d0`–`0x14015f326`)를
`.pdata` 시작에서 선형으로 다시 떠서 확인한 것:

```
0x14015f0f7  test  byte ptr [rcx+0x1c], 4        ; 시트 게이트(= flags bit2)
0x14015f15a  xorps xmm1, xmm1
0x14015f1c4  movss xmm1, dword ptr [r10]         ; 현재 프레임의 frametime
0x14015f1c9  comiss xmm0, xmm1                   ; acc vs frametime
0x14015f1cc  jb    0x14015f26a                   ;   acc < ft 면 그대로
0x14015f1d2  inc   edi                           ; ★ 한 프레임만
0x14015f1d8  subss xmm0, xmm1                    ; acc -= ft
0x14015f208  minss xmm0, dword ptr [r10]         ; ★ 잉여를 새 프레임 길이로 절사
```

`frametime == 0` 이면 `comiss` 가 `jb` 를 안 태우고, `subss` 가 0 을 빼고, `minss` 가 누적을
0 으로 되돌린다 — **dt 가 얼마든 렌더 프레임당 정확히 한 칸**이다. 호출 자체도 씬 프레임
카운터로 프레임당 1회만 열린다(`0x14015f162` ↔ `0x14015f275`, `[scene+0x144]`). 둘을 합치면
**시트는 화면 갱신률보다 빠르게 재생될 수 없다.** 즉 "초/프레임" 이라는 값이 애초에 없다.

**철회 — 종전 "넘길 패치안: `1.0 / max(1, frameCount)`" 는 틀린 제안이었다.** 근거였던
짝 `.tex-json` 의 `spritesheetsequences[].duration`(TEXS0002 8건 전건 `1`)을 **런타임이 읽지
않는다**(이번에 실측):

* `wallpaper64.exe` 안 `.tex-json` 문자열은 **정확히 1개**(`0x140492348`)이고, 그 자리는
  `resourcecompiler64.exe`(`0x140492330`) · `-mdl -i "`(`0x140492358`) ·
  `-tex -i "`(`0x140492368`) · `Recompiling textu…` 와 한 클러스터다 —
  **리소스 컴파일러 재호출 인자**다.
* `spritesheetsequences` 문자열은 `wallpaper64.exe` 에 **0개**다(ASCII·UTF-16LE 둘 다).
  `duration` 은 3개뿐이고 전부 무관하다(UI 색/base64 클러스터 1 ·
  `minperiodicduration`/`maxperiodicduration` 2).

읽지 않는 키의 값을 런타임 규약으로 삼을 수 없다. 게다가 실제 재생속도로 환산하면 그 제안은
**WE 보다 훨씬 느리다** — 60Hz 에서 WE 는 1/60 ≈ 0.0167 s/프레임인데 `1/frameCount` 는
snow(4프레임) 0.25 → **15배 느림**, debris1(8) 0.125 → 7.5배 느림, fire2·lightning2(32)
0.031 → 1.9배 느림, fire3(128) 0.0078 만 2배 빠르다.

**판단: 값은 `0.016` 을 유지한다.** ① 60Hz 실동작(1/60)의 4% 근사이고, ② 정확히 `1.0/60` 으로
올리려면 형제 자리 셋(`particleSheetFrameIndex` · `SceneRenderer3D` 의 `max(0.016, ft)`)을
같이 올려야 하는데 `SceneRenderer3D.swift` 는 이번 라운드 소유 밖이라 셋을 동시에 못 고친다.
4% 를 얻으려고 "같은 자산이 레이어냐 파티클이냐에 따라 속도가 갈리는" 상태를 만들 수 없다.
③ 도달이 작다 — TEXS0002 는 동봉 311 중 **8**, 설치 440 중 **8**(같은 8건).
워크샵 코퍼스는 이 컨테이너에 없어 **미측정**이다(0 이 아니다).

회귀는 `Tests/WapleCoreTests/TexSpriteSheetBlendTests.swift` 의
`testFallbackFrameTimeApproximatesOneRenderFrameAt60Hz` ·
`testZeroFrameTimeSheetCycleIsFrameCountTimesFallback` 이 잠근다(후자가 `1/frameCount`
되돌림을 직접 잡는다 — 4프레임 시트 한 바퀴가 0.064s 에서 1.0s 로 늘어난다).

### 11.2 크로스페이드를 "쿼드 두 번 그리기" 로 흉내 낼 수 없다

`SPRITESHEETBLEND` 를 셰이더 없이 CPU 에서 흉내 내는 유일한 길은 같은 파티클을 두 번,
현재 프레임 `α·(1−b)` + 다음 프레임 `α·b` 로 그리는 것이다. **그건 다른 식이다.**

WE 는 `mix` 를 **straight-alpha 상태에서** 하고 그 뒤에 premultiply 한다:

```
A   = va · ((1−b)·a0 + b·a1)
RGB = vc · ((1−b)·c0 + b·c1) · A          ← 색과 알파를 각각 섞은 뒤 곱한다
```

두 번 그리기는 premultiply 뒤에 더한다:

```
RGB = vc · va · ((1−b)·a0·c0 + b·a1·c1)   ← 곱한 뒤 섞는다
```

반례 하나면 충분하다. `c0=1, a0=0` · `c1=0, a1=1` · `b=0.5` · `vc=va=1`:
두 번 그리기는 `0`, WE 는 `0.5 × 0.5 = 0.25` 다. 이게 원저자가
`genericparticle.frag:74` 에 "**This is wrong because it can sample colors that are invisible
on one frame**" 이라고 적어 둔 바로 그 자리다 — 한쪽 프레임에서 `a == 0` 인 텍셀의 RGB(인코더가
넣은 검정이나 이웃 색 번짐)가 `mix` 를 타고 보이는 쪽으로 끌려 나온다. **알파 오염이지
오클루전이 아니다.** 원저자가 안 고친 이유도 같이 적혀 있다 — premultiplied 로 섞으면 오염은
사라지지만 가산(additive) 파티클의 밝기 곡선이 바뀐다.

`translucent`(`dst = 1−srcα`)에서는 알파 합성까지 갈린다. `a0=a1=1, va=1, b=0.5`:
두 번 그리기 `0.5 + 0.5·(1−0.5) = 0.75`, WE `1.0`.

> **결론: 이 자리를 "고쳐서" premultiplied 로 섞으면 WE 와 달라진다.** WE 와 같으려면
> straight 로 섞고 **그 다음에** premultiply 해야 한다 — 즉 프래그먼트 셰이더 안이어야 한다.

### 11.3 넘길 패치안 — 파티클 시트 크로스페이드 (소유 밖 파일 포함)

순수 산술은 이번에 들어갔다:

* `TexImage.sheetFramePair(frameCoordinate:frameCount:crossfade:)` — `floor`/`frac` 분해,
  `next = min(n−1, cur+1)`(**랩 아님**), `crossfade == false` 면 `next == current`·`blend == 0`.
* `SceneRendererFrameEncoder.particleSheetPair(...)` — 좌표 산출 + `mode != .randomframe`
  게이트. `particleSheetFrameIndex` 는 이제 그 `.current` 다(값 무변경).

**남은 것은 GPU 쪽 두 파일이다. 정점 스트라이드가 두 파일에 동시에 박혀 있어 반쪽만 넣으면
화면이 깨진다** — 그래서 이번 라운드에 안 넣었다.

`Sources/WapleRender/ParticleShaders.swift`(소유 밖):

```diff
-    struct PVOut { float4 pos [[position]]; float2 uv; float4 color; };
+    struct PVOut { float4 pos [[position]]; float2 uv; float4 color; float2 uv2; float blend; };

     vertex PVOut pv_main(uint vid [[vertex_id]], const device float* v [[buffer(0)]], ...) {
-        uint b = vid * 8;
+        uint b = vid * 12;                       // [ndc.xy, u0,v0, rgba, u1,v1, blend, pad]
         ...
-        PVOut o; o.pos = ...; o.uv = uv; o.color = col; return o;
+        PVOut o; o.pos = ...; o.uv = uv; o.color = col;
+        o.uv2 = float2(v[b + 8], v[b + 9]); o.blend = v[b + 10]; return o;
     }

     fragment float4 pf_main(PVOut in [[stage_in]], texture2d<float> tex [[texture(0)]], ...) {
-        float4 t = tex.sample(s, in.uv);
+        // WE genericparticle.frag:73-77 — straight-alpha 상태에서 mix 하고 **그 뒤에** premultiply.
+        // blend == 0 이면 mix(x, y, 0) == x 라 비트동일(무회귀).
+        float4 t = mix(tex.sample(s, in.uv), tex.sample(s, in.uv2), in.blend);
```

`pf_refract` 도 `pv_main` 을 공유하므로 같은 `mix` 를 넣어야 한다(안 넣으면 굴절 파티클만
크로스페이드가 빠진다). `ParticleShaders.nearestSource` 는 `source` 를 문자열 치환으로 파생시킬
뿐이라 자동으로 따라온다 — 따로 고칠 것 없다. 블렌드 상태는 `src = one`(프리멀티) ·
`dst = one`(additive) / `oneMinusSourceAlpha`(translucent) 이고, §11.2 의 반례는 그 상태를 그대로
가정한 계산이다. 3D 파티클(`pv3d_main` 9 float · `pv3d_fog_main` · 정점 조립은
`SceneRenderer3D.swift`)도 같은 구조라 함께 넓혀야 2D/3D 가 갈리지 않는다 — 세 파일
(`ParticleShaders.swift` · `SceneRenderer3D.swift` · `SceneRendererFrameEncoder.swift`)을
**한 커밋에** 고쳐야 한다는 뜻이다.

`Sources/WapleRender/SceneRendererFrameEncoder.swift`(이 라운드 소유 — **함께** 적용할 것):
`particleVertices` 의 `func v(_:_:)` 를 12 float 로 넓히고, 시트 경로에서
`particleSheetPair` 의 `.next` 로 두 번째 서브렉트 코너를, `.blend` 를 11번째 슬롯에 싣는다.
시트가 없는 시스템은 `uv1 = uv0` · `blend = 0` 을 실으면 **렌더 결과가 비트동일**하다.

**빠뜨리기 쉬운 자리 하나** — `particleVertices` 의 `p.frame >= 0` 분기(mapsequence: 스폰 시
프레임 확정)에서는 `blend = 0` 이어야 한다. 고정 프레임에 다음 프레임을 섞으면 틀리고, 그게
WE 가 `randomframe` 에서 `SPRITESHEETBLEND` 를 끄는 이유와 같은 이유다(§10.3). 그 분기는
`particleSheetPair` 를 아예 안 타므로 게이트가 자동으로 걸리지 않는다.

비용: 2D 파티클 정점 대역폭 +50%. 도달은 크다 — 동봉 파티클 def 289건 중 `randomframe`
32건을 뺀 **257건**이 크로스페이드 켜짐이다(설치본 296 중 264). 즉 이 패치가 들어가면
**시트를 쓰는 파티클의 화면이 실제로 바뀐다.** CI 픽셀 골든(`SyntheticPixelGoldenTests`)에는
파티클 시트가 없어 안 깨지지만, 256×144 기준선 재기준선 부채는 늘어난다.

### 11.4 프레임 지오메트리 아핀 — 도달을 세고 배선을 **안 했다**

§10.4.4 대로 WE 는 프레임의 6개 float 를 그대로 `g_TextureNRotation`(2×2 vec4) +
`g_TextureNTranslation`(vec2) 로 올린다. 업로더 암을 다시 되짚어 확인했다(점프 테이블
`0x1400da984`, 인덱스 표 `0x1400daaac`[VA-데이터표]):

```
0x1400d979d  mov    rax, qword ptr [r14+8]                   ; ── Rotation 암 진입(id 0x2a–0x33)
0x1400d97a1  add    rdx, rdx                                 ;    rdx = 2·id
0x1400d97aa  movups xmm0, xmmword ptr [rax + rdx*8 - 0xd4]   ;    id 0x2a → scene+0x1cc, **16바이트**
0x1400d97b7  mov    rax, qword ptr [r14+8]                   ; ── Translation 암 진입(id 0x34–0x3d)
0x1400d97bb  mov    rcx, rdx                                 ;    rcx = id
0x1400d97c4  mov    rcx, qword ptr [rax + rcx*8 + 0xcc]      ;    id 0x34 → scene+0x26c, **8바이트**
```

즉 vec4 하나 + vec2 하나이고, 진행기의 스토어(`0x14015f2a3`–`0x14015f2bc` 16바이트 스트라이드 ·
`0x14015f2d3`/`0x14015f2da` 8바이트 스트라이드)와 폭·베이스·스트라이드가 정확히 맞는다.
**그래서 WE 는 임의의 아핀(전단·회전)을 표현할 수 있다.**

**그런데 실물이 없다.** 직접 센 결과:

| 범위 | `.tex` | TEXS 보유 | TEXS 프레임 총수 | `widthY≠0 ∨ heightX≠0`(오프대각) | `width==0 ∨ height==0`(회전) | 음수 extent |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 동봉 `Sources/WapleRender/Resources/WEAssets/` | 311 | 52 | 1876 | **0** | **0** | **0** |
| 설치본 `wallpaper_engine/` | 440 | 61 | 1912 | **0** | **0** | **0** |
| 워크샵 코퍼스 | — | — | — | **미측정**(컨테이너에 없다) | 미측정 | 미측정 |

전건이 `diag(width/w, height/h)` 에 둘 다 양수다. Waple 의 축정렬 서브렉트
(`spriteSubrect`) + `rotationQuarters`(90° 배수) 가 **측정 도달 100%** 를 덮는다.
그래서 일반 아핀 배선은 **하지 않는다** — 표본 0 인 코드는 검증할 수 없다.
`TexSpriteSheetBlendTests.testBundledSheetFramesAreAllAxisAligned` 가 이 도달을 못박아,
회전/전단 실물이 자산에 들어오는 날 **테스트가 먼저 깨진다**. 그때 배선하면 된다.

### 11.5 시트 게이트 비트 — Waple 파서는 이미 읽고 있다

WE 의 술어는 4명령 리프 하나다(`.pdata` 엔트리 없음 — 앞뒤 `cc` 패딩으로 경계가 자명,
`0x14015c470` 직전이 `…5d c3 cc…cc`):

```
0x14015c470  mov eax, dword ptr [rcx+0x1c]   ; .tex 헤더 flags
0x14015c473  shr eax, 2
0x14015c476  and al, 1                       ; = flags & 0x4
0x14015c478  ret
```

같은 비트가 **둘 다**를 켠다 — 프레임 진행기 진입(`0x14015f0f7 test byte ptr [rcx+0x1c], 4`)과
`SPRITESHEET` 콤보(`0x1401d04a5 or dword ptr [r13+8], 0x1000000`, 그 직전
`0x1401d049c call 0x14015c470` · `0x1401d04a1 test al, al`; 소비
`0x1401d2d89 test dword ptr [r15+8], 0x1000000`).

> **"유일 세팅" 은 범위를 붙여야 맞다.** 이미지 전체를 바이트로 훑으면 `or r/m32, 0x1000000`
> 은 **5자리**다(§11.7 재현). 그중 파티클 def 의 flags 워드 `[def+8]` 에 쓰는 것은
> `0x1401d04a5` **하나뿐**이고, 나머지 넷은 다른 오브젝트의 다른 오프셋이다 —
> `0x140266f7a or [rsi], …`(함수 `0x140265c30`–`0x140266f99`) ·
> `0x14038acf7`/`0x1403f6ee9`/`0x1403f7d5a` 는 전부 `or [reg+0xd8], …` 로 `.tex`·파티클과
> 무관한 함수들이다. 즉 정확한 문장은 "**파티클 flags 워드에 이 비트를 세우는 자리가 1곳**" 이다. 콤보 문자열도 직접 확인했다 —
`0x140490180` `"SPRITESHEET"` · `0x140490190` `"SPRITESHEETBLEND"` ·
`0x140490110` `"SPRITESHEETBLENDNPOT"`.

Waple 의 `.tex` 파서는 그 비트를 `TexImage.isGif`(`flags & 0x4`)로 **이미 읽는다** — 배선할 게
없다. 대신 동치를 테스트로 잠갔다(`testSheetGateIsTexFlagsBit2AndMatchesTEXSPresence`):
동봉 311건 전부에서 `isGif == (flags & 0x4 != 0)` 이고 `isGif == !frames.isEmpty` 다
(불일치 **0**건 · 시트 **52**건).

> **주의 — 이미지 레이어의 게이트는 텍스처가 아니라 머티리얼이다.** `0x1401d04a5` 는
> **파티클 def 파스 함수**(`0x1401c5490`–`0x1401d152c`) 안이다. 이미지 레이어 쪽 `SPRITESHEET`
> 콤보는 머티리얼 JSON 에 저작돼 온다(§10.1 의 `declarations.json` 3종). Waple 도 같은 모양이다
> — `SceneRendererResources.swift` 의 `layer.spritesheet`(= 머티리얼 콤보) + `frames.count > 1`.
> 두 경로의 게이트 출처가 다르다는 것을 §10.3 한 줄("`.tex` flags 하나로 결정된다")만 읽고
> 뭉뚱그리면 오독한다.

### 11.6 이 절이 못 닫은 것

* **[미해결] 파티클 시트의 위상 정본.** WE 는 `frac(in_ParticleLifeTime)`
  (`genericparticle.vert:94`)을 쓰는데, 그 정점 속성(`a_TexCoordVec4C1.w`)에 CPU 가 무엇을
  굽는지는 **특정하지 못했다.** 강한 정황은 있다 — 파스가 `randomframe` 만 구분하고
  (`[def+0x30]`, `0x1401c5727`/`0x1401c5731`) `sequence` 와 **키 부재를 똑같이** 다루므로,
  WE 에는 "frametime 으로 도는 파티클 시트" 라는 모드가 아예 없고 둘 다
  `frac(수명진행 × sequencemultiplier)` 일 가능성이 크다. 그렇다면 Waple 의 `mode == nil`
  경로(`age / max(0.016, ft)`)는 WE 와 **구조가 다르다**. 정황일 뿐 **근거 없음** — 정점 버퍼를
  채우는 자리를 못 찾았다. 참고로 `mode == .sequence` 경로는 대수적으로 WE 와 같다
  (`floor(z·n) mod n == floor(frac(z)·n)`).
* **[미해결] `g_RenderVar1`(파티클 시트 균일 격자 3값)을 굽는 코드** — §10.8 그대로.
  Waple 은 TEXS 서브렉트를 쓰고 WE 파티클은 균일 격자를 쓰므로, 셀 폭 반올림이 어긋난
  시트(`tex-format.md`)에서 두 구현의 UV 가 갈린다. **[관측 한 줄 보탬]** 프레임 **크기**만
  보면 동봉 시트 **52/52** · 설치본 **61/61 이 균일**하다(한 시트 안의 `|width|`·`|height|`
  집합 크기가 각각 1).
  즉 갈릴 수 있는 것은 크기가 아니라 **위치(격자 원점 누적)**뿐이고, 그게 `tex-format.md` 가
  적은 "저장 셀 폭이 `아틀라스/열수` 보다 아주 조금 크다" 관측과 같은 자리다. 실제 UV 차분은
  아직 안 쟀다.
* **[미해결] `general.spritesheetrefreshsync`(씬 플래그 bit6)의 소비처** — §10.8 그대로.

### 11.7 재현 (이 절의 수치)

```bash
# 도달 — 동봉/설치본 .tex 의 TEXS 프레임 지오메트리 전수
python3 - <<'PY'
import os, struct
def parse(b):
    if len(b) <= 42 or b[:8] != b'TEXV0005': return None
    flags = struct.unpack_from('<i', b, 22)[0]
    i = b.rfind(b'TEXS000')
    if i < 0: return (flags, 0, [])
    ver = b[i+7]-0x30
    if not (1 <= ver <= 3): return (flags, 0, [])
    p = i+9; cnt = struct.unpack_from('<i', b, p)[0]; p += 4
    if not (0 < cnt <= 4096): return (flags, 0, [])
    if ver >= 3: p += 8
    if p + cnt*32 > len(b): return (flags, 0, [])
    fr = []
    for _ in range(cnt):
        g = struct.unpack_from('<6i' if ver == 1 else '<6f', b, p+8)
        fr.append(tuple(float(v) for v in g)); p += 32
    return (flags, ver, fr)
for label, root in {'동봉': 'Sources/WapleRender/Resources/WEAssets',
                    '설치본': 'wallpaper_engine'}.items():
    tex=sheets=frames=off=0
    for dp, dn, fn in os.walk(root):
        for f in fn:
            if not f.endswith('.tex'): continue
            r = parse(open(os.path.join(dp, f), 'rb').read())
            if not r: continue
            flags, ver, fr = r; tex += 1
            if not fr: continue
            sheets += 1; frames += len(fr)
            off += sum(1 for (x, y, w, wy, hx, h) in fr if wy or hx or w == 0 or h == 0)
    print(label, f'.tex {tex} · TEXS {sheets} · 프레임 {frames} · 비축정렬 {off}')
PY
# → 동봉 .tex 311 · TEXS 52 · 프레임 1876 · 비축정렬 0
# → 설치본 .tex 440 · TEXS 61 · 프레임 1912 · 비축정렬 0

# 파티클 def 의 animationmode 분포(술어: 최상위 `emitter` 키)
# → 동봉 289건 {부재 253, randomframe 32, sequence 4} · 설치본 296건 {260, 32, 4}

# 사이드카가 런타임에 안 읽힌다는 것
python3 -c "
import re; d=open('wallpaper_engine/wallpaper64.exe','rb').read()
for s in ('spritesheetsequences','.tex-json'):
    print(s, 'ascii', len(re.findall(re.escape(s.encode()), d)),
             'utf16', len(re.findall(re.escape(s.encode('utf-16le')), d)))"
# → spritesheetsequences ascii 0 utf16 0 · .tex-json ascii 1 utf16 0
```

`or r/m32, 0x1000000` 전수(§11.5 의 범위 라벨 근거) — ModRM 네 형태를 각각 훑는다:

```python
from wpe import pe
import re
base = 0x140001000
buf  = pe.read(base, 0x400000)
for name, p in {
    'mod=00': rb'\x81[\x08-\x0f]\x00\x00\x00\x01',
    'mod=01': rb'\x81[\x48-\x4f].\x00\x00\x00\x01',
    'mod=10': rb'\x81[\x88-\x8f]....\x00\x00\x00\x01',
    'mod=11': rb'\x81[\xc8-\xcf]\x00\x00\x00\x01',
}.items():
    print(name, [hex(base + m.start()) for m in re.finditer(p, buf)])
```

바이트 패턴은 **오탐을 낸다** — 반드시 `.pdata` 시작에서 선형 디스어셈해 확인할 것.
[VA-정정] 실제로 `0x1401d086d`(진짜는 `0x1401d086c or [rcx+r13+0xa4], 0x10000`, SIB 때문에 창이 밀렸다)와
`0x1400a7433`(진짜는 `mov [rcx+0xc8], 1`) 둘이 오탐이었고, 남은 5자리가 진짜다.
