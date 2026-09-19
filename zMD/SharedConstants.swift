import Foundation

// Constants shared between the zMD app target and the zMDQuickLook extension target.
// Lives outside SettingsManager.swift so the extension can compile MarkdownParser.swift without
// dragging in SettingsManager (ObservableObject, AppKit fonts, UserDefaults state).

/// CDN resource URLs for preview/export scripts. Both preview (WebRenderer) and exported HTML
/// (MarkdownParser.toHTML) reference the same strings — defining them once eliminates version
/// drift between the two consumers.
nonisolated enum CDN {
    // S2: pin Mermaid to an exact version (was the floating `mermaid@10`, which auto-adopted any
    // new 10.x without review) and carry a Subresource Integrity hash for every resource. The
    // `integrity` attribute makes the browser / WKWebView refuse a tampered script instead of
    // executing it — important because these run inside the unsandboxed app's WebView and in any
    // exported HTML opened by others. Hashes are the sha384 of the pinned files served by jsDelivr.
    static let mermaidJS = "https://cdn.jsdelivr.net/npm/mermaid@11.16.0/dist/mermaid.min.js"
    static let mermaidJSIntegrity = "sha384-T/0lMUdJpd2S1ZHtRiofG3htU3xPCrFVeAQ1UUE2TJwlEJSV5NUwn30kP28n238E"
    static let katexCSS = "https://cdn.jsdelivr.net/npm/katex@0.18.1/dist/katex.min.css"
    static let katexCSSIntegrity = "sha384-1vdNCNel6Tx/NQa8IR1mGOGKsbGreCkOPfbtPPnUURJ5Tu2PRVfQ/7KLZC+Pi1p1"
    static let katexJS = "https://cdn.jsdelivr.net/npm/katex@0.18.1/dist/katex.min.js"
    static let katexJSIntegrity = "sha384-ycJ6GAwiS15LoUPipwJOrWTvkUHl/YqELValBwI5I4awP1EeEQJYarj+w85ntcz7"
    static let katexAutoRenderJS = "https://cdn.jsdelivr.net/npm/katex@0.18.1/dist/contrib/auto-render.min.js"
    static let katexAutoRenderJSIntegrity = "sha384-bjyGPfbij8/NDKJhSGZNP/khQVgtHUE5exjm4Ydllo42FwIgYsdLO2lXGmRBf5Mz"
}
