import AppKit
import WebKit
import CryptoKit

/// Headless WKWebView-based renderer for Mermaid diagrams and KaTeX math
@MainActor
class WebRenderer: NSObject {
    static let shared = WebRenderer()

    private var mermaidWebView: WKWebView?
    private var katexWebView: WKWebView?
    private var mermaidReady = false
    private var katexReady = false
    private var imageCache: [String: NSImage] = [:]
    private var pendingMermaid: [(String, (NSImage?) -> Void)] = []
    private var pendingKatex: [(String, Bool, (NSImage?) -> Void)] = []

    private override init() {
        super.init()
    }

    // MARK: - Cache

    private func cacheKey(for input: String, prefix: String) -> String {
        let hash = SHA256.hash(data: Data(input.utf8))
        return prefix + hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    func getCachedImage(for input: String, prefix: String) -> NSImage? {
        return imageCache[cacheKey(for: input, prefix: prefix)]
    }

    // MARK: - Mermaid

    func renderMermaid(_ code: String, completion: @escaping (NSImage?) -> Void) {
        let key = cacheKey(for: code, prefix: "mermaid-")
        if let cached = imageCache[key] {
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
        <script src="https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"></script>
        <style>
            body { background: white; margin: 0; padding: 16px; }
            #container { font-family: -apple-system, sans-serif; }
        </style>
        </head><body>
        <div id="container"></div>
        <script>
            mermaid.initialize({ startOnLoad: false, theme: 'default' });
            window.webkit.messageHandlers.mermaidReady.postMessage('ready');

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
        guard let webView = mermaidWebView else {
            completion(nil)
            return
        }

        let escapedCode = code.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "\n", with: "\\n")

        // Store completion for callback
        self.activeMermaidCompletion = { [weak self] image in
            if let image = image {
                self?.imageCache[key] = image
            }
            completion(image)
        }

        webView.evaluateJavaScript("renderMermaid(`\(escapedCode)`)") { _, error in
            if error != nil {
                completion(nil)
            }
        }
    }

    private var activeMermaidCompletion: ((NSImage?) -> Void)?

    // MARK: - KaTeX

    func renderMath(_ latex: String, displayMode: Bool, completion: @escaping (NSImage?) -> Void) {
        let key = cacheKey(for: latex + (displayMode ? "-display" : "-inline"), prefix: "math-")
        if let cached = imageCache[key] {
            completion(cached)
            return
        }

        if !katexReady {
            pendingKatex.append((latex, displayMode, completion))
            setupKatexWebView()
            return
        }

        executeKatexRender(latex: latex, displayMode: displayMode, key: key, completion: completion)
    }

    private func setupKatexWebView() {
        guard katexWebView == nil else { return }

        let config = WKWebViewConfiguration()
        let userContentController = WKUserContentController()
        userContentController.add(self, name: "katexReady")
        userContentController.add(self, name: "katexResult")
        config.userContentController = userContentController

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 400), configuration: config)
        webView.navigationDelegate = self
        katexWebView = webView

        let html = """
        <!DOCTYPE html>
        <html><head>
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.css">
        <script src="https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.js"></script>
        <style>
            body { background: white; margin: 0; padding: 8px; }
            #container { font-size: 16px; color: black; }
        </style>
        </head><body>
        <div id="container"></div>
        <script>
            window.onload = function() {
                window.webkit.messageHandlers.katexReady.postMessage('ready');
            };

            function renderMath(latex, displayMode) {
                try {
                    const container = document.getElementById('container');
                    katex.render(latex, container, {
                        displayMode: displayMode,
                        throwOnError: false
                    });

                    setTimeout(function() {
                        // Use html2canvas-style approach: render to SVG foreignObject
                        const bbox = container.getBoundingClientRect();
                        const canvas = document.createElement('canvas');
                        const scale = 2;
                        canvas.width = bbox.width * scale;
                        canvas.height = bbox.height * scale;
                        const ctx = canvas.getContext('2d');

                        // Create SVG with foreignObject
                        const svgStr = '<svg xmlns="http://www.w3.org/2000/svg" width="' + bbox.width + '" height="' + bbox.height + '">' +
                            '<foreignObject width="100%" height="100%">' +
                            '<div xmlns="http://www.w3.org/1999/xhtml">' + container.outerHTML + '</div>' +
                            '</foreignObject></svg>';
                        const svgBlob = new Blob([svgStr], { type: 'image/svg+xml;charset=utf-8' });
                        const url = URL.createObjectURL(svgBlob);
                        const img = new Image();
                        img.onload = function() {
                            ctx.scale(scale, scale);
                            ctx.drawImage(img, 0, 0);
                            URL.revokeObjectURL(url);
                            const dataURL = canvas.toDataURL('image/png');
                            window.webkit.messageHandlers.katexResult.postMessage(dataURL);
                        };
                        img.onerror = function() {
                            URL.revokeObjectURL(url);
                            window.webkit.messageHandlers.katexResult.postMessage('ERROR');
                        };
                        img.src = url;
                    }, 100);
                } catch(e) {
                    window.webkit.messageHandlers.katexResult.postMessage('ERROR:' + e.message);
                }
            }
        </script>
        </body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    private func executeKatexRender(latex: String, displayMode: Bool, key: String, completion: @escaping (NSImage?) -> Void) {
        guard let webView = katexWebView else {
            completion(nil)
            return
        }

        let escapedLatex = latex.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")

        self.activeKatexCompletion = { [weak self] image in
            if let image = image {
                self?.imageCache[key] = image
            }
            completion(image)
        }

        webView.evaluateJavaScript("renderMath('\(escapedLatex)', \(displayMode))") { _, error in
            if error != nil {
                completion(nil)
            }
        }
    }

    private var activeKatexCompletion: ((NSImage?) -> Void)?

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
            if let image = imageFromBase64DataURL(bodyString) {
                activeMermaidCompletion?(image)
            } else {
                activeMermaidCompletion?(nil)
            }
            activeMermaidCompletion = nil

        case "katexReady":
            katexReady = true
            let pending = pendingKatex
            pendingKatex = []
            for (latex, displayMode, completion) in pending {
                renderMath(latex, displayMode: displayMode, completion: completion)
            }

        case "katexResult":
            if let image = imageFromBase64DataURL(bodyString) {
                activeKatexCompletion?(image)
            } else {
                activeKatexCompletion?(nil)
            }
            activeKatexCompletion = nil

        default:
            break
        }
    }
}

// MARK: - WKNavigationDelegate

extension WebRenderer: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        // Silently handle navigation failures
    }
}

// MARK: - Notification

extension Notification.Name {
    static let diagramRendered = Notification.Name("diagramRendered")
}
