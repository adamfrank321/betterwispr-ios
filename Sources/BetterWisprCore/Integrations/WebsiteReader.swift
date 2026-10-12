#if os(macOS)
import AppKit
import ApplicationServices

/// Reads the front page's address from a supported browser through Accessibility, only to match writing modes on this Mac.
public enum WebsiteReader {
    /// The browsers VoiceInk reads URLs from.
    static let browsers: Set<String> = [
        "com.apple.Safari", "company.thebrowser.Browser", "company.thebrowser.dia", "com.google.Chrome", "ai.perplexity.comet",
        "com.microsoft.edgemac", "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "com.kagi.kagimacOS",
        "ru.yandex.desktop.yandex-browser",
    ]

    /// Starts reading the focused window's page URL when `app` is a supported browser; the task yields nil without Accessibility access or after 500 ms.
    @MainActor
    public static func read(_ app: NSRunningApplication) -> Task<String?, Never>? {
        guard let bundleID = app.bundleIdentifier, browsers.contains(bundleID) else { return nil }
        let pid = app.processIdentifier, trusted = AXIsProcessTrusted()
        return Task { trusted ? await Task.detached(priority: .userInitiated) { pageURL(pid: pid) }.value(within: .milliseconds(500)) ?? nil : nil }
    }

    /// Chrome exposes the URL as the window's AXDocument; otherwise the page around the focused element, then the first web area's AXURL.
    private static func pageURL(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let window = app.element(kAXFocusedWindowAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(window, 0.25)
        if let document = window.string(kAXDocumentAttribute), !document.isEmpty { return document }
        return focusedPageURL(in: app) ?? firstPageURL(in: window)
    }

    /// Walks up from the focused element and keeps the outermost web area's AXURL, so a frame inside the page doesn't count.
    private static func focusedPageURL(in app: AXUIElement) -> String? {
        let attributes = [kAXRoleAttribute, kAXURLAttribute, kAXParentAttribute] as CFArray
        var element = app.element(kAXFocusedUIElementAttribute), url: String?, hops = 0
        while let current = element, hops < 64, !Task.isCancelled {
            hops += 1
            AXUIElementSetMessagingTimeout(current, 0.25)
            var copied: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(current, attributes, [], &copied) == .success,
                  let values = copied as? [AnyObject], values.count == 3 else { break }
            if values[0] as? String == "AXWebArea", let page = values[1] as? URL { url = page.absoluteString }
            element = CFGetTypeID(values[2]) == AXUIElementGetTypeID() ? (values[2] as! AXUIElement) : nil
        }
        return url
    }

    /// The first web area's AXURL in the window, which skips bookmark-bar links; used when focus is in the browser's toolbar.
    private static func firstPageURL(in window: AXUIElement) -> String? {
        let attributes = [kAXRoleAttribute, kAXURLAttribute, kAXChildrenAttribute] as CFArray
        var pending = [(element: window, depth: 0)], visited = 0
        while let (element, depth) = pending.popLast(), visited < 500, !Task.isCancelled {
            visited += 1
            AXUIElementSetMessagingTimeout(element, 0.25)
            var copied: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, attributes, [], &copied) == .success,
                  let values = copied as? [AnyObject], values.count == 3 else { continue }
            if values[0] as? String == "AXWebArea" {
                if let url = values[1] as? URL { return url.absoluteString }
            } else if depth < 12, let children = values[2] as? [AXUIElement] {
                pending.append(contentsOf: children.reversed().map { (element: $0, depth: depth + 1) })
            }
        }
        return nil
    }
}
#endif
