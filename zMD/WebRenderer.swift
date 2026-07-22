import AppKit
import WebKit
import CryptoKit

/// No-op stub — replaces the debug-trace logging used to diagnose the headless-WebView
/// requestAnimationFrame issue. Kept (vs deleted) so the call sites remain greppable; @inline
/// makes the optimizer remove the calls in Release.
@inline(__always) func _zmdNoop(_ msg: String) { _ = msg }

/// Headless WKWebView-based renderer for Mermaid diagrams and KaTeX math
@MainActor
class WebRenderer: NSObject {
    static let shared = WebRenderer()

    private var mermaidWebView: WKWebView?
    private var katexWebView: WKWebView?
    private var mermaidReady = false
    private var katexReady = false
    private var imageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        // Use the shared Cache constants — this cache previously hardcoded countLimit=100, the
        // exact thrash value Cache.diagramCountLimit was raised to 2000 to fix.
        cache.countLimit = Cache.diagramCountLimit
        cache.totalCostLimit = Cache.diagramByteLimit
        return cache
    }()

    /// Estimated in-memory byte cost of a rendered image, so the cache's totalCostLimit is
    /// actually enforced (setObject without a cost leaves the byte cap inert).
    private static func imageCost(_ image: NSImage) -> Int {
        let size = image.size
        return max(1, Int(size.width) * Int(size.height) * 4)
    }
    private var pendingMermaid: [(String, (NSImage?) -> Void)] = []
    private var pendingKatex: [(String, Bool, Bool, (NSImage?) -> Void)] = []

    // Render queues to prevent concurrent requests from overwriting completions
    private var mermaidRenderQueue: [(code: String, key: String, completion: (NSImage?) -> Void)] = []
    private var isMermaidRendering = false
    private var katexRenderQueue: [(latex: String, displayMode: Bool, isDark: Bool, key: String, completion: (NSImage?) -> Void)] = []
    private var isKatexRendering = false

    private override init() {
        super.init()
    }

    // MARK: - Cache

    private func cacheKey(for input: String, prefix: String) -> String {
        let hash = SHA256.hash(data: Data(input.utf8))
        return prefix + hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Mermaid

    func renderMermaid(_ code: String, completion: @escaping (NSImage?) -> Void) {
        let key = cacheKey(for: code, prefix: "mermaid-")
        if let cached = imageCache.object(forKey: key as NSString) {
            completion(cached)
            return
        }

        if !mermaidReady {
            pendingMermaid.append((code, completion))
            setupMermaidWebView()
            return
        }

        executeMermaidRender(code: code, key: key, completion: completion)
    }

    private func setupMermaidWebView() {
        guard mermaidWebView == nil else { return }

        let config = WKWebViewConfiguration()
        let userContentController = WKUserContentController()
        userContentController.add(self, name: "mermaidReady")
        userContentController.add(self, name: "mermaidResult")
        config.userContentController = userContentController

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        webView.navigationDelegate = self
        mermaidWebView = webView

        let html = """
        <!DOCTYPE html>
        <html><head>
        <script src="\(CDN.mermaidJS)" integrity="\(CDN.mermaidJSIntegrity)" crossorigin="anonymous"></script>
        <style>
            body { background: white; margin: 0; padding: 16px; }
            #container { font-family: -apple-system, sans-serif; }
        </style>
        </head><body>
        <div id="container"></div>
        <script>
            // L5: post mermaidReady from window.onload (which fires even when the CDN <script>
            // fails to load — offline or SRI mismatch), and guard mermaid.initialize. Previously
            // a top-level `mermaid.initialize(...)` threw ReferenceError when the script failed,
            // aborting this block before postMessage, so mermaidReady never posted and the Swift
            // pendingMermaid queue grew unbounded with "Rendering diagram..." stuck forever.
            // When mermaid is undefined, renderMermaid's await below throws and is caught, posting
            // an ERROR result so the queued item completes (as nil) instead of hanging.
            window.onload = function() {
                try {
                    if (typeof mermaid !== 'undefined') {
                        mermaid.initialize({ startOnLoad: false, theme: 'default' });
                    }
                } catch (e) {}
                window.webkit.messageHandlers.mermaidReady.postMessage('ready');
            };

            async function renderMermaid(code) {
                try {
                    const container = document.getElementById('container');
                    container.innerHTML = '';
                    const { svg } = await mermaid.render('diagram', code);
                    container.innerHTML = svg;

                    // Wait for rendering
                    await new Promise(r => setTimeout(r, 100));

                    // Convert SVG to canvas to get PNG
                    const svgEl = container.querySelector('svg');
                    if (!svgEl) { window.webkit.messageHandlers.mermaidResult.postMessage('ERROR'); return; }

                    const bbox = svgEl.getBoundingClientRect();
                    const canvas = document.createElement('canvas');
                    const scale = 2;
                    canvas.width = bbox.width * scale;
                    canvas.height = bbox.height * scale;
                    const ctx = canvas.getContext('2d');
                    ctx.scale(scale, scale);

                    const svgData = new XMLSerializer().serializeToString(svgEl);
                    const svgBlob = new Blob([svgData], { type: 'image/svg+xml;charset=utf-8' });
                    const url = URL.createObjectURL(svgBlob);
                    const img = new Image();
                    img.onload = function() {
                        ctx.drawImage(img, 0, 0);
                        URL.revokeObjectURL(url);
                        const dataURL = canvas.toDataURL('image/png');
                        window.webkit.messageHandlers.mermaidResult.postMessage(dataURL);
                    };
                    img.onerror = function() {
                        URL.revokeObjectURL(url);
                        window.webkit.messageHandlers.mermaidResult.postMessage('ERROR');
                    };
                    img.src = url;
                } catch(e) {
                    window.webkit.messageHandlers.mermaidResult.postMessage('ERROR:' + e.message);
                }
            }
        </script>
        </body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    private func executeMermaidRender(code: String, key: String, completion: @escaping (NSImage?) -> Void) {
        mermaidRenderQueue.append((code: code, key: key, completion: completion))
        processNextMermaidRender()
    }

    private func processNextMermaidRender() {
        guard !isMermaidRendering, !mermaidRenderQueue.isEmpty else { return }
        guard let webView = mermaidWebView else {
            // Drain queue with nil
            let queue = mermaidRenderQueue
            mermaidRenderQueue = []
            queue.forEach { $0.completion(nil) }
            return
        }

        isMermaidRendering = true
        let item = mermaidRenderQueue.removeFirst()

        // Escape for safe splicing into a JS backtick template literal:
        // - `\\` must double to survive the JS string parser
        // - backticks close the literal
        // - newlines must be escaped in the string representation
        // - `${` would trigger template-literal interpolation and evaluate arbitrary JS in the
        //   hidden WebView if present in user markdown (defensive hardening, not an observed RCE)
        let escapedCode = item.code
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "${", with: "\\${")
            .replacingOccurrences(of: "\n", with: "\\n")

        self.activeMermaidCompletion = { [weak self] image in
            if let image = image {
                self?.imageCache.setObject(image, forKey: item.key as NSString, cost: Self.imageCost(image))
            }
            item.completion(image)
            self?.isMermaidRendering = false
            self?.processNextMermaidRender()
        }
        startWatchdog(for: .mermaid)

        // L1: prefix with `void` so the statement result is `undefined`. renderMermaid is an async
        // JS function; without `void`, the call evaluates to a Promise that WKWebView cannot
        // serialize, so this completion fires with WKError 5 on EVERY render while the JS keeps
        // running and posts its result later via the mermaidResult handler. That advanced the queue
        // early, overwrote activeMermaidCompletion with the next item's closure, and delivered one
        // diagram's PNG to the wrong item — poisoning the SHA256 image cache for the session. With
        // `void`, this completion only fires on a genuine JS error.
        webView.evaluateJavaScript("void renderMermaid(`\(escapedCode)`)") { [weak self] _, error in
            if error != nil {
                // Genuine error: drop the active completion so a late mermaidResult cannot invoke it
                // for the wrong item, then fail this item and advance the queue.
                self?.cancelWatchdog(for: .mermaid)
                self?.activeMermaidCompletion = nil
                item.completion(nil)
                self?.isMermaidRendering = false
                self?.processNextMermaidRender()
            }
        }
    }

    private var activeMermaidCompletion: ((NSImage?) -> Void)?

    // MARK: - Render watchdog

    /// A render whose result never posts back (wedged content process, an img.onload that never
    /// fires) previously left isMermaidRendering/isKatexRendering stuck true forever — every
    /// subsequent render queued behind it and the session's diagrams/math were dead with no
    /// error. The watchdog fails the active item after a generous timeout and advances the queue.
    private static let renderWatchdogTimeout: TimeInterval = 15

    private enum RenderPipeline { case mermaid, katex }

    private var mermaidWatchdogTimer: Timer?
    private var katexWatchdogTimer: Timer?

    private func startWatchdog(for pipeline: RenderPipeline) {
        // `self?.method()` rather than `guard let self` inside the Task — the guard-let form is
        // rejected as "reference to captured var 'self'" by the older Swift toolchain CI builds
        // with.
        let timer = Timer.scheduledTimer(withTimeInterval: Self.renderWatchdogTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.watchdogFired(for: pipeline)
            }
        }
        switch pipeline {
        case .mermaid:
            mermaidWatchdogTimer?.invalidate()
            mermaidWatchdogTimer = timer
        case .katex:
            katexWatchdogTimer?.invalidate()
            katexWatchdogTimer = timer
        }
    }

    /// Consuming the active completion fails the item, resets the isRendering flag, and
    /// advances the queue; a late result for the timed-out item is then ignored because the
    /// completion is already nil.
    private func watchdogFired(for pipeline: RenderPipeline) {
        switch pipeline {
        case .mermaid:
            if let cb = activeMermaidCompletion {
                activeMermaidCompletion = nil
                cb(nil)
            }
        case .katex:
            if let cb = activeKatexCompletion {
                activeKatexCompletion = nil
                cb(nil)
            }
        }
    }

    private func cancelWatchdog(for pipeline: RenderPipeline) {
        switch pipeline {
        case .mermaid:
            mermaidWatchdogTimer?.invalidate()
            mermaidWatchdogTimer = nil
        case .katex:
            katexWatchdogTimer?.invalidate()
            katexWatchdogTimer = nil
        }
    }

    /// The headless content process died (WebKit kills background/occluded processes under
    /// memory pressure, and it can simply crash). Fail everything in flight VISIBLY and tear the
    /// web view down — the next render request rebuilds it from scratch. Without this handler the
    /// in-flight completion never ran and the pipeline hung for the rest of the session.
    fileprivate func handleWebContentProcessTermination(_ webView: WKWebView) {
        if webView === mermaidWebView {
            cancelWatchdog(for: .mermaid)
            mermaidReady = false
            mermaidWebView = nil   // must be nil BEFORE draining so processNext drains, not evaluates
            let pending = pendingMermaid
            pendingMermaid = []
            pending.forEach { $0.1(nil) }
            if let cb = activeMermaidCompletion {
                activeMermaidCompletion = nil
                cb(nil)            // resets isMermaidRendering, advances (and drains) the queue
            } else {
                processNextMermaidRender()
            }
        } else if webView === katexWebView {
            cancelWatchdog(for: .katex)
            katexReady = false
            katexWebView = nil
            let pending = pendingKatex
            pendingKatex = []
            pending.forEach { $0.3(nil) }
            if let cb = activeKatexCompletion {
                activeKatexCompletion = nil
                cb(nil)
            } else {
                processNextKatexRender()
            }
        }
    }

    // MARK: - KaTeX

    func renderMath(_ latex: String, displayMode: Bool, forceLightTheme: Bool = false, completion: @escaping (NSImage?) -> Void) {
        // Detect appearance at render time so dark-mode users get light-on-transparent math.
        // Cache key includes appearance so flipping themes triggers a re-render rather than
        // serving stale-color images. `forceLightTheme: true` is used by exports (PDF/RTF/print
        // on a white page) — without it, dark-mode renders produce near-invisible glyphs in PDF.
        let isDark = forceLightTheme
            ? false
            : NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let key = cacheKey(for: latex + (displayMode ? "-display" : "-inline") + (isDark ? "-dk" : "-lt"), prefix: "math-")
        if let cached = imageCache.object(forKey: key as NSString) {
            _zmdNoop("[WebRenderer] renderMath cache HIT for: \(latex)")
            completion(cached)
            return
        }

        if !katexReady {
            _zmdNoop("[WebRenderer] renderMath QUEUED (KaTeX not ready) for: \(latex)")
            pendingKatex.append((latex, displayMode, forceLightTheme, completion))
            setupKatexWebView()
            return
        }

        _zmdNoop("[WebRenderer] renderMath EXECUTING for: \(latex)")
        executeKatexRender(latex: latex, displayMode: displayMode, isDark: isDark, key: key, completion: completion)
    }

    private func setupKatexWebView() {
        guard katexWebView == nil else { return }
        _zmdNoop("[WebRenderer] setupKatexWebView called")

        let config = WKWebViewConfiguration()
        let userContentController = WKUserContentController()
        userContentController.add(self, name: "katexReady")
        userContentController.add(self, name: "katexResult")
        config.userContentController = userContentController

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 400), configuration: config)
        webView.navigationDelegate = self
        configureTransparentBackground(for: webView)
        katexWebView = webView

        // Why takeSnapshot instead of canvas/toDataURL: the previous implementation rendered
        // KaTeX into a container, wrapped container.outerHTML in <svg><foreignObject>, drew the
        // SVG onto a canvas, and called toDataURL. That path silently fails in WebKit because
        // (a) the foreignObject doesn't inherit the page's <link>'d KaTeX CSS, and (b) drawing
        // SVG with foreignObject onto a canvas taints the canvas, so toDataURL throws — the
        // throw escapes the JS try/catch, no message ever posts back, and the Swift placeholder
        // stays on screen forever. Instead: JS just renders KaTeX (with proper CSS applied) and
        // posts back the container's bounding rect. Swift uses WKWebView.takeSnapshot to capture
        // that rect, which respects all loaded CSS and works reliably.
        let html = """
        <!DOCTYPE html>
        <html><head>
        <link rel="stylesheet" href="\(CDN.katexCSS)" integrity="\(CDN.katexCSSIntegrity)" crossorigin="anonymous">
        <script src="\(CDN.katexJS)" integrity="\(CDN.katexJSIntegrity)" crossorigin="anonymous"></script>
        <style>
            html, body { background: transparent; margin: 0; padding: 0; }
            /* color is set per-render via JS based on the user's current macOS appearance */
            #container { display: inline-block; padding: 1px 2px; font-size: 14px; }
        </style>
        </head><body>
        <div id="container"></div>
        <script>
            window.onload = function() {
                window.webkit.messageHandlers.katexReady.postMessage('ready');
            };

            function renderMath(latex, displayMode, isDark) {
                try {
                    const container = document.getElementById('container');
                    container.innerHTML = '';
                    container.style.color = isDark ? '#e8e8e8' : '#1a1a1a';
                    katex.render(latex, container, {
                        displayMode: displayMode,
                        throwOnError: false
                    });
                    // setTimeout instead of requestAnimationFrame — RAF callbacks don't fire in
                    // headless WKWebViews (no display loop). 16ms is enough for layout/font-metric
                    // calculations to settle.
                    setTimeout(function() {
                        const r = container.getBoundingClientRect();
                        window.webkit.messageHandlers.katexResult.postMessage(JSON.stringify({
                            x: r.left, y: r.top, w: r.width, h: r.height
                        }));
                    }, 16);
                } catch(e) {
                    window.webkit.messageHandlers.katexResult.postMessage('ERROR:' + e.message);
                }
            }
        </script>
        </body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    private func configureTransparentBackground(for webView: WKWebView) {
        // Make snapshots transparent. `underPageBackgroundColor` is public; the older
        // `drawsBackground` switch is private, so only touch it if the selector exists.
        if #available(macOS 12.0, *) {
            webView.underPageBackgroundColor = .clear
        }

        if webView.responds(to: NSSelectorFromString("setDrawsBackground:")) {
            webView.setValue(false, forKey: "drawsBackground")
        }
    }

    private func executeKatexRender(latex: String, displayMode: Bool, isDark: Bool, key: String, completion: @escaping (NSImage?) -> Void) {
        katexRenderQueue.append((latex: latex, displayMode: displayMode, isDark: isDark, key: key, completion: completion))
        processNextKatexRender()
    }

    private func processNextKatexRender() {
        guard !isKatexRendering, !katexRenderQueue.isEmpty else { return }
        guard let webView = katexWebView else {
            let queue = katexRenderQueue
            katexRenderQueue = []
            queue.forEach { $0.completion(nil) }
            return
        }

        isKatexRendering = true
        let item = katexRenderQueue.removeFirst()

        let escapedLatex = item.latex.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")

        self.activeKatexCompletion = { [weak self] image in
            if let image = image {
                self?.imageCache.setObject(image, forKey: item.key as NSString, cost: Self.imageCost(image))
            }
            item.completion(image)
            self?.isKatexRendering = false
            self?.processNextKatexRender()
        }
        startWatchdog(for: .katex)

        // Pass the isDark flag through to JS so the rendered glyph color matches the user's
        // current appearance. Light text on dark themes (and vice versa) — the WebView is
        // transparent so the text-color in the snapshot is what actually shows over the
        // surrounding NSTextView.
        webView.evaluateJavaScript("renderMath('\(escapedLatex)', \(item.displayMode), \(item.isDark))") { [weak self] _, error in
            if error != nil {
                self?.cancelWatchdog(for: .katex)
                self?.activeKatexCompletion = nil
                item.completion(nil)
                self?.isKatexRendering = false
                self?.processNextKatexRender()
            }
        }
    }

    private var activeKatexCompletion: ((NSImage?) -> Void)?

    /// Decoded payload posted from the KaTeX WebView's JS — the rendered math container's
    /// bounding rect, which Swift then passes to `WKWebView.takeSnapshot`.
    private struct KatexRect: Decodable {
        let x: CGFloat
        let y: CGFloat
        let w: CGFloat
        let h: CGFloat
    }

    // MARK: - Base64 Decode Helper

    private func imageFromBase64DataURL(_ dataURL: String) -> NSImage? {
        guard dataURL.hasPrefix("data:image/png;base64,") else { return nil }
        let base64 = String(dataURL.dropFirst("data:image/png;base64,".count))
        guard let data = Data(base64Encoded: base64) else { return nil }
        return NSImage(data: data)
    }
}

// MARK: - WKScriptMessageHandler

extension WebRenderer: WKScriptMessageHandler {
    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        Task { @MainActor in
            handleMessage(name: message.name, body: message.body)
        }
    }

    private func handleMessage(name: String, body: Any) {
        guard let bodyString = body as? String else { return }

        switch name {
        case "mermaidReady":
            mermaidReady = true
            // Process pending renders
            let pending = pendingMermaid
            pendingMermaid = []
            for (code, completion) in pending {
                renderMermaid(code, completion: completion)
            }

        case "mermaidResult":
            cancelWatchdog(for: .mermaid)
            if let image = imageFromBase64DataURL(bodyString) {
                activeMermaidCompletion?(image)
            } else {
                activeMermaidCompletion?(nil)
            }
            activeMermaidCompletion = nil

        case "katexReady":
            _zmdNoop("[WebRenderer] katexReady — flushing \(pendingKatex.count) pending render(s)")
            katexReady = true
            let pending = pendingKatex
            pendingKatex = []
            for (latex, displayMode, forceLightTheme, completion) in pending {
                renderMath(latex, displayMode: displayMode, forceLightTheme: forceLightTheme, completion: completion)
            }

        case "katexResult":
            cancelWatchdog(for: .katex)
            _zmdNoop("[WebRenderer] katexResult received, body: \(bodyString.prefix(200))")
            if bodyString.hasPrefix("ERROR") {
                _zmdNoop("[WebRenderer] katexResult ERROR")
                activeKatexCompletion?(nil)
                activeKatexCompletion = nil
                return
            }
            guard let rectData = bodyString.data(using: .utf8),
                  let rect = try? JSONDecoder().decode(KatexRect.self, from: rectData),
                  rect.w > 0, rect.h > 0,
                  let webView = katexWebView else {
                _zmdNoop("[WebRenderer] katexResult parse FAILED or webview nil")
                activeKatexCompletion?(nil)
                activeKatexCompletion = nil
                return
            }
            _zmdNoop("[WebRenderer] takeSnapshot rect=\(rect.x),\(rect.y),\(rect.w),\(rect.h) webView.window=\(String(describing: webView.window))")
            let snapshotConfig = WKSnapshotConfiguration()
            snapshotConfig.rect = CGRect(x: rect.x, y: rect.y, width: rect.w + 1, height: rect.h)
            let cb = activeKatexCompletion
            activeKatexCompletion = nil
            webView.takeSnapshot(with: snapshotConfig) { image, error in
                _zmdNoop("[WebRenderer] takeSnapshot result image=\(image != nil) error=\(String(describing: error))")
                cb?(image)
            }

        default:
            break
        }
    }
}

// MARK: - WKNavigationDelegate

extension WebRenderer: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        _zmdNoop("[WebRenderer] WKNav didFail: \(error)")
    }
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        _zmdNoop("[WebRenderer] WKNav didFailProvisional: \(error)")
    }
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        _zmdNoop("[WebRenderer] WKNav didFinish")
    }
    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        _zmdNoop("[WebRenderer] WKNav didStartProvisional")
    }
    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in
            self.handleWebContentProcessTermination(webView)
        }
    }
}

// MARK: - Notification

extension Notification.Name {
    static let diagramRendered = Notification.Name("diagramRendered")
}
