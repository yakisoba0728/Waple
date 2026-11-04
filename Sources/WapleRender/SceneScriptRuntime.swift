import Foundation
import JavaScriptCore
import WapleCore

/// `slot` is an append-only script identity, independent of authored IDs and draw order.
public struct SceneScriptRuntimeLayerSnapshot {
    public let slot: Int
    public let values: [String: Any]

    public init(slot: Int, values: [String: Any]) {
        self.slot = slot
        self.values = values
    }
}

public struct SceneScriptRuntimeCommand {
    public enum Operation: String {
        case create, destroy, sort, reparent, setProperty
        case animation, textureAnimation, video, particle, bone, morph, camera, scene, geometry
    }

    public let operation: Operation
    public let slot: Int
    public let arguments: [String: Any]
}

extension SceneScriptContext {
    /// Local modules are installed before layer scripts execute; no filesystem or network access from JS.
    public func installModules(_ modules: [String: String]) {
        var compiled: [String: String] = [:]
        var characters = 0
        for path in modules.keys.sorted().prefix(128) {
            guard let source = modules[path], TextScriptEngine.passesPracticalSafetyChecks(source),
                  characters + source.count <= 2 * 1024 * 1024 else { continue }
            characters += source.count
            compiled[path] = TextScriptEngine.stripModuleSyntax(source, moduleExports: true)
        }
        guard let json = SceneScriptRuntime.json(compiled) else { return }
        context.evaluateScript("__wapleRegisterModules(\(json));")
    }

    public func installModules(package: ScenePackage) {
        var modules: [String: String] = [:]
        var total = 0
        for entry in package.entries where entry.name.lowercased().hasSuffix(".js") {
            guard modules.count < 128, entry.size <= 1024 * 1024, total + entry.size <= 2 * 1024 * 1024,
                  let data = package.data(for: entry.name), let source = String(data: data, encoding: .utf8) else { continue }
            modules[entry.name] = source
            total += data.count
        }
        installModules(modules)
    }

    public func publishRuntimeLayers(_ snapshots: [SceneScriptRuntimeLayerSnapshot]) {
        let payload = snapshots.map { ["slot": $0.slot, "values": $0.values] as [String: Any] }
        guard let json = SceneScriptRuntime.json(payload) else { return }
        context.evaluateScript("__waplePublishRuntimeLayers(\(json));")
    }

    public func drainRuntimeCommands() -> [SceneScriptRuntimeCommand] {
        guard let text = context.evaluateScript("__wapleDrainRuntimeCommands()")?.toString(),
              let data = text.data(using: .utf8),
              let values = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return values.compactMap { value in
            guard let name = value["operation"] as? String,
                  let operation = SceneScriptRuntimeCommand.Operation(rawValue: name),
                  let number = value["slot"] as? NSNumber,
                  let arguments = value["arguments"] as? [String: Any] else { return nil }
            return SceneScriptRuntimeCommand(operation: operation, slot: number.intValue, arguments: arguments)
        }
    }

    public func setScreenResolution(width: Float, height: Float) {
        context.evaluateScript("__wapleSetScreenResolution(\(TextScriptEngine.jsNumber(width)), \(TextScriptEngine.jsNumber(height)));")
    }
}

enum SceneScriptRuntime {
    static func json(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func bootstrap(_ context: JSContext) {
        var logCount = 0
        let log: @convention(block) (String, String) -> Void = { level, message in
            guard logCount < 64 else { return }
            logCount += 1
            let bounded = String(message.prefix(2048))
            NSLog("%@", "[Waple SceneScript \(level)] \(bounded)")
        }
        context.setObject(log, forKeyedSubscript: "__wapleScriptLog" as NSString)
        // The bundled classes are the measured WE implementation, not another math approximation.
        if let root = BaseAssetsSettings.bundledAssetsDirectory,
           let source = try? String(contentsOf: root.appendingPathComponent("scripts/jsclasses/baseclasses.js"), encoding: .utf8) {
            context.evaluateScript(source)
        }
        context.evaluateScript(classCompatibility)
        context.evaluateScript(TextScriptEngine.shims)
        context.evaluateScript(source)
    }

    // Native descriptors and events are plain JSON objects; WE's constructors expect class instances.
    static let classCompatibility = #"""
    (function() {
      function adapt(original, dimensions) {
        function vector(x, y, z, w) {
          if (x && typeof x === 'object' && !(x instanceof original)) {
            var fields = ['x', 'y', 'z', 'w'];
            var components = fields.slice(0, dimensions).map(function(k, i) {
              var v = Array.isArray(x) ? x[i] : x[k];
              return typeof v === 'number' ? v : 0;
            });
            return Reflect.construct(original, components);
          }
          return Reflect.construct(original, Array.prototype.slice.call(arguments));
        }
        vector.prototype = original.prototype;
        Object.setPrototypeOf(vector, original);
        var normalize = original.prototype.normalize;
        original.prototype.normalize = function() {
          return this.length() === 0 ? new vector(0) : normalize.call(this);
        };
        return vector;
      }
      if (typeof Vec2 !== 'undefined') { Vec2 = adapt(Vec2, 2); }
      if (typeof Vec3 !== 'undefined') { Vec3 = adapt(Vec3, 3); }
      if (typeof Vec4 !== 'undefined') { Vec4 = adapt(Vec4, 4); }
    })();
    """#

    static let source = #"""
    (function () {
      function writeLog(level, args) {
        var text = Array.prototype.map.call(args, function(value) {
          try { return typeof value === 'string' ? value : JSON.stringify(value); } catch (ignore) { return String(value); }
        }).join(' ').slice(0, 2048);
        if (typeof __wapleScriptLog === 'function') { __wapleScriptLog(level, text); }
      }
      console.log = function() { writeLog('log', arguments); };
      console.error = function() { writeLog('error', arguments); };
      console.warn = function() { writeLog('warning', arguments); };
      var warnedModules = Object.create(null);
      var moduleSources = Object.create(null), moduleInstances = Object.create(null);
      function moduleKey(path, parent) {
        var input = String(path).replace(/\\/g, '/');
        if (input.slice(0, 1) === '.' && parent) { input = parent.slice(0, parent.lastIndexOf('/') + 1) + input; }
        var result = [];
        input.split('/').forEach(function(piece) {
          if (!piece || piece === '.') { return; }
          if (piece === '..') { if (!result.length) { throw new Error('Module path escapes package'); } result.pop(); }
          else { result.push(piece.toLowerCase()); }
        });
        return result.join('/');
      }
      __wapleRegisterModules = function(sources) {
        Object.keys(sources).forEach(function(path) { moduleSources[moduleKey(path)] = sources[path]; });
      };
      __wapleImport = function(path, parent) {
        var key = moduleKey(path, parent);
        var builtin = key.replace(/^scripts\/jsmodules\//, '').replace(/\.js$/, '');
        var module = builtin === 'wecolor' ? __WEColor : builtin === 'wemath' ? __WEMath : builtin === 'wevector' ? __WEVector : null;
        if (module) {
          var result = Object.create(null);
          Object.keys(module).forEach(function(name) { result[name] = module[name]; });
          result.default = module;
          return result;
        }
        var candidates = [key, key + '.js', 'scripts/' + key, 'scripts/' + key + '.js'];
        for (var i = 0; i < candidates.length; ++i) { if (Object.prototype.hasOwnProperty.call(moduleSources, candidates[i])) { key = candidates[i]; break; } }
        if (Object.prototype.hasOwnProperty.call(moduleInstances, key)) { return moduleInstances[key]; }
        if (Object.prototype.hasOwnProperty.call(moduleSources, key)) {
          var exports = Object.create(null);
          moduleInstances[key] = exports;
          try {
            var factory = new Function('exports', '__wapleImport', moduleSources[key]);
            factory(exports, function(child) { return __wapleImport(child, key); });
            return exports;
          } catch (error) { delete moduleInstances[key]; throw error; }
        }
        if (!warnedModules[key] && Object.keys(warnedModules).length < 64) {
          warnedModules[key] = true;
          console.error('Unsupported SceneScript module: ' + path);
        }
        return Object.create(null);
      };
      var slots = [];
      var commands = [];
      var commandCharacters = 0;
      var nextAnimationID = 1000000;
      var maxLayers = 4096;
      var maxCommands = 4096;
      function command(operation, slot, args) {
        if (commands.length >= maxCommands) { throw new Error('SceneScript command budget exceeded'); }
        var encoded = JSON.stringify(args || {});
        if (encoded.length > (operation === 'geometry' ? 8388608 : 262144) || commandCharacters + encoded.length > 16777216) { throw new Error('SceneScript command payload budget exceeded'); }
        commandCharacters += encoded.length;
        commands.push({ operation: operation, slot: slot, arguments: JSON.parse(encoded) });
      }
      function runtime(layer, key) { return (layer.__wapleRuntime || {})[key]; }
      function listIndex(list, selector) {
        if (!list) { return -1; }
        if (typeof selector === 'number') { return Number.isInteger(selector) && selector >= 0 && selector < list.length ? selector : -1; }
        for (var i = 0; i < list.length; ++i) { if (list[i].name === selector) { return i; } }
        return -1;
      }
      function vector(v) { return new Vec3(v || [0, 0, 0]); }
      function transport(layer, operation, selector, read, layerID) {
        var callbacks = [];
        var result = {};
        var pending = { frame: 0, frameCount: 1, fps: 0, duration: 0, rate: 1, blend: 1, visible: true, playing: true, time: 0, loop: true };
        function current() { return read() || pending; }
        function change(action, value) {
          if (typeof value === 'number' && !isFinite(value)) { return result; }
          if (action.slice(0, 3) === 'set') { var property = action[3].toLowerCase() + action.slice(4); pending[property] = value; }
          if (action === 'play') { pending.playing = true; }
          if (action === 'pause' || action === 'stop') { pending.playing = false; }
          if (action === 'stop') { pending.frame = 0; pending.time = 0; }
          var args = { action: action, selector: selector };
          if (typeof layerID === 'number') { args.layerID = layerID; }
          if (value !== undefined) { args.value = value; }
          command(operation, layer.__wapleSlot, args);
          return result;
        }
        ['duration', 'frameCount', 'fps', 'name', 'rate', 'blend', 'visible', 'loop'].forEach(function(key) {
          var writable = ['name', 'rate', 'blend', 'visible', 'loop'].indexOf(key) >= 0;
          Object.defineProperty(result, key, {
            get: function() { return current()[key]; },
            set: writable ? function(value) { change('set' + key[0].toUpperCase() + key.slice(1), value); } : undefined
          });
        });
        result.getFrame = function() { return current().frame; };
        result.setFrame = function(value) { return change('setFrame', Number(value)); };
        result.getCurrentTime = function() { return current().currentTime === undefined ? current().time : current().currentTime; };
        result.setCurrentTime = function(value) { return change('setCurrentTime', Number(value)); };
        result.isPlaying = function() { return !!current().playing; };
        result.play = function() { return change('play'); };
        result.pause = function() { return change('pause'); };
        result.stop = function() { return change('stop'); };
        result.join = function() { return change('join'); };
        result.getAnimation = result.getTextureAnimation = function() { return result; };
        result.setBlend = function(value) { result.blend = value; return result; };
        result.getRate = function() { return result.rate; };
        result.setRate = function(value) { result.rate = value; return result; };
        result.getFrameCount = function() { return result.frameCount; };
        result.getDuration = function() { return result.duration; };
        result.getProgress = function() { return result.frameCount > 0 ? result.getFrame() / result.frameCount : 0; };
        result.setProgress = function(value) { return result.setFrame(value * result.frameCount); };
        result.addEndedCallback = function(callback) {
          if (typeof callback === 'function' && callbacks.length < 64) { callbacks.push(callback); }
        };
        result.__wapleSelector = selector;
        result.__wapleLayerID = layerID;
        result.__wapleNotifyEnded = function() { callbacks.slice().forEach(function(callback) { callback(); }); };
        return result;
      }
      function installLayer(layer) {
        var handles = Object.create(null);
        function handle(operation, selector, read, layerID) {
          var key = operation + ':' + (typeof layerID === 'number' ? 'id-' + layerID : selector);
          return handles[key] || (handles[key] = transport(layer, operation, selector, read, layerID));
        }
        layer.getAnimationLayerCount = function() {
          var list = runtime(layer, 'animationLayers');
          return list ? list.length : layer.animationLayerCount;
        };
        function animationHandle(selector, layerID) {
          return handle('animation', selector, function() {
            var latest = runtime(layer, 'animationLayers') || [];
            if (typeof layerID === 'number') {
              for (var i = 0; i < latest.length; ++i) { if (latest[i].id === layerID) { return latest[i]; } }
              return undefined;
            }
            var index = listIndex(latest, selector);
            return index < 0 ? undefined : latest[index];
          }, layerID);
        }
        layer.getAnimationLayer = function(selector) {
          var list = runtime(layer, 'animationLayers'), index = listIndex(list, selector);
          return animationHandle(selector, index >= 0 ? list[index].id : undefined);
        };
        function createAnimation(animation, config, once) {
          if (nextAnimationID >= 1004096) { throw new Error('SceneScript animation layer budget exceeded'); }
          var id = nextAnimationID++;
          var selector = typeof animation === 'string' ? animation : animation.name;
          command('animation', layer.__wapleSlot, { action: 'create', layerID: id, animation: animation, configuration: config || {}, once: !!once });
          return animationHandle(selector, id);
        }
        layer.createAnimationLayer = function(animation, config) { return createAnimation(animation, config, false); };
        layer.playSingleAnimation = function(animation, config) { return createAnimation(animation, config, true); };
        layer.destroyAnimationLayer = function(value) {
          var list = runtime(layer, 'animationLayers') || [];
          var selector = value && typeof value === 'object' ? value.__wapleSelector : value;
          var index = listIndex(list, selector);
          var id = value && typeof value === 'object' ? value.__wapleLayerID : (index >= 0 ? list[index].id : undefined);
          if (typeof id !== 'number' && index < 0) { return false; }
          command('animation', layer.__wapleSlot, { action: 'destroy', selector: selector, layerID: id });
          return true;
        };
        layer.getTextureAnimation = function() {
          return handle('textureAnimation', 0, function() { return runtime(layer, 'textureAnimation'); });
        };
        layer.getVideoTexture = function() {
          return handle('video', 0, function() { return runtime(layer, 'videoTexture'); });
        };
        layer.getBoneCount = function() { return (runtime(layer, 'bones') || []).length; };
        layer.getBoneIndex = function(name) { return listIndex(runtime(layer, 'bones'), name); };
        layer.getBoneParentIndex = function(bone) {
          var list = runtime(layer, 'bones') || [], index = listIndex(list, bone);
          return index < 0 ? -1 : list[index].parent;
        };
        function boneValue(bone, key) {
          var list = runtime(layer, 'bones') || [], index = listIndex(list, bone);
          return index < 0 ? undefined : list[index][key];
        }
        layer.getBoneTransform = function(bone) { var value = boneValue(bone, 'transform'); return value ? new Mat4(value) : undefined; };
        layer.getLocalBoneTransform = function(bone) { var value = boneValue(bone, 'localTransform'); return value ? new Mat4(value) : undefined; };
        layer.getLocalBoneAngles = function(bone) { var value = boneValue(bone, 'angles'); return value ? vector(value) : undefined; };
        layer.getLocalBoneOrigin = function(bone) { var value = boneValue(bone, 'origin'); return value ? vector(value) : undefined; };
        ['Transform', 'LocalTransform', 'LocalAngles', 'LocalOrigin'].forEach(function(key) {
          var method = key === 'Transform' ? 'setBoneTransform' : 'set' + key.slice(0, 5) + 'Bone' + key.slice(5);
          layer[method] = function(bone, value) {
            if (listIndex(runtime(layer, 'bones'), bone) < 0) { return; }
            command('bone', layer.__wapleSlot, { action: 'set' + key, selector: bone, value: value && value.m ? value.m : value });
          };
        });
        layer.applyBonePhysicsImpulse = function(bone, directional, angular) {
          command('bone', layer.__wapleSlot, { action: 'impulse', selector: bone, directional: directional, angular: angular });
        };
        layer.resetBonePhysicsSimulation = function(bone) { command('bone', layer.__wapleSlot, { action: 'resetPhysics', selector: bone }); };
        layer.getBlendShapeIndex = function(name) { return listIndex(runtime(layer, 'blendShapes'), name); };
        layer.getBlendShapeWeight = function(value) {
          var list = runtime(layer, 'blendShapes') || [], index = listIndex(list, value);
          return index < 0 ? undefined : list[index].weight;
        };
        layer.setBlendShapeWeight = function(value, weight) {
          if (listIndex(runtime(layer, 'blendShapes'), value) >= 0) { command('morph', layer.__wapleSlot, { action: 'setWeight', selector: value, value: Number(weight) }); }
        };
        layer.getAttachmentIndex = function(name) { return listIndex(runtime(layer, 'attachments'), name); };
        layer.getAttachmentMatrix = function(value) {
          var list = runtime(layer, 'attachments') || [], index = listIndex(list, value);
          return index < 0 ? undefined : new Mat4(list[index].transform);
        };
        layer.getAttachmentOrigin = function(value) { var matrix = layer.getAttachmentMatrix(value); return matrix ? matrix.translation() : undefined; };
        layer.getAttachmentAngles = function(value) { var matrix = layer.getAttachmentMatrix(value); return matrix ? matrix.extractEuler() : undefined; };
        function notifyTransform() {
          command('setProperty', layer.__wapleSlot, {property:'transforms',value:{origin:layer.origin,angles:layer.angles,scale:layer.scale}});
        }
        layer.rotateObjectSpace = function(angles) {
          layer.angles = Mat4.fromEuler(layer.angles).multiply(Mat4.fromEuler(vector(angles))).extractEuler();
          notifyTransform();
        };
        function lookAt(center, up, yawOnly) {
          var world = new Mat4(layer.getTransformMatrix().m);
          var eye = world.translation(), target = vector(center);
          if (yawOnly) { target.y = eye.y; }
          if (target.subtract(eye).length() === 0) { return; }
          var desired = Mat4.lookAt(eye, target, up ? vector(up) : new Vec3(0,1,0)).inverse();
          if (layer.parent) { desired = new Mat4(layer.parent.getTransformMatrix().m).inverse().multiply(desired); }
          layer.angles = desired.extractEuler();
          notifyTransform();
        }
        layer.lookAt = function(center, up) { lookAt(center, up, false); };
        layer.lookAtYaw = function(center, up) { lookAt(center, up, true); };
        layer.setParent = function(value, attachment, adjustTransforms) {
          if (typeof attachment === 'boolean') { adjustTransforms = attachment; attachment = undefined; }
          var parent = value === undefined ? null : resolve(value);
          if (value !== undefined && !parent) { return; }
          for (var p = parent, depth = 0; p && depth < maxLayers; p = p.parent, ++depth) { if (p === layer) { return; } }
          var oldWorld = adjustTransforms ? new Mat4(layer.getTransformMatrix().m) : null;
          var oldParent = layer.parent;
          if (oldParent && oldParent.children) { oldParent.children = oldParent.children.filter(function(child) { return child !== layer; }); }
          layer.parent = parent;
          if (parent && parent.children.indexOf(layer) < 0) { parent.children.push(layer); }
          if (oldWorld) {
            var local = parent ? new Mat4(parent.getTransformMatrix().m).inverse().multiply(oldWorld) : oldWorld;
            var parts = local.decompose();
            if (parts.translation.isFinite() && parts.rotation.isFinite() && parts.scale.isFinite()) {
              layer.origin = parts.translation; layer.angles = parts.rotation; layer.scale = parts.scale;
            }
          }
          command('reparent', layer.__wapleSlot, { parentSlot: parent ? parent.__wapleSlot : -1, attachment: attachment, adjustTransforms: !!adjustTransforms,
            transforms:{origin:layer.origin,angles:layer.angles,scale:layer.scale} });
        };
        layer.getChildren = function() { return slots.filter(function(child) { return child.parent === layer && !child.__wapleDestroyed; }); };
        layer.addChild = function(child) { if (child && typeof child.setParent === 'function') { child.setParent(layer); } return layer; };
        layer.__wapleHandles = handles;
      }
      function bind(layer) {
        if (typeof layer.__wapleSlot !== 'number' || slots[layer.__wapleSlot] !== layer) {
          if (slots.length >= maxLayers) { throw new Error('SceneScript layer budget exceeded'); }
          Object.defineProperty(layer, '__wapleSlot', { value: slots.length, configurable: true });
          slots.push(layer);
          installLayer(layer);
        }
        return layer;
      }
      function resolve(value) {
        if (typeof value === 'number') { return thisScene.layers[value] || null; }
        if (typeof value === 'string') {
          for (var i = 0; i < thisScene.layers.length; ++i) {
            if (thisScene.layers[i].name === value || String(thisScene.layers[i].__wapleId) === value) {
              return thisScene.layers[i];
            }
          }
          return null;
        }
        return value && slots.indexOf(value) >= 0 ? value : null;
      }
      function clone(value) { return JSON.parse(JSON.stringify(value)); }
      var detachedLayer = __wapleDetachedLayer;
      __wapleDetachedLayer = function(name) {
        var layer = detachedLayer(name);
        layer.__wapleIsParticle = true;
        bind(layer);
        layer.play = function() { layer.__waplePlaying = true; command('particle',layer.__wapleSlot,{action:'play'}); return layer; };
        layer.pause = function() { layer.__waplePlaying = false; command('particle',layer.__wapleSlot,{action:'pause'}); return layer; };
        layer.stop = function() { layer.__waplePlaying = false; command('particle',layer.__wapleSlot,{action:'stop'}); return layer; };
        layer.isPlaying = function() { var state=runtime(layer,'particle');return state ? !!state.playing : layer.__waplePlaying; };
        layer.getParticleSystem = function() { return layer; };
        layer.emitParticles = function(count) { command('particle',layer.__wapleSlot,{action:'emit',count:count}); };
        return layer;
      };
      var setLayers = __setSceneLayers;
      __setSceneLayers = function (descriptors) {
        setLayers(descriptors);
        slots = [];
        for (var i = 0; i < thisScene.layers.length; ++i) { bind(thisScene.layers[i]); }
      };
      var appendLayers = __appendSceneLayers;
      __appendSceneLayers = function (descriptors, replacePlaceholder) {
        var retained = replacePlaceholder ? thisScene.layers.filter(function(layer) { return layer !== __scenePlaceholderLayer; }) : [];
        var previousSlots = retained.map(function(layer) { return layer.__wapleSlot; });
        var start = appendLayers(descriptors, replacePlaceholder);
        if (replacePlaceholder) { slots = []; }
        for (var i = 0; i < thisScene.layers.length; ++i) { bind(thisScene.layers[i]); }
        // Removing the synthetic placeholder also shifts pre-registration create commands.
        if (replacePlaceholder) {
          var remapped = Object.create(null);
          retained.forEach(function(layer, index) { remapped[previousSlots[index]] = layer.__wapleSlot; });
          commands.forEach(function(value) {
            if (Object.prototype.hasOwnProperty.call(remapped, value.slot)) { value.slot = remapped[value.slot]; }
            if (Object.prototype.hasOwnProperty.call(remapped, value.arguments.parentSlot)) { value.arguments.parentSlot = remapped[value.arguments.parentSlot]; }
          });
        }
        return thisScene.layers[start] ? thisScene.layers[start].__wapleSlot : slots.length;
      };
      var soundLayers = __setSoundLayers;
      __setSoundLayers = function(names) {
        soundLayers(names);
        for (var i = 0; i < thisScene.layers.length; ++i) { bind(thisScene.layers[i]); }
      };
      var updateLayers = __updateSceneLayers;
      __updateSceneLayers = function (descriptors, start) {
        var ordered = thisScene.layers;
        thisScene.layers = slots;
        try { updateLayers(descriptors, start); } finally { thisScene.layers = ordered; }
      };
      __wapleLayerForScript = function (name, index) {
        if (typeof index === 'number' && slots[index]) { return slots[index]; }
        return resolve(name) || thisLayer;
      };
      thisScene.createLayer = function (configuration) {
        if (configuration && configuration.__wapleGeometryID) { configuration = {model:{__wapleGeometryID:configuration.__wapleGeometryID}}; }
        if (configuration && configuration.__wapleAsset) { configuration = {asset: configuration.__wapleAsset}; }
        if (typeof configuration === 'string') { configuration = { name: configuration, asset: configuration }; }
        if (!configuration || typeof configuration !== 'object') { throw new Error('Invalid layer configuration'); }
        var layer = bind(__makeLayer());
        __wapleApplyLayerConfig(layer, configuration);
        layer.name = String(configuration.name || '');
        layer.__wapleInitialConfig = clone(configuration);
        this.layers.push(layer);
        command('create', layer.__wapleSlot, { configuration: configuration });
        return layer;
      };
      thisScene.sortLayer = function (value, index) {
        var layer = resolve(value);
        if (!layer || typeof index !== 'number' || !isFinite(index)) { return false; }
        var old = this.layers.indexOf(layer);
        this.layers.splice(old, 1);
        var next = Math.max(0, Math.min(this.layers.length, Math.floor(index)));
        this.layers.splice(next, 0, layer);
        layer.__wapleSortIndex = Math.floor(index);
        command('sort', layer.__wapleSlot, { index: next });
        return true;
      };
      thisScene.destroyLayer = function (value) {
        var layer = resolve(value);
        if (!layer || layer.__wapleDestroyed) { return false; }
        layer.__wapleDestroyed = true;
        layer.visible = false;
        command('destroy', layer.__wapleSlot);
        return true;
      };
      thisScene.getInitialLayerConfig = function (value) {
        var layer = resolve(value);
        if (!layer) { return null; }
        return clone(layer.__wapleInitialConfig || {});
      };
      var nextGeometryID = 1;
      var geometryHandles = Object.create(null);
      function geometryJSON(value) {
        if (value === null) { return null; }
        if (ArrayBuffer.isView(value)) { return Array.prototype.slice.call(value); }
        if (Array.isArray(value)) { return value.map(geometryJSON); }
        if (value && typeof value === 'object') {
          var out = {};
          Object.keys(value).forEach(function(key) { if (typeof value[key] !== 'function') { out[key] = geometryJSON(value[key]); } });
          return out;
        }
        if (typeof value === 'number' && !isFinite(value)) { throw new Error('Model data must contain finite numbers'); }
        return value;
      }
      thisScene.createModelData = function(configuration) {
        if (!configuration || typeof configuration !== 'object' || nextGeometryID > 4096) { throw new Error('Invalid model data or model data budget exceeded'); }
        var id = nextGeometryID++;
        var handle = typeof IModelData === 'function' ? new IModelData() : {};
        Object.defineProperty(handle,'__wapleGeometryID',{value:id,enumerable:true});
        handle.applyData = function(shapes) {
          if (handle.__wapleDestroyed) { throw new Error('Model data has been destroyed'); }
          command('geometry',-1,{action:'apply',geometryID:id,shapes:geometryJSON(shapes)});
        };
        handle.replaceData = function(shapes) {
          if (typeof __wapleInScriptUpdate !== 'undefined' && __wapleInScriptUpdate) { throw new Error('replaceData cannot be called in update'); }
          if (handle.__wapleDestroyed) { throw new Error('Model data has been destroyed'); }
          command('geometry',-1,{action:'replace',geometryID:id,shapes:geometryJSON(shapes)});
        };
        geometryHandles[id] = handle;
        command('geometry',-1,{action:'create',geometryID:id,configuration:geometryJSON(configuration)});
        return handle;
      };
      thisScene.destroyModelData = function(handle) {
        if (!handle || geometryHandles[handle.__wapleGeometryID] !== handle || handle.__wapleDestroyed) { return; }
        handle.__wapleDestroyed = true;
        command('geometry',-1,{action:'destroy',geometryID:handle.__wapleGeometryID});
        delete geometryHandles[handle.__wapleGeometryID];
      };
      __engineState.registerAsset = function(path) {
        if (typeof path !== 'string' || path.length > 1024 || !path || path[0] === '/' || path.indexOf('..') >= 0 || path.indexOf(':') >= 0) {
          throw new Error('Asset path must remain inside the wallpaper package');
        }
        return Object.freeze({__wapleAsset: path});
      };
      __wapleSetInitialConfigurations = function(values) {
        values.forEach(function(value) { if (slots[value.slot]) { slots[value.slot].__wapleInitialConfig = clone(value.configuration); } });
      };
      var sceneSettings = Object.create(null);
      ['clearenabled','clearcolor','zoom','bloom','bloomstrength','bloomthreshold'].forEach(function(key) {
        Object.defineProperty(thisScene, key, {
          get: function() { return sceneSettings[key]; },
          set: function(value) { sceneSettings[key] = value; command('scene', -1, {property:key,value:value}); }
        });
      });
      var getCameraTransforms = thisScene.getCameraTransforms;
      var setCameraTransforms = thisScene.setCameraTransforms;
      thisScene.setCameraTransforms = function(value) {
        setCameraTransforms.call(thisScene, value);
        command('camera', -1, {transforms:value});
      };
      __wapleConfigureScene = function(values) {
        Object.keys(values).forEach(function(key) {
          if (key === 'camera') {
            var camera = getCameraTransforms.call(thisScene);
            camera.eye = vector(values.camera.eye); camera.center = vector(values.camera.center); camera.up = vector(values.camera.up);
            setCameraTransforms.call(thisScene, camera);
          } else { sceneSettings[key] = key === 'clearcolor' ? vector(values[key]) : values[key]; }
        });
      };
      __engineState.openUserShortcut = function(name) {
        return typeof name === 'string' && typeof __wapleOpenUserShortcut === 'function' ? __wapleOpenUserShortcut(name) : false;
      };
      __engineState.isObjectValid = function (layer) {
        return !!layer && slots.indexOf(layer) >= 0 && !layer.__wapleDestroyed;
      };
      __engineState.screenResolution = new Vec2(__canvasSize.x, __canvasSize.y);
      __wapleSetScreenResolution = function (width, height) {
        __engineState.screenResolution.x = width;
        __engineState.screenResolution.y = height;
      };
      __wapleScriptLayerAt = function (slot) { return slots[slot] || null; };
      __waplePublishRuntimeLayers = function (snapshots) {
        for (var i = 0; i < snapshots.length; ++i) {
          var layer = slots[snapshots[i].slot];
          if (!layer) { continue; }
          var previous = layer.__wapleRuntime || {};
          layer.__wapleRuntime = Object.assign({}, previous, snapshots[i].values);
          Object.keys(layer.__wapleHandles || {}).forEach(function(key) {
            var pair = key.split(':'), operation = pair[0], selector = Number(pair[1]);
            var layerID = pair[1].slice(0, 3) === 'id-' ? Number(pair[1].slice(3)) : undefined;
            var field = operation === 'animation' ? 'animationLayers' : operation === 'video' ? 'videoTexture' : 'textureAnimation';
            var before = field === 'animationLayers' ? (previous[field] || [])[selector] : previous[field];
            var after = field === 'animationLayers' ? (layer.__wapleRuntime[field] || [])[selector] : layer.__wapleRuntime[field];
            if (field === 'animationLayers' && typeof layerID === 'number') {
              before = (previous[field] || []).filter(function(value) { return value.id === layerID; })[0];
              after = (layer.__wapleRuntime[field] || []).filter(function(value) { return value.id === layerID; })[0];
            }
            if (after && before && after.endedGeneration !== before.endedGeneration && after.endedGeneration > 0) {
              layer.__wapleHandles[key].__wapleNotifyEnded();
            }
          });
        }
      };
      __wapleDrainRuntimeCommands = function () {
        var out = JSON.stringify(commands);
        commands = [];
        commandCharacters = 0;
        return out;
      };
      for (var i = 0; i < thisScene.layers.length; ++i) { bind(thisScene.layers[i]); }
      // Descriptor updates retain slots; sorting must never retarget a bound property script.
      var fromDescriptor = __layerFromDescriptor;
      __layerFromDescriptor = function (descriptor) {
        var layer = fromDescriptor(descriptor);
        layer.__wapleInitialConfig = clone(descriptor || {});
        return layer;
      };
    })();
    """#
}
