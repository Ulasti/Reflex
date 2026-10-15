#if os(macOS)
import AppKit
import Foundation

/// Browser automation: reuse the front tab for sites/searches instead of
/// spawning tabs pointlessly, run in-page JavaScript (click the first link,
/// history navigation), and drive tabs via System Events keystrokes.
///
/// No custom browser only: any Chromium app (Chrome, Edge, Brave, Opera) and
/// Safari are supported; the frontmost one that qualifies is preferred, Safari
/// otherwise. In-page JS on Safari additionally needs "Allow JavaScript from
/// Apple Events" (Safari > Develop menu); keystrokes need Accessibility.
public enum BrowserController {
    public enum Navigation {
        case newTab
        case nextTab
        case previousTab
        case closeTab
        case back
        case forward
        case reload
        case scrollDown
        case scrollUp
    }

    /// The browsers BrowserController can drive. Public so the diagnostics
    /// preflight (`SystemDiagnostics`) can probe each one.
    public static let browserBundleIDs = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.operasoftware.Opera",
    ]

    /// The browser to drive: the frontmost qualifying browser if one is
    /// running, otherwise the OS default browser (from LaunchServices). This
    /// makes "no browser open → launch default and act in it" match how people
    /// actually use their Mac.
    public static func preferredBundleID() -> String {
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let frontmost, browserBundleIDs.contains(frontmost) {
            return frontmost
        }
        return defaultBrowserBundleID()
    }

    /// Resolves the system default web browser. Falls back to Safari when the
    /// default handler isn't one we can automate.
    private static func defaultBrowserBundleID() -> String {
        guard let appURL = NSWorkspace.shared.urlForApplication(
            toOpen: URL(string: "https://example.com")!
        ) else {
            return "com.apple.Safari"
        }
        let bundleID = Bundle(url: appURL)?.bundleIdentifier
        return bundleID.flatMap(browserBundleIDs.contains) == true ? bundleID! : "com.apple.Safari"
    }

    /// Opens `url` following the tab policy:
///   * no browser window → launch the default browser and put the page in the
///     single fresh tab (never a window with two tabs);
///   * a blank / new-tab page in front → reuse that tab freely;
///   * any populated tab → open a **new** tab, never overwriting what's being
///     read;
///   * unknown (couldn't read) → new tab, the safe default.
/// Returns "front tab" or "new tab".
    @discardableResult
    public static func open(_ url: URL, in browser: String? = nil) throws -> String {
        let bundleID = browser ?? preferredBundleID()
        let target = url.absoluteString
        let current = currentTabURL(bundleID: bundleID)

        let blank = ["about:blank", "about:home", "favorites://",
                     "chrome://newtab/", "chrome://new-tab-page/", "edge://newtab/"]
        // NOWINDOW / blank / empty → reuse the (single or blank) front tab.
        // nil = couldn't read (automation), ERROR = odd browser state → new tab.
        let strategy: String
        if let current {
            strategy = current == "NOWINDOW" || current.isEmpty || blank.contains(current)
                ? "front tab" : "new tab"
        } else {
            strategy = "new tab"
        }

        let script: String
        if isSafari(bundleID) {
            script = """
            tell application id "\(bundleID)"
                activate
                if (count of windows) is 0 then make new window
                \(strategy == "new tab"
                    ? "make new tab with properties {URL:\"\(target.appleScriptEscaped)\"} in front window"
                    : "set URL of current tab of front window to \"\(target.appleScriptEscaped)\"")
            end tell
            """
        } else {
            script = """
            tell application id "\(bundleID)"
                activate
                if (count of windows) is 0 then make new window
                \(strategy == "new tab"
                    ? "make new tab with properties {URL:\"\(target.appleScriptEscaped)\"} in front window"
                    : "set URL of active tab of front window to \"\(target.appleScriptEscaped)\"")
            end tell
            """
        }
        do {
            _ = try runOSA(script)
            return strategy
        } catch ActionExecutionError.automationDenied {
            // Automation (tab reuse) is denied, but simply opening the URL in
            // a browser needs no Apple Events — fall back to LaunchServices.
            let opened = NSWorkspace.shared.open(url)
            guard opened else {
                throw ActionExecutionError.launchFailed(name: url.host ?? url.absoluteString)
            }
            return "new tab"
        }
    }

    /// Runs in-page JavaScript (Safari `do JavaScript`, Chromium `execute
    /// javascript`) and returns the JS result from the browser. Throws the
    /// underlying AppleScript error on failure — e.g. Safari needs "Allow
    /// JavaScript from Apple Events" (Develop menu), otherwise `do JavaScript`
    /// raises and this surfaces it instead of silently doing nothing.
    @discardableResult
    public static func runJavaScript(_ code: String, in browser: String? = nil) throws -> String {
        let bundleID = browser ?? preferredBundleID()
        let script = isSafari(bundleID)
            ? """
            tell application id "\(bundleID)"
                activate
                if (count of windows) is 0 then make new window
                return (do JavaScript "\(code.appleScriptEscaped)" in current tab of front window)
            end tell
            """
            : """
            tell application id "\(bundleID)"
                activate
                if (count of windows) is 0 then make new window
                return (execute active tab of front window javascript "\(code.appleScriptEscaped)")
            end tell
            """
        let out = try runOSA(script)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Clicks the nth *real result* on the current page (0-based); "open the
    /// first link" is index 0. Picks links in tiers of quality: (1) anchors
    /// wrapping an `h1/h2/h3` heading outside page chrome (real search
    /// results), (2) any anchored link outside chrome, (3) any visible labeled
    /// link at all — always keeping `#`/`javascript:` fragments and hidden
    /// links out. Falls through tiers so Google's markup changes never yield
    /// "no clickable link" on a page that visibly has links. Returns the
    /// label+href, or throws with a reason when nothing clickable exists.
    @discardableResult
    public static func clickLink(at index: Int, in browser: String? = nil) throws -> String {
        let js = """
        (function() {
            function chrome(a) {
                var n = a;
                while (n && n !== document.body) {
                    var tag = (n.tagName || '').toLowerCase();
                    if (tag === 'header' || tag === 'nav' || tag === 'footer' ||
                        tag === 'button' || tag === 'menu') return true;
                    n = n.parentElement;
                }
                return false;
            }
            // Skip links inside Google's AI response / "knowledge panel" sections
            function inAIResponse(a) {
                var n = a;
                while (n && n !== document.body) {
                    var className = (n.className || '').toString();
                    var id = (n.id || '').toString();
                    // Common AI response container classes/ids
                    if (className.includes('kno-rdesc') ||      // knowledge panel description
                        className.includes('g-blk') ||         // knowledge block
                        className.includes('V3FYCf') ||        // AI overview
                        className.includes('ULSxyf') ||        // AI response
                        className.includes('yDYNvb') ||        // AI answer
                        className.includes('e24Kjd') ||        // AI snippet
                        className.includes('bkWMgd') ||        // AI box
                        id.includes('kno-') ||                 // knowledge panel
                        className.includes('mnr-c') ||         // "People also ask" / AI
                        className.includes('Wt5Tfe') ||        // AI featured snippet
                        className.includes('Gx5Zad')) {        // AI overview wrapper
                        return true;
                    }
                    // Check for role="heading" inside AI containers
                    if (n.getAttribute && n.getAttribute('role') === 'heading' &&
                        className.includes('LC20lb')) { // AI answer heading
                        return true;
                    }
                    n = n.parentElement;
                }
                return false;
            }
            // On a Google results page the organic results are the only
            // "websites" a user means by "open the third link". Shopping
            // carousels, ads (#tads), the right-rail knowledge panel and AI
            // overview all contain anchor+heading combos that would otherwise
            // outrank the real results in DOM order, so gate on them here.
            var isGoogleSearch = /(^|\\.)google\\./.test(location.hostname) &&
                location.pathname.indexOf('/search') === 0;
            function isGoogleOrganic(a) {
                // Every real Google result anchors a heading.
                if (!a.querySelector('h3, h2, [role="heading"]')) return false;
                var n = a;
                while (n && n !== document.body) {
                    var cls = (n.className || '').toString();
                    var id = (n.id || '').toString();
                    if (id === 'tads' || id === 'bottomads' || id === 'taw' ||
                        id === 'rhs' || id === 'center_col_extra' ||
                        n.hasAttribute && n.hasAttribute('data-text-ad') ||
                        cls.indexOf('commercial-unit') >= 0 ||
                        cls.indexOf('cu-container') >= 0 ||
                        cls.indexOf('pla-unit') >= 0 ||
                        cls.indexOf('sh-dgr') >= 0 ||
                        cls.indexOf('knowledge-panel') >= 0 ||
                        cls.indexOf('kno-') >= 0 ||
                        cls.indexOf('V3FYCf') >= 0 ||
                        cls.indexOf('ULSxyf') >= 0 ||
                        cls.indexOf('g-blk') >= 0 ||
                        cls.indexOf('g-scrolling-carousel') >= 0) {
                        return false;
                    }
                    n = n.parentElement;
                }
                // Must live inside the main results column.
                var m = a;
                while (m && m !== document.body) {
                    var mid = (m.id || '').toString();
                    if (mid === 'search' || mid === 'rso' || mid === 'center_col' || mid === 'res') return true;
                    m = m.parentElement;
                }
                return false;
            }
            var links = document.querySelectorAll('a[href]');
            var titled = [], outside = [], any = [];
            for (var i = 0; i < links.length; i++) {
                var a = links[i];
                var rect = a.getBoundingClientRect();
                if (rect.width === 0 || rect.height === 0) continue;
                var href = a.getAttribute('href') || '';
                if (href === '#' || href.indexOf('#') === 0 || href.indexOf('javascript:') === 0) continue;
                var label = (a.textContent || '').replace(/\\s+/g, ' ').trim();
                if (!label) continue;
                // Skip AI response links entirely
                if (inAIResponse(a)) continue;
                // On Google, only organic results count as "the Nth link".
                if (isGoogleSearch && !isGoogleOrganic(a)) continue;
                // Skip Google's navigation/filter tabs (All, Images, Videos, News, Maps, AI Mode, etc.)
                var labelLower = label.toLowerCase();
                var navTabs = ['all', 'images', 'videos', 'news', 'maps', 'shopping', 'books', 'flights', 'finance', 'ai mode', 'web',
                               'short videos', 'shorts', 'forums', 'discussions', 'perspectives', 'scholar', 'patents'];
                if (navTabs.includes(labelLower)) continue;
                var n = a;
                var isNav = false;
                while (n && n !== document.body && !isNav) {
                    var className = (n.className || '').toString();
                    var role = n.getAttribute ? n.getAttribute('role') : '';
                    if (className.includes('hdtb-mitem') ||
                        className.includes('hdtb-tl') ||
                        className.includes('hdtb') ||
                        role === 'tab' ||
                        role === 'tablist') {
                        isNav = true;
                    }
                    n = n.parentElement;
                }
                if (isNav) continue;
                // Skip boilerplate/footer/sidebar links (About, Privacy, Terms, Accessibility, etc.)
                var boilerplate = [
                    'about', 'advertising', 'business', 'accessibility', 'help',
                    'privacy', 'terms', 'settings', 'feedback', 'send feedback',
                    'how search works', 'privacy policy', 'terms of service',
                    'cookie policy', 'your data', 'ad choices', 'ad settings',
                    'places', 'directions', 'near me'
                ];
                if (boilerplate.some(b => labelLower === b || labelLower.startsWith(b + ' '))) continue;
                n = a;
                var isBoiler = false;
                while (n && n !== document.body && !isBoiler) {
                    var className = (n.className || '').toString();
                    if (className.includes('footer') ||
                        className.includes('glue') ||
                        className.includes('bottom') ||
                        className.includes('sidebar') ||
                        className.includes('side-bar') ||
                        className.includes('fbar') ||
                        className.includes('sfooter')) {
                        isBoiler = true;
                    }
                    n = n.parentElement;
                }
                if (isBoiler) continue;
                // Search result links typically have h3 inside (or h2/h1 for featured)
                var isTitled = !!a.querySelector('h1, h2, h3, [role="heading"]');
                any.push({ a: a, label: label, href: href });
                if (chrome(a)) continue;
                outside.push({ a: a, label: label, href: href });
                if (isTitled) titled.push({ a: a, label: label, href: href });
            }
            var pool = titled.length ? titled : (outside.length ? outside : any);
            if (index >= pool.length) return 'EMPTY|' + document.readyState + '|' + document.URL + '|' + links.length + '|' + outside.length + '|' + titled.length;
            var hit = pool[index];
            hit.a.scrollIntoView();
            hit.a.click();
            return 'OK|' + hit.label + '|' + hit.href;
        })()
        """
        // Fallback JS without AI filter AND without chrome/titled tier logic —
        /// just grabs the first valid visible link (skipping nav tabs & boilerplate). Used if all AI-filtered attempts fail.
        let fallbackJS = """
        (function() {
            function isNavTab(a) {
                var label = (a.textContent || '').replace(/\\s+/g, ' ').trim().toLowerCase();
                var navTabs = ['all', 'images', 'videos', 'news', 'maps', 'shopping', 'books', 'flights', 'finance', 'ai mode', 'web',
                               'short videos', 'shorts', 'forums', 'discussions', 'perspectives', 'scholar', 'patents'];
                if (navTabs.includes(label)) return true;
                var n = a;
                while (n && n !== document.body) {
                    var className = (n.className || '').toString();
                    var role = n.getAttribute ? n.getAttribute('role') : '';
                    if (className.includes('hdtb-mitem') ||
                        className.includes('hdtb-tl') ||
                        className.includes('hdtb') ||
                        role === 'tab' ||
                        role === 'tablist') {
                        return true;
                    }
                    n = n.parentElement;
                }
                return false;
            }
            function isBoilerplate(a) {
                var label = (a.textContent || '').replace(/\\s+/g, ' ').trim().toLowerCase();
                var boilerplate = [
                    'about', 'advertising', 'business', 'accessibility', 'help',
                    'privacy', 'terms', 'settings', 'feedback', 'send feedback',
                    'how search works', 'privacy policy', 'terms of service',
                    'cookie policy', 'your data', 'ad choices', 'ad settings',
                    'places', 'directions', 'near me'
                ];
                if (boilerplate.some(b => label === b || label.startsWith(b + ' '))) return true;
                var n = a;
                while (n && n !== document.body) {
                    var className = (n.className || '').toString();
                    if (className.includes('footer') ||
                        className.includes('glue') ||
                        className.includes('bottom') ||
                        className.includes('sidebar') ||
                        className.includes('side-bar') ||
                        className.includes('fbar') ||
                        className.includes('sfooter')) {
                        return true;
                    }
                    n = n.parentElement;
                }
                return false;
            }
            // On Google, exclude ads and shopping/knowledge carousels so the
            // fallback still lands on a real result rather than a "Read more"
            // shopping tile.
            function isGoogleJunk(a) {
                if (!(/(^|\\.)google\\./.test(location.hostname) &&
                      location.pathname.indexOf('/search') === 0)) return false;
                var n = a;
                while (n && n !== document.body) {
                    var cls = (n.className || '').toString();
                    var id = (n.id || '').toString();
                    if (id === 'tads' || id === 'bottomads' || id === 'taw' || id === 'rhs' ||
                        n.hasAttribute && n.hasAttribute('data-text-ad') ||
                        cls.indexOf('commercial-unit') >= 0 ||
                        cls.indexOf('cu-container') >= 0 ||
                        cls.indexOf('pla-unit') >= 0 ||
                        cls.indexOf('sh-dgr') >= 0 ||
                        cls.indexOf('knowledge-panel') >= 0 ||
                        cls.indexOf('kno-') >= 0 ||
                        cls.indexOf('g-scrolling-carousel') >= 0) {
                        return true;
                    }
                    n = n.parentElement;
                }
                return false;
            }
            var links = document.querySelectorAll('a[href]');
            var any = [];
            for (var i = 0; i < links.length; i++) {
                var a = links[i];
                var rect = a.getBoundingClientRect();
                if (rect.width === 0 || rect.height === 0) continue;
                var href = a.getAttribute('href') || '';
                if (href === '#' || href.indexOf('#') === 0 || href.indexOf('javascript:') === 0) continue;
                var label = (a.textContent || '').replace(/\\s+/g, ' ').trim();
                if (!label) continue;
                if (isNavTab(a)) continue;
                if (isBoilerplate(a)) continue;
                if (isGoogleJunk(a)) continue;
                any.push({ a: a, label: label, href: href });
            }
            if (any.length === 0) return 'EMPTY|' + document.readyState + '|' + document.URL + '|' + links.length + '|0|0';
            var hit = any[Math.min(\(index), any.length - 1)];
            hit.a.scrollIntoView();
            hit.a.click();
            return 'OK|' + hit.label + '|' + hit.href;
        })()
        """
        let attempts = 6
        var lastReason = "the page has no links"
        for attempt in 0..<attempts {
            let raw = try runJavaScript(js, in: browser)
            let parts = raw.split(separator: "|", maxSplits: 2).map(String.init)
            if parts.first == "OK", parts.count >= 3 {
                return parts[1] + " — " + parts[2]
            }
            if parts.first == "EMPTY", parts.count >= 6 {
                lastReason = parts[1] == "complete"
                    ? "page is \(parts[1]) (\(parts[2]) — \(parts[3]) links, \(parts[4]) usable, \(parts[5]) rankable)"
                    : "page still \(parts[1]) (\(parts[2]) — \(parts[3]) links); waiting for it to load"
            }
            if attempt < attempts - 1 {
                if parts.first == "EMPTY", parts.count >= 6,
                   let usable = Int(parts[4]), parts[1] == "complete", usable == 0 {
                    break
                }
                Thread.sleep(forTimeInterval: 0.7)
            }
        }
        // Fallback: try once without AI filter (some queries only show AI overview)
        do {
            let raw = try runJavaScript(fallbackJS, in: browser)
            let parts = raw.split(separator: "|", maxSplits: 2).map(String.init)
            if parts.first == "OK", parts.count >= 3 {
                return parts[1] + " — " + parts[2]
            }
        } catch {
            // ignore fallback error
        }
        throw ActionExecutionError.noClickableLink(index: index, reason: lastReason)
    }

    /// Navigates/scrolls/scroll reloads and tab management.
    public static func navigate(_ nav: Navigation, in browser: String? = nil) throws {
        let bundleID = browser ?? preferredBundleID()
        switch nav {
        case .back:
            try runJavaScript("history.back()", in: bundleID)
        case .forward:
            try runJavaScript("history.forward()", in: bundleID)
        case .reload:
            try runJavaScript("location.reload()", in: bundleID)
        case .scrollDown:
            try runJavaScript("window.scrollBy(0, window.innerHeight * 0.8)", in: bundleID)
        case .scrollUp:
            try runJavaScript("window.scrollBy(0, -window.innerHeight * 0.8)", in: bundleID)
        case .newTab:
            try keystroke(key: "t", modifiers: "{command down}", bundleID: bundleID)
        case .nextTab:
            try keystroke(key: "]", modifiers: "{command down, shift down}", bundleID: bundleID)
        case .previousTab:
            try keystroke(key: "[", modifiers: "{command down, shift down}", bundleID: bundleID)
        case .closeTab:
            try keystroke(key: "w", modifiers: "{command down}", bundleID: bundleID)
        }
    }

    // MARK: - Internals

    private static func isSafari(_ bundleID: String) -> Bool {
        bundleID == "com.apple.Safari"
    }

    /// The front tab's URL: "" when there's no window or a genuinely empty tab,
    /// "ERROR" when Safari knows it but we couldn't read it, nil when the whole
    /// read was denied (automation). `open` uses this to decide reuse vs new.
    private static func currentTabURL(bundleID: String) -> String? {
        let script = isSafari(bundleID)
            ? """
            tell application id "\(bundleID)"
                if (count of windows) is 0 then return "NOWINDOW"
                if (count of tabs of front window) is 0 then return ""
                try
                    set u to URL of current tab of front window
                    if u is missing value then return ""
                    return u
                on error
                    return "ERROR"
                end try
            end tell
            """
            : """
            tell application id "\(bundleID)"
                if (count of windows) is 0 then return "NOWINDOW"
                try
                    set u to URL of active tab of front window
                    if u is missing value then return ""
                    return u
                on error
                    return "ERROR"
                end try
            end tell
            """
        guard let out = try? runOSA(script) else {
            return nil
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs an AppleScript and retries once on the transient automation
    /// denial (-1723) that macOS raises when the TCC prompt is still being
    /// granted; a fresh attempt immediately after usually succeeds. If the
    /// permission is genuinely missing, surfaces a readable guidance error.
    private static func runOSA(_ script: String) throws -> String {
        do {
            return try ActionDispatcher.runTool("/usr/bin/osascript", arguments: ["-e", script])
        } catch let ActionExecutionError.unexpectedExit(_, _, output) where output.contains("Access not allowed") {
            Thread.sleep(forTimeInterval: 0.8)
            do {
                return try ActionDispatcher.runTool("/usr/bin/osascript", arguments: ["-e", script])
            } catch let ActionExecutionError.unexpectedExit(_, _, retry) where retry.contains("Access not allowed") {
                throw ActionExecutionError.automationDenied(what: "your browsers")
            }
        }
    }

    private static func keystroke(key: String, modifiers: String, bundleID: String) throws {
        let script = """
        tell application id "\(bundleID)"
            activate
        end tell
        tell application "System Events"
            keystroke "\(key)" using \(modifiers)
        end tell
        """
        _ = try runOSA(script)
    }
}
#endif
