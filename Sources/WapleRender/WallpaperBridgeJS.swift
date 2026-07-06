enum WallpaperBridgeJS {
    static let source = #"""
    (function () {
      var ASSET_PROTOCOL = 'waple-asset:';
      var ASSET_HOST = 'wallpaper';
      function isAllowedWindow(w) {
        try { return w.location.protocol === ASSET_PROTOCOL && w.location.host === ASSET_HOST; } catch (e) { return false; }
      }
      var allowedFrame = isAllowedWindow(window);
      if (!allowedFrame) {
        try { allowedFrame = window.parent && window.parent !== window && isAllowedWindow(window.parent); } catch (e) {}
      }
      if (!allowedFrame) { return; }
      function defineFixed(name, value) {
        try {
          Object.defineProperty(window, name, { value: value, writable: false, configurable: false });
        } catch (e) {
          try { window[name] = value; } catch (_) {}
        }
      }
      function defineBridge(name, value) {
        try {
          Object.defineProperty(window, name, { value: value, writable: true, configurable: true });
        } catch (e) {
          try { window[name] = value; } catch (_) {}
        }
      }
      function post(message) {
        try { window.webkit.messageHandlers.waple.postMessage(message); } catch (e) {}
      }
      function forEachChild(fn) {
        for (var i = 0; i < window.frames.length; i++) {
          try {
            var child = window.frames[i];
            if (child && child !== window) { fn(child); }
          } catch (e) {}
        }
      }
      var audioCb = null;
      defineFixed('wallpaperRegisterAudioListener', function (cb) {
        audioCb = (typeof cb === 'function') ? cb : null;
      });
      defineFixed('__wapleAudio', function (arr) {
        if (audioCb) { try { audioCb(arr); } catch (e) {} }
      });
      // WE 의미론: wallpaperPropertyListener 는 "등록 즉시" 속성을 받는다 — 문서 로드 후(async)
      // 등록해도 유실되지 않도록 세터 훅 + pending/flush. (__waplePropsDelivered 는 GT 검증용.)
      var listener; var pendingProps = null; var pendingGeneral = null; var lastProps = null; var lastGeneral = null;
      window.__waplePropsDelivered = false;
      function flush() {
        if (!listener) { return; }
        if (pendingProps && listener.applyUserProperties) {
          try { listener.applyUserProperties(pendingProps); window.__waplePropsDelivered = true; } catch (e) {}
          pendingProps = null;
        }
        if (pendingGeneral && listener.applyGeneralProperties) {
          try { listener.applyGeneralProperties(pendingGeneral); } catch (e) {}
          pendingGeneral = null;
        }
      }
      function propagateProps(props, general) {
        forEachChild(function (child) {
          try {
            if (typeof child.__wapleApplyProps === 'function') {
              child.__wapleApplyProps(props, general);
            }
          } catch (e) {}
        });
      }
      function propagateLastProps() {
        if (lastProps || lastGeneral) { propagateProps(lastProps, lastGeneral); }
      }
      function schedulePropagateLastProps() {
        setTimeout(propagateLastProps, 0);
        setTimeout(propagateLastProps, 50);
        setTimeout(propagateLastProps, 250);
      }
      function installFrameObserver() {
        if (!window.MutationObserver) { return; }
        var root = document.documentElement || document.body;
        if (!root) { return; }
        try {
          new MutationObserver(schedulePropagateLastProps).observe(root, { childList: true, subtree: true });
        } catch (e) {}
      }
      Object.defineProperty(window, 'wallpaperPropertyListener', {
        get: function () { return listener; },
        set: function (v) { listener = v; flush(); },
        configurable: true
      });
      defineBridge('__wapleApplyProps', function (props, general) {
        lastProps = props; lastGeneral = general;
        pendingProps = props; pendingGeneral = general; flush();
        propagateProps(props, general);
      });
      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', installFrameObserver);
      } else {
        installFrameObserver();
      }
      window.addEventListener('load', schedulePropagateLastProps, true);
      // 마우스 전달(WE 동작): 네이티브가 좌표를 밀어주면 DOM mousemove 로 재게시.
      // 조작 창 입력 프록시: 실이벤트를 받는 별도 창이 좌표·키를 넘겨주면 합성 DOM 이벤트로 재게시.
      // (데스크탑 창 자체는 아이콘 보호를 위해 실이벤트를 받지 않는다.)
      defineBridge('__wapleEvent', function (kind, x, y, a, b) {
        try {
          var t = document.elementFromPoint(x, y) || document;
          var o = { clientX: x, clientY: y, screenX: x, screenY: y,
                    bubbles: true, cancelable: true, view: window, button: 0, buttons: (kind === 'mousemove' && a === 1) ? 1 : (kind === 'mousedown' ? 1 : 0) };
          if (kind === 'wheel') {
            t.dispatchEvent(new WheelEvent('wheel', { clientX: x, clientY: y, deltaX: a || 0, deltaY: b || 0, bubbles: true, cancelable: true, view: window }));
          } else if (kind === 'keydown' || kind === 'keyup') {
            var ko = { key: a, code: b || a, bubbles: true, cancelable: true, view: window };
            (document.activeElement || document).dispatchEvent(new KeyboardEvent(kind, ko));
            document.dispatchEvent(new KeyboardEvent(kind, ko));
          } else {
            t.dispatchEvent(new MouseEvent(kind, o));
            if (kind === 'mouseup') { t.dispatchEvent(new MouseEvent('click', o)); }
          }
        } catch (e) {}
      });
      defineBridge('__wapleClick', function (x, y) {  // 하위 호환
        window.__wapleEvent('mousedown', x, y); window.__wapleEvent('mouseup', x, y);
      });
      defineBridge('__wapleMouse', function (x, y) {
        try {
          document.dispatchEvent(new MouseEvent('mousemove', { clientX: x, clientY: y, bubbles: true }));
        } catch (e) {}
      });
      var randomSeq = 0;
      var randomPrefix = String(Date.now()) + '-' + Math.random().toString(36).slice(2);
      var randomCallbacks = {};
      defineBridge('wallpaperRequestRandomFileForProperty', function (name, cb) {
        if (typeof cb !== 'function') { return; }
        var requestId = randomPrefix + '-' + (++randomSeq);
        randomCallbacks[requestId] = cb;
        post({ type: 'randomFile', name: String(name), requestId: requestId });
      });
      defineBridge('__wapleRandomFileResponse', function (requestId, name, filePath) {
        var cb = randomCallbacks[requestId];
        if (cb) {
          delete randomCallbacks[requestId];
          try { cb(name, filePath); } catch (e) {}
          return true;
        }
        var delivered = false;
        forEachChild(function (child) {
          try {
            if (typeof child.__wapleRandomFileResponse === 'function' &&
                child.__wapleRandomFileResponse(requestId, name, filePath)) {
              delivered = true;
            }
          } catch (e) {}
        });
        return delivered;
      });
      // 미디어 연동: 리스너 등록 시 네이티브에 알리고(폴링 시작), __wapleMedia 로 배달받는다.
      window.wallpaperMediaIntegration = { PLAYBACK_STOPPED: 0, PLAYBACK_PLAYING: 1, PLAYBACK_PAUSED: 2 };
      var mediaCbs = { status: null, properties: null, timeline: null, thumbnail: null, playback: null };
      function regMedia(kind) {
        return function (cb) {
          mediaCbs[kind] = cb;
          post({ type: 'mediaListen' });
        };
      }
      defineBridge('wallpaperRegisterMediaStatusListener', regMedia('status'));
      defineBridge('wallpaperRegisterMediaPropertiesListener', regMedia('properties'));
      defineBridge('wallpaperRegisterMediaThumbnailListener', regMedia('thumbnail'));
      defineBridge('wallpaperRegisterMediaTimelineListener', regMedia('timeline'));
      defineBridge('wallpaperRegisterMediaPlaybackListener', regMedia('playback'));
      defineBridge('__wapleMedia', function (kind, obj) {
        var cb = mediaCbs[kind];
        if (cb) { try { cb(obj); } catch (e) {} }
      });
    })();
    """#
}
