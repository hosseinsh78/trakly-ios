/* Trakly bridge shim (docs/specs/phase10-apps-and-stores.md D7, §B2, §E7): hand-written, injected by
   Panel/PanelWebViewFactory.swift at document start in the main frame of every panel WKWebView (the page world).
   It defines the frozen window.TraklyNative of TNB/1 only when the document is on the panel origin: postMessage(string)
   sends through the `trakly` WKScriptMessageHandlerWithReply and dispatches a reply string as a `message` event;
   native sends later messages with callAsyncJavaScript("window.TraklyNative.__receive(m)"). Native replaces the
   ORIGIN literal below with a Debug build's local origin; a Release build ships it unchanged.
   Checked by ios/tools/source.check.mjs and erp/tests/js/native-bridge.check.ts (in a vm). */
(function () {
    'use strict';

    var ORIGIN = 'https://erp.trakly.info';
    var scope = typeof window !== 'undefined' ? window : null;

    if (!scope || !scope.location || scope.location.origin !== ORIGIN || scope.TraklyNative) {
        return;
    }

    var handlers = scope.webkit && scope.webkit.messageHandlers;
    var handler = handlers && handlers.trakly;

    if (!handler || typeof handler.postMessage !== 'function') {
        return;
    }

    // Kept before any page script runs: a later change of webkit.messageHandlers cannot redirect the bridge.
    var post = handler.postMessage.bind(handler);
    var listeners = [];
    var onmessage = null;
    var native = {};

    function eventOf(data) {
        try {
            return new MessageEvent('message', { data: data });
        } catch (error) {
            return { type: 'message', data: data };
        }
    }

    function dispatch(data) {
        if (typeof data !== 'string' || data === '') {
            return;
        }

        var event = eventOf(data);
        var list = listeners.slice();

        for (var index = 0; index < list.length; index++) {
            try {
                list[index].call(native, event);
            } catch (error) {
                if (typeof console !== 'undefined') {
                    console.error(error);
                }
            }
        }

        if (typeof onmessage === 'function') {
            try {
                onmessage.call(native, event);
            } catch (error) {
                if (typeof console !== 'undefined') {
                    console.error(error);
                }
            }
        }
    }

    Object.defineProperty(native, 'postMessage', {
        enumerable: true,
        value: function (message) {
            if (typeof message !== 'string') {
                return Promise.resolve();
            }

            var reply;

            try {
                reply = post(message);
            } catch (error) {
                return Promise.resolve();
            }

            return Promise.resolve(reply).then(dispatch, function () {});
        },
    });

    Object.defineProperty(native, 'addEventListener', {
        enumerable: true,
        value: function (type, listener) {
            if (type === 'message' && typeof listener === 'function' && listeners.indexOf(listener) === -1) {
                listeners.push(listener);
            }
        },
    });

    Object.defineProperty(native, 'removeEventListener', {
        enumerable: true,
        value: function (type, listener) {
            var index = listeners.indexOf(listener);

            if (type === 'message' && index !== -1) {
                listeners.splice(index, 1);
            }
        },
    });

    Object.defineProperty(native, 'onmessage', {
        enumerable: true,
        get: function () {
            return onmessage;
        },
        set: function (value) {
            onmessage = typeof value === 'function' ? value : null;
        },
    });

    // Native → page (§B2): one JSON string, dispatched like a reply.
    Object.defineProperty(native, '__receive', {
        value: function (raw) {
            dispatch(raw);
        },
    });

    Object.freeze(native);
    Object.defineProperty(scope, 'TraklyNative', { value: native, writable: false, configurable: false, enumerable: false });

    // A page restored from WebKit's back-forward cache keeps its old scripts but is a new document for native, which
    // then waits for a `hello` that never comes (no chrome updates, no intake host): such a page loads again.
    if (typeof scope.addEventListener === 'function') {
        scope.addEventListener('pageshow', function (event) {
            if (event && event.persisted) {
                scope.location.reload();
            }
        });
    }
})();
