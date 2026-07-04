enum WallpaperBridgeJS {
    static let source = #"""
    (function () {
      var audioCb = null;
      window.wallpaperRegisterAudioListener = function (cb) { audioCb = cb; };
      window.__wapleAudio = function (arr) {
        if (audioCb) { try { audioCb(arr); } catch (e) {} }
      };
      // WE 의미론: wallpaperPropertyListener 는 "등록 즉시" 속성을 받는다 — 문서 로드 후(async)
      // 등록해도 유실되지 않도록 세터 훅 + pending/flush. (__waplePropsDelivered 는 GT 검증용.)
      var listener; var pendingProps = null; var pendingGeneral = null;
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
      Object.defineProperty(window, 'wallpaperPropertyListener', {
        get: function () { return listener; },
        set: function (v) { listener = v; flush(); },
        configurable: true
      });
      window.__wapleApplyProps = function (props, general) {
        pendingProps = props; pendingGeneral = general; flush();
      };
      // 마우스 전달(WE 동작): 네이티브가 좌표를 밀어주면 DOM mousemove 로 재게시.
      // 조작 창 입력 프록시: 실이벤트를 받는 별도 창이 좌표·키를 넘겨주면 합성 DOM 이벤트로 재게시.
      // (데스크탑 창 자체는 아이콘 보호를 위해 실이벤트를 받지 않는다.)
      window.__wapleEvent = function (kind, x, y, a, b) {
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
      };
      window.__wapleClick = function (x, y) {  // 하위 호환
        window.__wapleEvent('mousedown', x, y); window.__wapleEvent('mouseup', x, y);
      };
      window.__wapleMouse = function (x, y) {
        try {
          document.dispatchEvent(new MouseEvent('mousemove', { clientX: x, clientY: y, bubbles: true }));
        } catch (e) {}
      };
      window.wallpaperRequestRandomFileForProperty = function (name, cb) {
        try { window.webkit.messageHandlers.waple.postMessage({ type: 'randomFile', name: name }); } catch (e) {}
      };
      // 미디어 연동: 리스너 등록 시 네이티브에 알리고(폴링 시작), __wapleMedia 로 배달받는다.
      window.wallpaperMediaIntegration = { PLAYBACK_STOPPED: 0, PLAYBACK_PLAYING: 1, PLAYBACK_PAUSED: 2 };
      var mediaCbs = { status: null, properties: null, timeline: null, thumbnail: null, playback: null };
      function regMedia(kind) {
        return function (cb) {
          mediaCbs[kind] = cb;
          try { window.webkit.messageHandlers.waple.postMessage({ type: 'mediaListen' }); } catch (e) {}
        };
      }
      window.wallpaperRegisterMediaStatusListener = regMedia('status');
      window.wallpaperRegisterMediaPropertiesListener = regMedia('properties');
      window.wallpaperRegisterMediaThumbnailListener = regMedia('thumbnail');
      window.wallpaperRegisterMediaTimelineListener = regMedia('timeline');
      window.wallpaperRegisterMediaPlaybackListener = regMedia('playback');
      window.__wapleMedia = function (kind, obj) {
        var cb = mediaCbs[kind];
        if (cb) { try { cb(obj); } catch (e) {} }
      };
    })();
    """#
}
