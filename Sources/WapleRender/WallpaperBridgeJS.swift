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
      function installServiceWorkerShim() {
        function registration() {
          return {
            installing: null, waiting: null, active: null, scope: String(window.location.href),
            unregister: function () { return Promise.resolve(true); },
            update: function () { return Promise.resolve(); }
          };
        }
        var serviceWorkerShim = {
          controller: null,
          ready: Promise.resolve(registration()),
          register: function () { return Promise.resolve(registration()); },
          getRegistration: function () { return Promise.resolve(registration()); },
          getRegistrations: function () { return Promise.resolve([registration()]); },
          addEventListener: function () {},
          removeEventListener: function () {},
          dispatchEvent: function () { return true; }
        };
        try {
          Object.defineProperty(window.navigator, 'serviceWorker', {
            value: serviceWorkerShim, writable: false, configurable: true
          });
        } catch (e) {
          try { window.navigator.serviceWorker = serviceWorkerShim; } catch (_) {}
        }
      }
      installServiceWorkerShim();
      // WE 가 CEF `OnContextCreated`(webwallpaper64.exe 0x140013280–0x1400143f7)에서
      // **document-start 에 무조건** 전역으로 심는 것들. 없으면 페이지가 그냥 죽는다
      // (`ReferenceError` 는 스크립트 하나를 통째로 중단시킨다) — 그래서 도달 수와 무관하게
      // 존재 자체가 규약이다. 등록 순서·이름은 원본 그대로.
      //
      //  · wallpaperGetUtilities (0x140013d73) — 0x140015376 이 만드는 반환 객체는
      //    `isScreensaver`(0x1400154c5)·`isWallpaper`(0x140015604) **두 함수**뿐이다
      //    (`CreateFunction` → `SetValue`; 값이 아니라 함수다).
      //    Waple 은 스크린세이버 모드가 없으므로 isScreensaver 는 항상 false 다.
      //  · wallpaperOnVideoEnded (0x140014097) — WE 가 동영상 벽지용으로 생성하는 래퍼
      //    HTML 이 `v.onended` 에서 부른다(주입 원문 @0x1198f0). 페이지가 직접 부르는 일도
      //    있어 전역이 존재해야 한다. Waple 의 동영상 폴백은 `VideoFallbackHTML` 이 같은
      //    래퍼를 생성한다.
      //  · wallpaperRequestTakeScreenshotResponse (0x140014226) — **페이지 → 네이티브** 방향의
      //    응답 창구다. 네이티브가 먼저 `window.__wpxTakeSnapshot()`(0x140011d99)을 실행해야
      //    발생하는데, 그 캡처는 `navigator.mediaDevices.getDisplayMedia({displaySurface:
      //    "browser"})` 로 구현돼 있다(주입 원문 @0x11a1c0 이후). WKWebView 는 화면 캡처
      //    getDisplayMedia 를 제공하지 않으므로(카메라/마이크만) 이 경로는 재현 불가 —
      //    자세한 이유는 docs/re/web-wallpaper-bridge.md. 전역은 인자를 받고 버리는 스텁으로
      //    둔다(호출이 예외로 번지지 않게).
      defineFixed('wallpaperGetUtilities', function () {
        return {
          isScreensaver: function () { return false; },
          isWallpaper: function () { return true; }
        };
      });
      defineBridge('wallpaperOnVideoEnded', function () {});
      defineBridge('wallpaperRequestTakeScreenshotResponse', function () {});
      // WE 의 `___STAHP` 스크립트(주입 원문 @0x119ca0, 5936바이트)가 여는 공용 훅.
      // WE 자신이 플러그인 로드 통지를 이 위에 얹고(0x14001f569 가 만드는
      // `window.___wpxShared.onLoad(function(){...onPluginLoaded(...)})`), 벽지도 쓸 수 있다.
      // 원본과 같은 의미론: load 이후 등록하면 즉시 호출, 이전이면 큐잉.
      if (!window.___wpxShared) {
        var wpxShared = {
          hasLoaded: false,
          onLoadListeners: [],
          onLoad: function (fn) {
            if (typeof fn !== 'function') { return; }
            if (window.___wpxShared.hasLoaded) { fn(); }
            else { window.___wpxShared.onLoadListeners.push(fn); }
          }
        };
        defineBridge('___wpxShared', wpxShared);
        window.addEventListener('load', function () {
          wpxShared.hasLoaded = true;
          wpxShared.onLoadListeners.forEach(function (l) {
            try { l(); } catch (e) {}
          });
          wpxShared.onLoadListeners = [];
        });
      }
      // F682: WE 의미론의 Page Visibility 스푸핑. 데스크탑/헤드리스 WKWebView 의 네이티브
      // document.hidden/visibilityState 는 월페이퍼 가시성과 무관하다(헤드리스 호스트는 항상 hidden —
      // 가시성 게이트로 애니메이션을 미루는 페이지가 영구 정지한다). WE 는 월페이퍼가 가려질 때
      // (=Waple pause) hidden=true + visibilitychange 를 발화하므로 pause 상태를 hidden 으로 매핑한다
      // (__wapleSetPaused 가 갱신). atDocumentStart 주입이라 페이지 스크립트는 항상 스푸핑 값만 본다.
      var spoofedHidden = false;
      function spoofVisibilityGetter(name) {
        return function () {
          if (name === 'hidden' || name === 'webkitHidden') { return spoofedHidden; }
          return spoofedHidden ? 'hidden' : 'visible';
        };
      }
      ['hidden', 'webkitHidden', 'visibilityState', 'webkitVisibilityState'].forEach(function (name) {
        var installed = false;
        try {
          Object.defineProperty(document, name, { get: spoofVisibilityGetter(name), configurable: true });
          installed = true;
        } catch (e) {}
        if (!installed) {
          try {
            if (window.Document && window.Document.prototype) {
              Object.defineProperty(window.Document.prototype, name,
                { get: spoofVisibilityGetter(name), configurable: true });
            }
          } catch (e) {}
        }
      });
      function fireVisibilityChange() {
        try { document.dispatchEvent(new Event('visibilitychange')); } catch (e) {}
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
        post({ type: audioCb ? 'audioListen' : 'audioUnlisten' });
      });
      defineFixed('__wapleAudio', function (arr) {
        if (audioCb) { try { audioCb(arr); } catch (e) {} }
        // 네이티브는 메인 프레임에서만 evaluateJS — 동일출처 자식 프레임 리스너에도 전파(props 와 동일 패턴).
        forEachChild(function (child) {
          try {
            if (typeof child.__wapleAudio === 'function') { child.__wapleAudio(arr); }
          } catch (e) {}
        });
      });
      defineBridge('wallpaperReady', function () {});
      // WE 의미론: wallpaperPropertyListener 는 "등록 즉시" 속성을 받는다 — 문서 로드 후(async)
      // 등록해도 유실되지 않도록 세터 훅 + pending/flush. (__waplePropsDelivered 는 GT 검증용.)
      var listener; var pendingProps = null; var pendingGeneral = null; var lastProps = null; var lastGeneral = null;
      var lastPaused = null;
      var pendingDirectoryAdds = [];
      var pendingDirectoryRemoves = [];
      window.__waplePropsDelivered = false;
      // WE 는 `applyGeneralProperties` 에 **항상 `language` 를 담는다**(0x140020547–0x1400206e4 가
      // `{language: <코드>}` 를 만들고 0x140020764 가 그것을 넘긴다). 값의 형태는 설치본
      // `locale/ui_<코드>.json` 75개가 그대로 보여 준다 — `en-us`·`ko-kr` 같은 **소문자 BCP-47**.
      // 네이티브(WebRenderer)가 아직 fps 만 보내므로, 키가 비어 있을 때만 브라우저 로케일에서
      // 채운다. **근사임을 명시한다**: WE 값은 WE UI 언어 설정이고 여기서는 시스템 로케일이다.
      // 네이티브가 언젠가 실제 값을 넣으면 그쪽이 이긴다(덮어쓰지 않는다).
      function withDefaultLanguage(general) {
        if (!general || typeof general !== 'object') { return general; }
        if (general.language) { return general; }
        try {
          var tag = (window.navigator && (navigator.language || navigator.userLanguage)) || '';
          if (tag) { general.language = String(tag).toLowerCase(); }
        } catch (e) {}
        return general;
      }
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
        flushDirectoryAdds();
        flushDirectoryRemoves();
      }
      function flushDirectoryAdds() {
        if (!listener || !listener.userDirectoryFilesAddedOrChanged) { return; }
        var pending = pendingDirectoryAdds;
        pendingDirectoryAdds = [];
        for (var i = 0; i < pending.length; i++) {
          try { listener.userDirectoryFilesAddedOrChanged(pending[i].name, pending[i].files); } catch (e) {}
        }
      }
      // WE 는 추가/변경과 **삭제를 별도 콜백으로** 통지한다(브라우저 프로세스가 만드는 JS 원문:
      // 0x140009c9a–0x14000a0c4 가 `userDirectoryFilesAddedOrChanged`, 0x14000a0f7–0x14000a50a 가
      // `userDirectoryFilesRemoved` 를 같은 `if(listener&&listener.<cb>){...(name,[files]);}`
      // 형태로 생성한다). 브리지 쪽 대칭을 여기서 채운다 — 네이티브 트리거(디렉터리 감시의
      // 삭제 이벤트)는 `WebRenderer` 소관이라 아직 없다(docs/re/web-wallpaper-bridge.md 참조).
      function flushDirectoryRemoves() {
        if (!listener || !listener.userDirectoryFilesRemoved) { return; }
        var pending = pendingDirectoryRemoves;
        pendingDirectoryRemoves = [];
        for (var i = 0; i < pending.length; i++) {
          try { listener.userDirectoryFilesRemoved(pending[i].name, pending[i].files); } catch (e) {}
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
      function propagatePaused(paused) {
        forEachChild(function (child) {
          try {
            if (typeof child.__wapleSetPaused === 'function') {
              child.__wapleSetPaused(paused);
            }
          } catch (e) {}
        });
      }
      function setHardPaused(paused) {
        try {
          if (window.__wapleHardPauseController &&
              typeof window.__wapleHardPauseController.setPaused === 'function') {
            window.__wapleHardPauseController.setPaused(paused);
          }
        } catch (error) {
          try { window.console.error('[Waple hard pause bridge]', error); } catch (_) {}
        }
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
        general = withDefaultLanguage(general);
        lastProps = props; lastGeneral = general;
        pendingProps = props; pendingGeneral = general; flush();
        propagateProps(props, general);
      });
      // F840: defineFixed(비쓰기·비설정) — defineBridge 였을 때는 월페이퍼 페이지가
      // `window.__wapleSetPaused = function(){}` 한 줄로 덮어써서 가림 정지를 통째로 무력화할 수 있었다
      // (WebRenderer.setPausedJS 는 이 함수가 있으면 그것만 부르고 하드포즈 폴백으로 내려가지 않는다).
      // 페이지가 정지를 거부할 수 있으면 절전·가림 정책이 성립하지 않는다.
      defineFixed('__wapleSetPaused', function (paused) {
        paused = !!paused;
        if (lastPaused === paused) { return; }
        lastPaused = paused;
        // F682: WE 처럼 가시성 전이를 페이지에 알린다(가림/수동정지=hidden, 복귀=visible).
        if (spoofedHidden !== paused) { spoofedHidden = paused; fireVisibilityChange(); }
        setHardPaused(paused);
        if (listener && listener.setPaused) {
          try { listener.setPaused(paused); } catch (e) {}
        }
        var lifecycle = paused ? window.wallpaperWillGoBackground : window.wallpaperWillGoForeground;
        if (typeof lifecycle === 'function') {
          try { lifecycle(); } catch (e) {}
        }
        propagatePaused(paused);
      });
      defineBridge('__wapleDirectoryFilesAddedOrChanged', function (name, files) {
        var event = { name: String(name), files: Array.isArray(files) ? files : [] };
        pendingDirectoryAdds.push(event);
        flushDirectoryAdds();
        forEachChild(function (child) {
          try {
            if (typeof child.__wapleDirectoryFilesAddedOrChanged === 'function') {
              child.__wapleDirectoryFilesAddedOrChanged(event.name, event.files);
            }
          } catch (e) {}
        });
      });
      defineBridge('__wapleDirectoryFilesRemoved', function (name, files) {
        var event = { name: String(name), files: Array.isArray(files) ? files : [] };
        pendingDirectoryRemoves.push(event);
        flushDirectoryRemoves();
        forEachChild(function (child) {
          try {
            if (typeof child.__wapleDirectoryFilesRemoved === 'function') {
              child.__wapleDirectoryFilesRemoved(event.name, event.files);
            }
          } catch (e) {}
        });
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
            // activeElement 발 이벤트는 bubbles:true 로 document 까지 버블 — document 재발화를 겹치면
            // 리스너가 2회 수신한다(감사 W-B2). 1회만 발화.
            (document.activeElement || document).dispatchEvent(new KeyboardEvent(kind, ko));
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
      var lastMedia = {};
      function regMedia(kind) {
        return function (cb) {
          mediaCbs[kind] = cb;
          post({ type: 'mediaListen' });
          if (typeof cb === 'function' && Object.prototype.hasOwnProperty.call(lastMedia, kind)) {
            setTimeout(function () {
              try { cb(lastMedia[kind]); } catch (e) {}
            }, 0);
          }
        };
      }
      defineBridge('wallpaperRegisterMediaStatusListener', regMedia('status'));
      defineBridge('wallpaperRegisterMediaPropertiesListener', regMedia('properties'));
      defineBridge('wallpaperRegisterMediaThumbnailListener', regMedia('thumbnail'));
      defineBridge('wallpaperRegisterMediaTimelineListener', regMedia('timeline'));
      defineBridge('wallpaperRegisterMediaPlaybackListener', regMedia('playback'));
      defineBridge('__wapleMedia', function (kind, obj) {
        lastMedia[kind] = obj;
        var cb = mediaCbs[kind];
        if (cb) { try { cb(obj); } catch (e) {} }
        // 자식 프레임 전파(__wapleAudio 와 동일 — 자식의 lastMedia/재생 콜백도 채운다).
        forEachChild(function (child) {
          try {
            if (typeof child.__wapleMedia === 'function') { child.__wapleMedia(kind, obj); }
          } catch (e) {}
        });
      });
    })();
    """#
}
