enum WallpaperBridgeJS {
    static let source = #"""
    (function () {
      var audioCb = null;
      window.wallpaperRegisterAudioListener = function (cb) { audioCb = cb; };
      window.__wapleAudio = function (arr) {
        if (audioCb) { try { audioCb(arr); } catch (e) {} }
      };
      window.wallpaperRequestRandomFileForProperty = function (name, cb) {
        try { window.webkit.messageHandlers.waple.postMessage({ type: 'randomFile', name: name }); } catch (e) {}
      };
      var noop = function () {};
      window.wallpaperRegisterMediaStatusListener = noop;
      window.wallpaperRegisterMediaPropertiesListener = noop;
      window.wallpaperRegisterMediaThumbnailListener = noop;
      window.wallpaperRegisterMediaTimelineListener = noop;
      window.wallpaperRegisterMediaPlaybackListener = noop;
    })();
    """#
}
