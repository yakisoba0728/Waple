import Foundation

/// A narrow adapter for the shipped playlist HLSL, not a general shader translator.
/// Each FADEEFFECT branch stays in the original asset; all 27 variants are exercised by the GPU regression suite.
enum PlaylistTransitionShader {
    enum Failure: Error { case unsupportedEffect, malformedSource }

    static func source(effectID: Int, assets: URL) throws -> String {
        guard (0...26).contains(effectID) else { throw Failure.unsupportedEffect }
        let folder = assets.appendingPathComponent("shaders/HLSL")
        let fragment = try String(contentsOf: folder.appendingPathComponent("dx11playlisttransition.frag"), encoding: .utf8)
        let vertex = try String(contentsOf: folder.appendingPathComponent("dx11playlisttransition.vert"), encoding: .utf8)
        guard let start = fragment.range(of: "float2 rotateFloat2"),
              let end = fragment.range(of: "PS_OUTPUT main"),
              let vertexStart = vertex.range(of: "float4x4 rotation3d") else { throw Failure.malformedSource }
        let body = try adaptSamples(String(fragment[start.lowerBound..<end.lowerBound]))
            .replacingOccurrences(of: "in float2", with: "float2")
            .replacingOccurrences(of: "const in int", with: "const int")
            .replacingOccurrences(of: "inout float distFromRay", with: "thread float &distFromRay")
        let shatter = String(vertex[vertexStart.lowerBound...])
            .replacingOccurrences(of: "VS_OUTPUT main(VS_INPUT IN)", with: "VS_OUTPUT shatter(VS_INPUT IN)")
            // HLSL implicitly truncates float3 to float2 at this call; Metal requires it explicitly.
            .replacingOccurrences(of: "nrand(IN.a_Center *", with: "nrand(IN.a_Center.xy *")
        return "#define FADEEFFECT \(effectID)\n" + header + program + body + shatter + fragmentEntry + vertexEntry
    }

    private static func adaptSamples(_ original: String) throws -> String {
        var source = original
        while let marker = source.range(of: ".SampleLevel(") {
            var depth = 0
            var arguments: [String] = []
            var start = marker.upperBound
            var cursor = start
            while cursor < source.endIndex {
                let character = source[cursor]
                if character == "(" { depth += 1 }
                if character == ")" {
                    if depth == 0 {
                        arguments.append(String(source[start..<cursor]))
                        break
                    }
                    depth -= 1
                }
                if character == ",", depth == 0 {
                    arguments.append(String(source[start..<cursor]))
                    start = source.index(after: cursor)
                }
                cursor = source.index(after: cursor)
            }
            guard cursor < source.endIndex, arguments.count == 3 else { throw Failure.malformedSource }
            source.replaceSubrange(marker.lowerBound...cursor,
                with: ".sample(" + arguments[0] + "," + arguments[1] + ",level(" + arguments[2] + "))")
        }
        return source
    }

    private static let header = #"""
#include <metal_stdlib>
using namespace metal;
#ifndef FADEEFFECT
#define FADEEFFECT 0
#endif
struct Uniforms { float4 p; float4 resolution; float4x4 viewProjection; float4x4 viewProjectionInv; };
#define g_Progress u.p.x
#define g_Hash u.p.y
#define g_Hash2 u.p.z
#define g_Random u.p.w
#define g_AspectRatio u.resolution.x
#define g_Width u.resolution.y
#define g_Height u.resolution.z
#define g_ViewProjection u.viewProjection
#define g_ViewProjectionInv u.viewProjectionInv
#define frac fract
#define lerp mix
#define ddx dfdx
#define ddy dfdy
#define saturate(x) clamp(x,0.0f,1.0f)
#define mul(a,b) ((b)*(a))
float hs(float a,float b,float x) { float t=clamp((x-a)/(b-a),0.0f,1.0f); return t*t*(3.0f-2.0f*t); }
float3 hs(float3 a,float3 b,float3 x) { float3 t=clamp((x-a)/(b-a),0.0f,1.0f); return t*t*(3.0f-2.0f*t); }
#define smoothstep hs
struct VS_OUTPUT { float4 v_Position [[position]]; float2 v_TexCoord; float2 v_TexCoordBase; float3 v_WorldPos; float3 v_WorldNormal; };
struct VS_INPUT { float3 a_Position; float2 a_TexCoord; float3 a_Center; float3 a_Normal; };

"""#

    private static let program = #"""
struct Program { constant Uniforms &u; texture2d<float> g_Texture0; texture2d<float> g_Texture0MipMapped; texture2d<float> g_Texture1Noise; texture2d<float> g_Texture2Clouds; sampler g_Texture0SamplerState; sampler g_Texture0SamplerStateWrap;

"""#

    private static let fragmentEntry = #"""
};
fragment float4 playlistFragment(VS_OUTPUT IN [[stage_in]], constant Uniforms &u [[buffer(0)]], texture2d<float> old [[texture(0)]], texture2d<float> noise [[texture(1)]], texture2d<float> clouds [[texture(2)]]) { constexpr sampler c(coord::normalized,address::clamp_to_edge,filter::linear,mip_filter::linear); constexpr sampler w(coord::normalized,address::repeat,filter::linear); Program p{u,old,old,noise,clouds,c,w}; if(u.p.x<=0) return float4(old.sample(c,IN.v_TexCoord).rgb,1); if(u.p.x>=1) return float4(0); return p.PerformEffect(IN,IN.v_TexCoord,u.p.x); }

"""#

    private static let vertexEntry = #"""

struct PackedVertex { packed_float3 position; packed_float2 uv; packed_float3 center; packed_float3 normal; };
vertex VS_OUTPUT playlistVertex(uint vertexID [[vertex_id]], uint instanceID [[instance_id]],
 constant Uniforms &u [[buffer(0)]], const device PackedVertex *mesh [[buffer(1)]],
 texture2d<float> old [[texture(0)]]) {
 constexpr sampler c(coord::normalized,address::clamp_to_edge,filter::linear);
 Program p{u,old,old,old,old,c,c};
#if FADEEFFECT == 23
 PackedVertex v=mesh[vertexID];
 VS_INPUT input{float3(v.position),float2(v.uv),float3(v.center),float3(v.normal)};
 return p.shatter(input);
#else
 const float2 corners[6]={float2(0,1),float2(0,0),float2(1,1),float2(1,1),float2(0,0),float2(1,0)};
 float2 uv=corners[vertexID];
 VS_OUTPUT result{};
#if FADEEFFECT == 16
 const float brickWidth=2.0f*0.333334f;
 uint set=instanceID/7, brick=instanceID%7;
 uint row=brick<3?0:1, column=brick<3?brick:brick-3;
 float2 size=float2(brickWidth,0.25f);
 float2 origin=float2(-1.0f+(float(column)+(row==0?0.5f:0.0f))*brickWidth,
                     -1.0f+float(set)*0.5f+(float(row)+0.5f)*0.25f);
 float animPosY=origin.y*0.5f+0.5f,animPosX=origin.x*0.5f+0.5f;
 float fallOffset=hs(0.0f,0.3f,g_Progress*1.45f-animPosY-animPosX*0.2f);
 fallOffset=pow(fallOffset,2.0f);
 float2 animOrigin=origin+float2(fallOffset*origin.x*0.333f,-fallOffset*(animPosY+0.2f)*2.6f);
 float angle=fallOffset*3.0f*-origin.x;
 float2 corner=float2(uv.x*2.0f-1.0f,1.0f-uv.y*2.0f);
 float2 halfSize=size*0.5f*float2(g_AspectRatio,1.0f);
 float2 position=animOrigin+p.rotateFloat2(corner*halfSize,angle)/float2(g_AspectRatio,1.0f);
 float2 initial=origin+corner*size*0.5f;
 result.v_Position=float4(position,0,1);
 result.v_TexCoord=float2(initial.x*0.5f+0.5f,0.5f-initial.y*0.5f);
#else
 result.v_Position=float4(uv.x*2.0f-1.0f,1.0f-uv.y*2.0f,0,1);
 result.v_TexCoord=uv;
#endif
 return result;
#endif
}

"""#

}
