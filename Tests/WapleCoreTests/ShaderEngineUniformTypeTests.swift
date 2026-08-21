import XCTest
@testable import WapleCore

/// **엔진 유니폼의 선언 타입 계약(BK/G7) + 전처리기 소수 리터럴·include-once 계약.**
///
/// 왜 따로 있는가
/// -------------
/// 세 갭 모두 **리눅스 스윕이 못 잡는 종류**다.
///
/// - `GLSLBundledShaderRegressionTests` 는 방출된 MSL 에 **방언 토큰이 남았는지**만 본다.
///   `mul(localNormal, g_NormalModelMatrix)` 가 `(float4x4(1.0) * localNormal)` 로 나와도
///   토큰은 전부 MSL 이라 **초록으로 통과**한다 — 깨지는 곳은 Metal 컴파일러이고 그건 리눅스에 없다.
///   그래서 여기서는 **방출 문자열을 값으로** 잠근다.
/// - `#if 1.5` / include-once 는 동봉·설치본 도달이 0 이라 스윕이 아예 그 입력을 안 만든다.
///
/// 근거는 전부 `docs/re/shader-uniforms.md` §1.2/§7.4 와 `docs/re/shader-combos.md` §3.7/§5 다.
final class ShaderEngineUniformTypeTests: XCTestCase {

    // MARK: - G7: 엔진 행렬 유니폼의 선언 타입

    /// 실물 자산 실측(설치본 `assets/` + `projects/` 전수): 엔진 유니폼 56 이름의 선언 타입 중
    /// **치환 타입과 갈리는 것은 `mat3` 3종뿐**이다 —
    /// `g_NormalModelMatrix`(5파일) · `g_AltNormalModelMatrix`(3파일) · `g_ModelMatrix`(2파일).
    /// 앞 둘의 실사용 형태가 이 입력이다(`shaders/generic4.vert:137`
    /// `vec3 normal = normalize(mul(localNormal, g_NormalModelMatrix));`).
    func testMat3EngineMatrixSubstitutesFloat3x3() throws {
        let vert = """
        uniform mat4 g_ModelViewProjectionMatrix;
        uniform mat3 g_NormalModelMatrix;
        attribute vec3 a_Position;
        attribute vec3 a_Normal;
        varying vec3 v_Normal;
        void main() {
            gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
            v_Normal = normalize(mul(a_Normal, g_NormalModelMatrix));
        }
        """
        let frag = """
        varying vec3 v_Normal;
        void main() { gl_FragColor = vec4(v_Normal, 1.0); }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("float3x3(1.0)"),
                      "mat3 선언인데 float3x3 항등이 안 나왔다:\n\(t.msl)")
        // mat3 자리에 float4x4 가 들어가면 `float4x4 * float3` 로 **Metal 컴파일이 확정 실패**한다.
        // 이 셰이더의 다른 행렬(`g_ModelViewProjectionMatrix`)은 `eng.mvp` 로 치환되므로
        // 방출물에 `float4x4(1.0)` 이 남을 자리는 이 갭 하나뿐이다.
        XCTAssertFalse(t.msl.contains("float4x4(1.0)"),
                       "mat3 자리에 float4x4 항등이 남았다:\n\(t.msl)")
        // 엔진 유니폼은 머티리얼 파라미터로 강등되면 안 된다(팬텀 슬롯 방지).
        XCTAssertFalse(t.materialParams.contains { $0.glslName == "g_NormalModelMatrix" })
    }

    /// `mat4` 선언은 **종전과 바이트 동일**이어야 한다 — 표에 없는 타입은 손대지 않는다는 계약.
    /// (`engineDeclaredTypes` 가 `mat4` 를 담지 않는 이유가 이것이다.)
    func testMat4EngineMatrixStillSubstitutesFloat4x4() throws {
        let vert = """
        uniform mat4 g_ModelMatrix;
        attribute vec3 a_Position;
        varying vec3 v_World;
        void main() {
            v_World = mul(vec4(a_Position, 1.0), g_ModelMatrix).xyz;
            gl_Position = vec4(a_Position, 1.0);
        }
        """
        let frag = "varying vec3 v_World;\nvoid main() { gl_FragColor = vec4(v_World, 1.0); }"
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:]))
        // **치환 자리를 값으로** 잠근다. 전역 `contains("float3x3(1.0)")` 로는 못 잠근다 —
        // 프리앰블의 `we_inverse(float3x3)` 가 특이행렬 폴백으로 `return float3x3(1.0);` 를
        // 무조건 싣기 때문이다(그건 이 계약과 무관한 상수).
        XCTAssertTrue(t.msl.contains("(float4x4(1.0) * float4(vin.a_Position, 1.0))"),
                      "mat4 선언의 치환이 종전과 달라졌다:\n\(t.msl)")
        XCTAssertFalse(t.msl.contains("float3x3(1.0) * float4"), t.msl)
    }

    /// 같은 이름이 `mat3` 로 선언되는 실물 자산은 **저작 레인**에도 있다 —
    /// `projects/defaultprojects/{audiophile,fantasticcar}/shaders/grid.vert:2`
    /// `uniform mat3 g_ModelMatrix;`. 그 두 파일은 본문에서 안 쓰지만, 같은 저작이 본문에서 쓰면
    /// 종전 규약으로는 컴파일이 깨진다. 이름별로 표가 잡히는지 확인한다.
    func testEngineDeclaredTypesTableIsNameKeyedAndMat3Only() {
        let us = [
            GLSLTranslator.Uniform(type: .mat3, name: "g_ModelMatrix",
                                   annotationMaterial: nil, annotationDefault: nil, annotationDefaultTexture: nil),
            GLSLTranslator.Uniform(type: .mat4, name: "g_ViewProjectionMatrix",
                                   annotationMaterial: nil, annotationDefault: nil, annotationDefaultTexture: nil),
            // 엔진이 아닌 이름은 담기지 않는다(부류 C 는 머티리얼 파라미터 경로).
            GLSLTranslator.Uniform(type: .mat3, name: "g_UserSpin",
                                   annotationMaterial: nil, annotationDefault: nil, annotationDefaultTexture: nil),
            // mat4x3 은 일부러 제외 — 비정방 `float4x3(1.0)` 의 MSL 유효성 미확인 + 도달 0.
            GLSLTranslator.Uniform(type: .mat4x3, name: "g_SomeMatrix",
                                   annotationMaterial: nil, annotationDefault: nil, annotationDefaultTexture: nil),
        ]
        let table = GLSLTranslator.engineDeclaredTypes(us)
        XCTAssertEqual(table, ["g_ModelMatrix": .mat3])
        XCTAssertEqual(GLSLTranslator.engineReplacement("g_ModelMatrix", engineTypes: table), "float3x3(1.0)")
        XCTAssertEqual(GLSLTranslator.engineReplacement("g_ModelMatrix"), "float4x4(1.0)")  // 표 없으면 종전대로
        XCTAssertEqual(GLSLTranslator.engineReplacement("g_ViewProjectionMatrix", engineTypes: table),
                       "float4x4(1.0)")
    }

    /// 헬퍼로 승격된 경우 — 캡처 파라미터 **선언 타입**과 호출부 **인자 타입**이 같아야 한다.
    /// 종전에는 파라미터가 `float4x4`, 인자가 `float4x4(1.0)` 로 짝은 맞았지만 본문의 `mat3` 연산과
    /// 갈렸다. 이제 둘 다 `float3x3` 이어야 한다(둘 중 하나만 바꾸면 그 자리에서 깨진다).
    func testHelperCaptureOfMat3EngineMatrixUsesFloat3x3OnBothSides() throws {
        let vert = """
        uniform mat3 g_NormalModelMatrix;
        attribute vec3 a_Position;
        attribute vec3 a_Normal;
        varying vec3 v_Normal;
        vec3 toWorld(vec3 n) { return mul(n, g_NormalModelMatrix); }
        void main() {
            v_Normal = toWorld(a_Normal);
            gl_Position = vec4(a_Position, 1.0);
        }
        """
        let frag = "varying vec3 v_Normal;\nvoid main() { gl_FragColor = vec4(v_Normal, 1.0); }"
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("float3x3 g_NormalModelMatrix"),
                      "헬퍼 캡처 파라미터가 float3x3 이 아니다:\n\(t.msl)")
        XCTAssertFalse(t.msl.contains("float4x4 g_NormalModelMatrix"), t.msl)
        XCTAssertTrue(t.msl.contains("float3x3(1.0)"), t.msl)
    }

    // MARK: - 소수 리터럴(실물 0x140167021-0x140167046)

    /// 실물 렉서는 `.` 을 **무조건 소비**하고 소수부 숫자를 읽되 누적기를 안 건드린다 →
    /// `#if 1.5` 는 **1**. 16진 분기도 같은 자리로 합류한다(`0x140166ff1 jmp 0x14016701e`).
    func testDecimalFractionIsReadAndDiscardedLikeEngine() {
        XCTAssertEqual(ExprEval.evalChecked("1.5", defines: [:]), 1)
        XCTAssertEqual(ExprEval.evalChecked("0.9", defines: [:]), 0)
        XCTAssertEqual(ExprEval.evalChecked("2.", defines: [:]), 2)          // `.` 뒤 숫자 없어도 소비
        XCTAssertEqual(ExprEval.evalChecked("1.5f", defines: [:]), 1)        // 접미도 이어서
        XCTAssertEqual(ExprEval.evalChecked("0x10.5", defines: [:]), 16)     // 16진도 같은 합류점
        XCTAssertEqual(ExprEval.evalChecked("3.25 > 2.9", defines: [:]), 1)  // 3 > 2
        // 수 밖의 `.` 는 여전히 미지 문자 → 거부(실물도 토큰 코드 0x19).
        XCTAssertNil(ExprEval.evalChecked(".5", defines: [:]))
        XCTAssertNil(ExprEval.evalChecked("g_Texture0Resolution.x", defines: [:]))
        // 지수 표기는 수 `1` + 식별자 `e5` → 잔여 토큰 → 거부(의도적 이탈, 실물은 관용).
        XCTAssertNil(ExprEval.evalChecked("1e5", defines: [:]))
    }

    /// `#define X 1.5` 가 `#if X` 를 통째로 거부시키던 자리(F421 suspect). 실물은 1 로 본다.
    func testFloatValuedDefineNoLongerRefusesTheWholeShader() {
        let src = """
        #define BLUR 1.5
        #if BLUR
        live;
        #else
        dead;
        #endif
        """
        let out = ShaderPreprocessor.preprocess(src, combos: [:])
        XCTAssertTrue(out.contains("live;"), out)
        XCTAssertFalse(out.contains("dead;"), out)
        // 본문 텍스트 치환은 **원문 그대로**여야 한다 — #if 평가값(1)이 본문으로 새면 안 된다.
        let body = ShaderPreprocessor.preprocess("#define BLUR 1.5\nfloat b = BLUR;", combos: [:])
        XCTAssertTrue(body.contains("float b = 1.5;"), body)
    }

    /// 지수 표기는 여전히 거부 — "오역보다 폴터" 규약이 남아 있는 자리를 함께 못 박는다.
    /// (이게 없으면 위 확장이 거부 규약 전체를 지운 것처럼 읽힌다.)
    func testExponentValuedDefineStillRefuses() {
        let src = "#define BIG 1e5\n#if BIG\nlive;\n#endif"
        XCTAssertNil(ShaderPreprocessor.preprocessStrict(src, combos: [:]))
    }

    // MARK: - G4: include-once (실물 0x1401624b0-0x14016250d)

    /// 실물은 이미 인라인한 **이름**을 만나면 그 줄을 건너뛴다. 헤더에 함수 정의가 있으면
    /// 중복 인라인은 MSL `redefinition` = 폴백이다.
    func testIncludeIsInlinedOncePerStage() {
        var served = 0
        let headers = [
            "common.h": "float weHelper(float x) { return x; }\n",
            "a.h": "#include \"common.h\"\nfloat aFn(float x) { return weHelper(x); }\n",
            "b.h": "#include \"common.h\"\nfloat bFn(float x) { return weHelper(x); }\n",
        ]
        let src = "#include \"a.h\"\n#include \"b.h\"\nvoid main() { gl_FragColor = vec4(aFn(1.0) + bFn(2.0)); }"
        let out = ShaderPreprocessor.preprocess(src, combos: [:], include: { name in
            served += 1
            return headers[name]
        })
        XCTAssertEqual(out.components(separatedBy: "float weHelper").count - 1, 1,
                       "common.h 가 두 번 인라인됐다(중복 정의 = MSL redefinition):\n\(out)")
        XCTAssertTrue(out.contains("float aFn"), out)
        XCTAssertTrue(out.contains("float bFn"), out)
        // 두 번째 `common.h` 는 include() 조차 안 부른다(실물도 목록만 보고 줄을 건너뛴다).
        XCTAssertEqual(served, 3, "요청 횟수: a.h, common.h, b.h 셋이어야 한다")
    }

    /// 직접 순환(`x.h` → `x.h`)도 깊이 캡이 아니라 **이름 목록**으로 끊긴다.
    func testSelfIncludingHeaderTerminatesByNameNotDepth() {
        var served = 0
        let out = ShaderPreprocessor.preprocess("#include \"x.h\"\nbody;", combos: [:], include: { name in
            served += 1
            return name == "x.h" ? "#include \"x.h\"\nfloat xFn() { return 1.0; }\n" : nil
        })
        XCTAssertEqual(served, 1)
        XCTAssertEqual(out.components(separatedBy: "float xFn").count - 1, 1, out)
        XCTAssertTrue(out.contains("body;"), out)
    }

    /// 메모이즈 키(`inlinedSource`)도 같은 규약이어야 한다 — 여기만 두 번 인라인하면
    /// 같은 입력이 서로 다른 키를 받아 캐시가 갈린다.
    func testMemoKeyInlinerSharesIncludeOnce() {
        let headers = ["common.h": "COMMON\n", "a.h": "#include \"common.h\"\nA\n"]
        let key = ShaderPreprocessor.inlinedSource("#include \"a.h\"\n#include \"common.h\"\nmain;",
                                                   include: { headers[$0] })
        XCTAssertEqual(key.components(separatedBy: "COMMON").count - 1, 1, key)
    }
}
