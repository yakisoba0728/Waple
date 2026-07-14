enum WebHardPauseJS {
    static let source = #"""
    (function () {
      'use strict';
      if (window.__wapleHardPauseController) { return; }

      var nativeRAF = window.requestAnimationFrame.bind(window);
      var nativeCancelRAF = window.cancelAnimationFrame.bind(window);
      var nativeSetTimeout = window.setTimeout.bind(window);
      // Preserve the bound original; virtual intervals deliberately re-arm native timeouts.
      var nativeSetInterval = window.setInterval.bind(window);
      var nativeClearTimeout = window.clearTimeout.bind(window);
      var nativeClearInterval = window.clearInterval.bind(window);
      var monotonicNow = window.performance.now.bind(window.performance);
      var paused = false;
      var nextVirtualID = 1073741824;
      var records = Object.create(null);

      function report(error) {
        try { window.console.error('[Waple hard pause]', error); } catch (_) {}
      }

      function safely(action) {
        try { action(); } catch (error) { report(error); }
      }

      function allocateID() {
        nextVirtualID += 1;
        if (nextVirtualID >= 2147483647) { nextVirtualID = 1073741824; }
        while (records[nextVirtualID]) { nextVirtualID += 1; }
        return nextVirtualID;
      }

      function normalizedDelay(value) {
        var number = Number(value);
        if (!isFinite(number) || number < 0) { return 0; }
        return number;
      }

      function invokeTimer(record) {
        if (typeof record.handler === 'function') {
          record.handler.apply(window, record.arguments);
        } else {
          (0, eval)(String(record.handler));
        }
      }

      function armRAF(record) {
        if (paused || record.nativeHandle !== null) { return; }
        record.nativeHandle = nativeRAF(function (timestamp) {
          var current = records[record.id];
          if (!current) { return; }
          current.nativeHandle = null;
          delete records[current.id];
          current.callback(timestamp);
        });
      }

      function armTimer(record, delay) {
        if (paused || record.nativeHandle !== null) { return; }
        record.remaining = delay;
        record.deadline = monotonicNow() + delay;
        record.nativeHandle = nativeSetTimeout(function () {
          var current = records[record.id];
          if (!current || paused) { return; }
          current.nativeHandle = null;
          if (current.kind === 'timeout') {
            delete records[current.id];
          } else {
            armTimer(current, current.period);
          }
          invokeTimer(current);
        }, delay);
      }

      function clearTimerRecord(id) {
        var record = records[id];
        if (!record || (record.kind !== 'timeout' && record.kind !== 'interval')) {
          nativeClearTimeout(id);
          nativeClearInterval(id);
          return;
        }
        if (record.nativeHandle !== null) {
          nativeClearTimeout(record.nativeHandle);
          nativeClearInterval(record.nativeHandle);
        }
        delete records[id];
      }

      window.requestAnimationFrame = function (callback) {
        if (typeof callback !== 'function') {
          throw new TypeError('requestAnimationFrame callback must be a function');
        }
        var record = {
          id: allocateID(), kind: 'raf', callback: callback, nativeHandle: null
        };
        records[record.id] = record;
        armRAF(record);
        return record.id;
      };

      window.cancelAnimationFrame = function (id) {
        var record = records[id];
        if (!record || record.kind !== 'raf') {
          nativeCancelRAF(id);
          return;
        }
        if (record.nativeHandle !== null) { nativeCancelRAF(record.nativeHandle); }
        delete records[id];
      };

      window.setTimeout = function (handler, delay) {
        var record = {
          id: allocateID(),
          kind: 'timeout',
          handler: handler,
          arguments: Array.prototype.slice.call(arguments, 2),
          nativeHandle: null,
          deadline: 0,
          remaining: normalizedDelay(delay),
          period: 0
        };
        records[record.id] = record;
        armTimer(record, record.remaining);
        return record.id;
      };

      window.setInterval = function (handler, delay) {
        var period = normalizedDelay(delay);
        var record = {
          id: allocateID(),
          kind: 'interval',
          handler: handler,
          arguments: Array.prototype.slice.call(arguments, 2),
          nativeHandle: null,
          deadline: 0,
          remaining: period,
          period: period
        };
        records[record.id] = record;
        armTimer(record, period);
        return record.id;
      };

      window.clearTimeout = clearTimerRecord;
      window.clearInterval = clearTimerRecord;

      function pauseSchedulers() {
        var now = monotonicNow();
        Object.keys(records).forEach(function (id) {
          var record = records[id];
          if (record.nativeHandle === null) { return; }
          if (record.kind === 'raf') {
            nativeCancelRAF(record.nativeHandle);
          } else {
            record.remaining = Math.max(0, record.deadline - now);
            nativeClearTimeout(record.nativeHandle);
          }
          record.nativeHandle = null;
        });
      }

      function resumeSchedulers() {
        Object.keys(records).forEach(function (id) {
          var record = records[id];
          if (record.nativeHandle !== null) { return; }
          if (record.kind === 'raf') {
            armRAF(record);
          } else {
            armTimer(record, record.remaining);
          }
        });
      }

      var audioEntries = [];

      function removeAudioEntry(entry) {
        var index = audioEntries.indexOf(entry);
        if (index >= 0) { audioEntries.splice(index, 1); }
      }

      function enqueueAudio(entry, transition, onCompletion) {
        entry.chain = entry.chain.catch(function (error) {
          report(error);
        }).then(function () {
          if (entry.context.state === 'closed') {
            removeAudioEntry(entry);
            return;
          }
          return Promise.resolve().then(transition).then(function () {
            if (entry.context.state === 'closed') {
              removeAudioEntry(entry);
              return;
            }
            if (onCompletion) { onCompletion(); }
          });
        }).catch(function (error) {
          report(error);
        });
        return entry.chain;
      }

      function requestAudioState(entry, desiredState, ownedResume) {
        entry.controllerDesiredState = desiredState;
        var generation = ++entry.controllerGeneration;
        return enqueueAudio(entry, function () {
          if (generation !== entry.controllerGeneration) { return; }
          if (entry.context.state === desiredState) { return; }
          return desiredState === 'running'
            ? entry.nativeResume()
            : entry.nativeSuspend();
        }, function () {
          if (generation === entry.controllerGeneration &&
              ownedResume && !paused && entry.context.state === 'running') {
            entry.resumeAfterPause = false;
          }
        });
      }

      function trackAudioContext(context) {
        var entry = {
          context: context,
          nativeResume: context.resume.bind(context),
          nativeSuspend: context.suspend.bind(context),
          pageDesiredState: context.state,
          controllerDesiredState: context.state,
          controllerGeneration: 0,
          chain: Promise.resolve(),
          resumeAfterPause: false
        };
        audioEntries.push(entry);

        try {
          Object.defineProperty(context, 'resume', {
            configurable: true,
            value: function () {
              entry.pageDesiredState = 'running';
              return enqueueAudio(entry, function () {
                return Promise.resolve(entry.nativeResume()).then(function () {
                  if (paused) { return entry.nativeSuspend(); }
                });
              });
            }
          });
          Object.defineProperty(context, 'suspend', {
            configurable: true,
            value: function () {
              entry.pageDesiredState = 'suspended';
              entry.resumeAfterPause = false;
              return enqueueAudio(entry, entry.nativeSuspend);
            }
          });
        } catch (error) {
          report(error);
        }

        if (paused) { requestAudioState(entry, 'suspended', false); }
        return context;
      }

      var audioConstructorWrappers = [];

      function wrapperForAudioConstructor(Original, name) {
        for (var index = 0; index < audioConstructorWrappers.length; index += 1) {
          if (audioConstructorWrappers[index].original === Original) {
            return audioConstructorWrappers[index].wrapper;
          }
        }
        function WrappedAudioContext() {
          if (!new.target) { throw new TypeError(name + ' requires new'); }
          var args = Array.prototype.slice.call(arguments);
          var target = new.target === WrappedAudioContext ? Original : new.target;
          return trackAudioContext(Reflect.construct(Original, args, target));
        }
        Object.setPrototypeOf(WrappedAudioContext, Original);
        WrappedAudioContext.prototype = Original.prototype;
        audioConstructorWrappers.push({ original: Original, wrapper: WrappedAudioContext });
        return WrappedAudioContext;
      }

      function wrapAudioConstructor(name) {
        var Original = window[name];
        if (typeof Original !== 'function') { return; }
        var WrappedAudioContext = wrapperForAudioConstructor(Original, name);
        try {
          Object.defineProperty(window, name, {
            value: WrappedAudioContext, writable: true, configurable: true
          });
        } catch (error) {
          window[name] = WrappedAudioContext;
        }
      }

      function pauseAudioContexts() {
        audioEntries.slice().forEach(function (entry) {
          if (entry.context.state === 'closed') {
            removeAudioEntry(entry);
            return;
          }
          if (entry.context.state === 'running') {
            if (entry.pageDesiredState === 'running') {
              entry.resumeAfterPause = true;
            }
            requestAudioState(entry, 'suspended', false);
          } else if (entry.controllerDesiredState === 'running') {
            requestAudioState(entry, 'suspended', false);
          }
        });
      }

      function resumeAudioContexts() {
        audioEntries.slice().forEach(function (entry) {
          if (entry.context.state === 'closed') {
            removeAudioEntry(entry);
          } else if (entry.resumeAfterPause && entry.pageDesiredState === 'running') {
            requestAudioState(entry, 'running', true);
          }
        });
      }

      safely(function () { wrapAudioConstructor('AudioContext'); });
      safely(function () { wrapAudioConstructor('webkitAudioContext'); });

      var pauseClass = '__waple-hard-paused';
      var animationStyleID = '__waple-hard-pause-style';
      var knownAnimations = [];
      var animationsToResume = [];
      var animationObserver = null;
      var nativeElementAnimate = null;
      var nativeAnimationPlay = null;
      var resumingOwnedAnimation = false;

      function allAnimations() {
        if (typeof document.getAnimations !== 'function') { return []; }
        return document.getAnimations();
      }

      function rememberAnimation(animation) {
        if (animationsToResume.indexOf(animation) < 0) {
          animationsToResume.push(animation);
        }
        try { animation.pause(); } catch (error) { report(error); }
      }

      function rememberAnimationStartedWhilePaused(animation) {
        if (!paused || !animation) { return; }
        if (knownAnimations.indexOf(animation) < 0) {
          knownAnimations.push(animation);
        }
        rememberAnimation(animation);
      }

      function installAnimationAPIObservation() {
        if (window.Element && window.Element.prototype) {
          var animateDescriptor = Object.getOwnPropertyDescriptor(
            window.Element.prototype, 'animate');
          if (animateDescriptor && typeof animateDescriptor.value === 'function') {
            nativeElementAnimate = animateDescriptor.value;
            animateDescriptor.value = function () {
              var animation = nativeElementAnimate.apply(this, arguments);
              rememberAnimationStartedWhilePaused(animation);
              return animation;
            };
            Object.defineProperty(window.Element.prototype, 'animate', animateDescriptor);
          }
        }
        if (window.Animation && window.Animation.prototype) {
          var playDescriptor = Object.getOwnPropertyDescriptor(
            window.Animation.prototype, 'play');
          if (playDescriptor && typeof playDescriptor.value === 'function') {
            nativeAnimationPlay = playDescriptor.value;
            playDescriptor.value = function () {
              var result = nativeAnimationPlay.apply(this, arguments);
              if (!resumingOwnedAnimation) {
                rememberAnimationStartedWhilePaused(this);
              }
              return result;
            };
            Object.defineProperty(window.Animation.prototype, 'play', playDescriptor);
          }
        }
      }

      function ensureAnimationStyle() {
        if (document.getElementById(animationStyleID)) { return; }
        var parent = document.head || document.documentElement;
        if (!parent) { return; }
        var style = document.createElement('style');
        style.id = animationStyleID;
        style.textContent =
          'html.' + pauseClass + ', html.' + pauseClass + ' *, ' +
          'html.' + pauseClass + '::before, html.' + pauseClass + '::after, ' +
          'html.' + pauseClass + ' *::before, html.' + pauseClass + ' *::after {' +
          'animation-play-state: paused !important;}';
        parent.appendChild(style);
      }

      function pauseAnimations() {
        ensureAnimationStyle();
        knownAnimations = allAnimations();
        knownAnimations.forEach(function (animation) {
          if (animation.playState === 'running' || animation.playState === 'pending') {
            rememberAnimation(animation);
          }
        });
        if (document.documentElement) {
          document.documentElement.classList.add(pauseClass);
        }
      }

      function captureAnimationsCreatedWhilePaused() {
        if (!paused) { return; }
        allAnimations().forEach(function (animation) {
          if (knownAnimations.indexOf(animation) >= 0) { return; }
          knownAnimations.push(animation);
          if (animation.playState !== 'idle' && animation.playState !== 'finished') {
            rememberAnimation(animation);
          }
        });
      }

      function queueAnimationCapture() {
        Promise.resolve().then(captureAnimationsCreatedWhilePaused);
      }

      function installAnimationObservation() {
        if (animationObserver || !document.documentElement || !window.MutationObserver) { return; }
        animationObserver = new MutationObserver(queueAnimationCapture);
        animationObserver.observe(document.documentElement, {
          childList: true, subtree: true, attributes: true
        });
      }

      function resumeAnimations() {
        if (document.documentElement) {
          document.documentElement.classList.remove(pauseClass);
        }
        var recorded = animationsToResume.slice();
        animationsToResume = [];
        knownAnimations = [];
        recorded.forEach(function (animation) {
          if (animation.playState !== 'idle' && animation.playState !== 'finished') {
            try {
              resumingOwnedAnimation = true;
              animation.play();
            } catch (error) {
              report(error);
            } finally {
              resumingOwnedAnimation = false;
            }
          }
        });
      }

      safely(installAnimationAPIObservation);
      document.addEventListener('animationstart', queueAnimationCapture, true);
      document.addEventListener('transitionrun', queueAnimationCapture, true);
      document.addEventListener('transitionstart', queueAnimationCapture, true);
      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', function () {
          installAnimationObservation();
          if (paused) { pauseAnimations(); }
        });
      } else {
        installAnimationObservation();
      }

      var controller = {
        version: 1,
        isPaused: function () { return paused; },
        setPaused: function (next) {
          next = !!next;
          if (next === paused) { return; }
          paused = next;
          if (paused) {
            safely(pauseSchedulers);
            safely(pauseAudioContexts);
            safely(pauseAnimations);
            safely(postStateToChildren);
          } else {
            safely(resumeAnimations);
            safely(resumeAudioContexts);
            safely(resumeSchedulers);
            safely(postStateToChildren);
          }
        }
      };

      try {
        Object.defineProperty(window, '__wapleHardPauseController', {
          value: controller, writable: false, configurable: false
        });
      } catch (error) {
        window.__wapleHardPauseController = controller;
      }

      var frameChannel = 'waple-hard-pause';
      var frameVersion = 1;

      function frameMessage(type) {
        return {
          channel: frameChannel,
          version: frameVersion,
          type: type,
          paused: paused
        };
      }

      function isDirectChild(source) {
        for (var index = 0; index < window.frames.length; index += 1) {
          try {
            if (window.frames[index] === source) { return true; }
          } catch (_) {}
        }
        return false;
      }

      function postStateToChildren() {
        for (var index = 0; index < window.frames.length; index += 1) {
          try {
            window.frames[index].postMessage(frameMessage('state'), '*');
          } catch (error) {
            report(error);
          }
        }
      }

      window.addEventListener('message', function (event) {
        var message = event.data;
        if (!message ||
            message.channel !== frameChannel ||
            message.version !== frameVersion) {
          return;
        }
        if (message.type === 'requestState' && isDirectChild(event.source)) {
          try {
            event.source.postMessage(frameMessage('state'), '*');
          } catch (error) {
            report(error);
          }
          return;
        }
        if (message.type === 'state' &&
            window.parent !== window &&
            event.source === window.parent) {
          controller.setPaused(!!message.paused);
        }
      }, false);

      if (window.parent !== window) {
        try {
          window.parent.postMessage({
            channel: frameChannel,
            version: frameVersion,
            type: 'requestState'
          }, '*');
        } catch (error) {
          report(error);
        }
      }

      window.addEventListener('load', postStateToChildren, true);
    })();
    """#
}
