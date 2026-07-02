import XCTest
import Metal
@testable import WapleCore
@testable import WapleRender

/// 스파이크: 변환된 opacity 를 풀 경로(reflection→vertex descriptor + material float4 buffer + engine buffer)로
/// 렌더해 바인딩 계약을 검증. 흰색 입력 + alpha=0.5 → straight (1,1,1,0.5) (설계 §3: premult 는 컴포지트 1회).
final class SpikeOpacityTranslatedTests: XCTestCase {
    func testTranslatedOpacityBindingContract() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw XCTSkip("no Metal") }
        let vert = """
        uniform mat4 g_ModelViewProjectionMatrix;
        uniform vec4 g_Texture1Resolution;
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec4 v_TexCoord;
        void main() {
            gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
            v_TexCoord.xy = a_TexCoord;
            v_TexCoord.zw = vec2(v_TexCoord.x * g_Texture1Resolution.z / g_Texture1Resolution.x,
                                v_TexCoord.y * g_Texture1Resolution.w / g_Texture1Resolution.y);
        }
        """
        let frag = """
        varying vec4 v_TexCoord;
        uniform sampler2D g_Texture0; // {"hidden":true}
        uniform sampler2D g_Texture1; // {"combo":"MASK"}
        uniform float g_UserAlpha; // {"material":"alpha","default":1.0}
        void main() {
            vec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy);
        #if MASK
            float mask = texSample2D(g_Texture1, v_TexCoord.zw).r;
        #else
            float mask = 1.0;
        #endif
            albedo.a *= mask * g_UserAlpha;
            gl_FragColor = albedo;
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: ["MASK": 0]))
        let lib = try device.makeLibrary(source: t.msl, options: nil)

        // 정점 디스크립터: attr0 float3@0, attr1 float2@12, stride 20, 버퍼 인덱스 4(p=0/eng=1 와 충돌 회피).
        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3; vd.attributes[0].offset = 0; vd.attributes[0].bufferIndex = 4
        vd.attributes[1].format = .float2; vd.attributes[1].offset = 12; vd.attributes[1].bufferIndex = 4
        vd.layouts[4].stride = 20
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "ev_main")
        pd.fragmentFunction = lib.makeFunction(name: "ef_main")
        pd.vertexDescriptor = vd
        pd.colorAttachments[0].pixelFormat = .rgba8Unorm
        let pipe = try device.makeRenderPipelineState(descriptor: pd)

        // 풀스크린 쿼드(triangle strip): pos NDC + uv
        let quad: [Float] = [
            -1, -1, 0,  0, 1,
             1, -1, 0,  1, 1,
            -1,  1, 0,  0, 0,
             1,  1, 0,  1, 0,
        ]
        let vbuf = device.makeBuffer(bytes: quad, length: MemoryLayout<Float>.stride * quad.count)!
        // material: p[0] = (alpha=0.5, 0,0,0)
        var p: [SIMD4<Float>] = [SIMD4(0.5, 0, 0, 0)]
        let pbuf = device.makeBuffer(bytes: &p, length: MemoryLayout<SIMD4<Float>>.stride)!
        // engine: mvp identity(16) + timeAndPad(4) + texRes[8](32). texRes 는 1 로 채워 div0 회피.
        var eng = [Float](repeating: 0, count: 16 + 4 + 32)
        eng[0] = 1; eng[5] = 1; eng[10] = 1; eng[15] = 1       // identity
        for i in 20..<52 { eng[i] = 1 }                         // texRes = 1
        let ebuf = device.makeBuffer(bytes: eng, length: MemoryLayout<Float>.stride * eng.count)!

        func whiteTex() -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
            d.usage = [.shaderRead]
            let tx = device.makeTexture(descriptor: d)!
            var px: [UInt8] = [255, 255, 255, 255]
            tx.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &px, bytesPerRow: 4)
            return tx
        }
        let tex0 = whiteTex(), tex1 = whiteTex()

        // 오프스크린 타겟
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 8, height: 8, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]; td.storageMode = .shared
        let target = device.makeTexture(descriptor: td)!
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        let cb = queue.makeCommandBuffer()!
        let enc = cb.makeRenderCommandEncoder(descriptor: rpd)!
        enc.setRenderPipelineState(pipe)
        enc.setVertexBuffer(vbuf, offset: 0, index: 4)
        enc.setVertexBuffer(pbuf, offset: 0, index: 0)
        enc.setVertexBuffer(ebuf, offset: 0, index: 1)
        enc.setFragmentBuffer(pbuf, offset: 0, index: 0)
        enc.setFragmentBuffer(ebuf, offset: 0, index: 1)
        enc.setFragmentTexture(tex0, index: 0)
        enc.setFragmentTexture(tex1, index: 1)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()

        var px = [UInt8](repeating: 0, count: 8 * 8 * 4)
        px.withUnsafeMutableBytes { ptr in
            target.getBytes(ptr.baseAddress!, bytesPerRow: 8 * 4, from: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 0)
        }
        // 중앙 픽셀(4,4): straight 출력(설계 §3) (1.0,1.0,1.0,0.5) → R 255, A 128.
        let o = (4 * 8 + 4) * 4
        NSLog("%@", "[Waple] spike opacity px = \(px[o]),\(px[o+1]),\(px[o+2]),\(px[o+3])")
        XCTAssertEqual(Int(px[o]),   255, accuracy: 4, "straight R (premult 는 컴포지트에서)")
        XCTAssertEqual(Int(px[o+3]), 128, accuracy: 4, "alpha")
    }
}
