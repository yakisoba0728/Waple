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

      var controller = {
        version: 1,
        isPaused: function () { return paused; },
        setPaused: function (next) {
          next = !!next;
          if (next === paused) { return; }
          paused = next;
          if (paused) {
            safely(pauseSchedulers);
          } else {
            safely(resumeSchedulers);
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
    })();
    """#
}
