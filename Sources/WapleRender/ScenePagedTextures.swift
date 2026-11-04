import Metal
import WapleCore

extension SceneRenderer {
    struct ParticlePageBatch {
        var system: GPUParticleSystem
        var particles: [Particle]
        let current: Int
        let next: Int
    }

    static func framePair(for particle: Particle, system: GPUParticleSystem) -> TexImage.SheetFramePair {
        if particle.frame >= 0 {
            return TexImage.fixedSheetPair(currentIndex: sheetFrameIndex(sequence: particle.frame,
                frameCount: system.frames.count, mirror: system.mapSeqMirror))
        }
        return particleSheetPair(age: particle.age, lifetime: particle.lifetime,
            frameTime: system.frames.first?.time ?? TexImage.fallbackFrameTime,
            frameCount: system.frames.count, mode: system.def.animationMode,
            seqMul: system.def.sequenceMultiplier)
    }

    func pagedParticleBatches(_ snapshot: [Particle], system: GPUParticleSystem,
                              device: MTLDevice) -> [ParticlePageBatch]? {
        guard let source = pagedTextureSources[ObjectIdentifier(system.texture)], !system.frames.isEmpty else { return nil }
        var batches: [ParticlePageBatch] = []
        for particle in snapshot {
            let pair = Self.framePair(for: particle, system: system)
            let current = system.frames[max(0, min(system.frames.count - 1, pair.current))].imageId
            let next = system.frames[max(0, min(system.frames.count - 1, pair.next))].imageId
            if let last = batches.indices.last, batches[last].current == current, batches[last].next == next {
                batches[last].particles.append(particle)
                continue
            }
            guard let firstTexture = source.texture(page: current, renderer: self, device: device),
                  let nextTexture = source.texture(page: next, renderer: self, device: device) else { continue }
            var selected = system
            selected.texture = firstTexture; selected.nextTexture = nextTexture
            batches.append(ParticlePageBatch(system: selected, particles: [particle], current: current, next: next))
        }
        return batches
    }
}
