import AppKit
import WebKit

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Constants

    private static let dataDir: String = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("QwenUsage", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }()
    private static let savedCookiePath: String = "\(dataDir)/saved_cookies.txt"
    private static let pollInterval: TimeInterval = 300  // 5 minutes
    private static let billingURL = "https://home.qwencloud.com/billing/subscription/token-plan-individual"
    private static let userInfoURL = "https://home.qwencloud.com/tool/user/info.json"
    private static let bailianBase = "https://cs-data.qwencloud.com"

    // MARK: - State

    private var statusItem: NSStatusItem!
    private var pollTimer: Timer?
    private var loginWindow: NSWindow?
    private var loginWebView: WKWebView?
    private var isLoggedIn = false
    private var lastError: String?
    private var usageData: UsageData?

    struct UsageData {
        let per5HourTotal: Double
        let per5HourUsed: Double
        let per5HourRefreshTime: Double
        let perWeekTotal: Double
        let perWeekUsed: Double
        let perWeekRefreshTime: Double
        let perMonthTotal: Double
        let perMonthUsed: Double
        let perMonthRefreshTime: Double
        let planName: String
        let status: String
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Qwen --"
        statusItem.button?.toolTip = "Qwen Cloud Usage"

        // The status bar image bakes in fixed colors chosen for the appearance
        // at render time. When auto light/dark flips while the app is running,
        // the cached image keeps the stale palette (e.g. dark-mode colors on a
        // light menu bar) and stays illegible until the next poll or manual
        // refresh. Re-render on every appearance change.
        // There is no NSApplication appearance notification; KVO on
        // effectiveAppearance is the documented observation point.
        NSApp.addObserver(self, forKeyPath: "effectiveAppearance", options: [], context: nil)

        rebuildMenu()
        tryRestoreSession()
        startPolling()
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.invalidate()
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()

        if let data = usageData {
            let planItem = NSMenuItem(title: "\(data.planName)  [\(data.status)]", action: nil, keyEquivalent: "")
            planItem.isEnabled = false
            menu.addItem(planItem)
            menu.addItem(NSMenuItem.separator())

            addUsageRow(to: menu, label: "5h window", used: data.per5HourUsed, total: data.per5HourTotal, refreshTime: data.per5HourRefreshTime)
            addUsageRow(to: menu, label: "Weekly", used: data.perWeekUsed, total: data.perWeekTotal, refreshTime: data.perWeekRefreshTime)
            // Monthly: not in current Qwen token plan API. Keep for future (e.g. ClaudeCode or other providers).
            // addUsageRow(to: menu, label: "Monthly", used: data.perMonthUsed, total: data.perMonthTotal, refreshTime: data.perMonthRefreshTime)

            menu.addItem(NSMenuItem.separator())
        }

        if let err = lastError {
            let errItem = NSMenuItem(title: "Error: \(err)", action: nil, keyEquivalent: "")
            errItem.isEnabled = false
            menu.addItem(errItem)
            menu.addItem(NSMenuItem.separator())
        }

        if isLoggedIn {
            let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
            refreshItem.target = self
            menu.addItem(refreshItem)

            let logoutItem = NSMenuItem(title: "Logout", action: #selector(logout), keyEquivalent: "")
            logoutItem.target = self
            menu.addItem(logoutItem)
        } else {
            let loginItem = NSMenuItem(title: "Login to Qwen Cloud...", action: #selector(showLogin), keyEquivalent: "l")
            loginItem.target = self
            menu.addItem(loginItem)
        }

        menu.addItem(NSMenuItem.separator())

        let openWebItem = NSMenuItem(title: "Open Billing Page", action: #selector(openBillingPage), keyEquivalent: "")
        openWebItem.target = self
        menu.addItem(openWebItem)

        let quitItem = NSMenuItem(title: "Quit QwenUsage", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func addUsageRow(to menu: NSMenu, label: String, used: Double, total: Double, refreshTime: Double) {
        let remaining = total - used
        let pct = total > 0 ? (used / total * 100) : 0
        let title = String(format: "%@:  %.0f / %.0f  (%.1f%% used, %.0f left)", label, used, total, pct, remaining)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)

        if refreshTime > 0 {
            let date = Date(timeIntervalSince1970: refreshTime / 1000.0)
            let formatter = DateFormatter()
            formatter.dateFormat = "MM/dd HH:mm"
            let refreshItem = NSMenuItem(title: "    next refresh: \(formatter.string(from: date))", action: nil, keyEquivalent: "")
            refreshItem.isEnabled = false
            menu.addItem(refreshItem)
        }
    }

    // MARK: - Status Bar Rendering

    private func updateStatusBar() {
        guard let data = usageData else {
            statusItem.button?.image = nil
            statusItem.button?.title = isLoggedIn ? "Q --" : "Q ?"
            return
        }
        let pct5h = data.per5HourTotal > 0 ? (data.per5HourUsed / data.per5HourTotal * 100) : 0
        let pctWeek = data.perWeekTotal > 0 ? (data.perWeekUsed / data.perWeekTotal * 100) : 0
        let remainPct5h = 100.0 - pct5h
        let remainPctWeek = 100.0 - pctWeek

        // Color by remaining %: green > 50, yellow 20-50, red < 20.
        // Saturated palettes chosen for contrast against the menu bar in each appearance.
        let dark = (statusItem.button?.effectiveAppearance ?? NSApp.effectiveAppearance)
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        func color(for remainPct: Double) -> NSColor {
            if dark {
                if remainPct > 50 { return NSColor(red: 0.40, green: 0.90, blue: 0.50, alpha: 1.0) }
                if remainPct > 20 { return NSColor(red: 1.00, green: 0.80, blue: 0.30, alpha: 1.0) }
                return NSColor(red: 1.00, green: 0.45, blue: 0.40, alpha: 1.0)
            } else {
                if remainPct > 50 { return NSColor(red: 0.05, green: 0.45, blue: 0.18, alpha: 1.0) }
                if remainPct > 20 { return NSColor(red: 0.70, green: 0.42, blue: 0.00, alpha: 1.0) }
                return NSColor(red: 0.75, green: 0.08, blue: 0.08, alpha: 1.0)
            }
        }

        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let textColor: NSColor = dark ? .white : .black
        // Brand hue distinguishes the two usage apps at a glance (Qwen = violet).
        let brandColor: NSColor = dark ? NSColor(red: 0.72, green: 0.58, blue: 1.00, alpha: 1.0)
                                       : NSColor(red: 0.38, green: 0.20, blue: 0.72, alpha: 1.0)

        let parts: [(String, NSColor, NSFont)] = [
            ("Q ", brandColor, font),
            (String(format: "5h:%.0f%%", remainPct5h), color(for: remainPct5h), font),
            (" · ", textColor, labelFont),
            (String(format: "W:%.0f%%", remainPctWeek), color(for: remainPctWeek), font),
        ]

        // Measure total width
        var totalWidth: CGFloat = 0
        let height: CGFloat = 18
        var sizes: [(String, CGSize, NSColor, NSFont)] = []
        for (text, col, f) in parts {
            let s = (text as NSString).size(withAttributes: [.font: f])
            sizes.append((text, s, col, f))
            totalWidth += s.width
        }

        let imageSize = NSSize(width: totalWidth + 2, height: height)
        let image = NSImage(size: imageSize, flipped: false) { _ in
            var x: CGFloat = 1
            let y: CGFloat = (height - font.ascender + font.descender) / 2
            for (text, size, col, f) in sizes {
                (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: f, .foregroundColor: col])
                x += size.width
            }
            return true
        }
        image.isTemplate = false

        statusItem.button?.title = ""
        statusItem.button?.image = image

        statusItem.button?.toolTip = String(format: "5h: %.0f/%.0f (%.0f%% used)\nWeek: %.0f/%.0f (%.0f%% used)",
            data.per5HourUsed, data.per5HourTotal, pct5h,
            data.perWeekUsed, data.perWeekTotal, pctWeek)
    }

    // MARK: - Polling

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.fetchUsage()
        }
        // Delay first fetch — WKWebsiteDataStore needs time to load cookies from disk
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.fetchUsageWithRetry(attemptsLeft: 3)
        }
    }

    private func fetchUsageWithRetry(attemptsLeft: Int) {
        getSecToken { [weak self] token in
            guard let self = self else { return }
            if let token = token {
                DispatchQueue.main.async { self.isLoggedIn = true }
                self.fetchSubscriptionData(secToken: token)
            } else if attemptsLeft > 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                    self.fetchUsageWithRetry(attemptsLeft: attemptsLeft - 1)
                }
            } else {
                DispatchQueue.main.async {
                    if self.isLoggedIn {
                        self.handleSessionExpired()
                    }
                }
            }
        }
    }

    @objc private func refreshNow() {
        lastError = nil
        fetchUsage()
    }

    /// Light/dark (or accent) changed: re-render the status bar image with the
    /// palette that matches the new appearance. No network fetch needed.
    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if object as? NSApplication === NSApp, keyPath == "effectiveAppearance" {
            NSLog("[appearance] effectiveAppearance changed, re-rendering status bar")
            DispatchQueue.main.async { [weak self] in self?.updateStatusBar() }
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }

    private func fetchUsage() {
        getSecToken { [weak self] token in
            guard let self = self, let token = token else {
                DispatchQueue.main.async {
                    if self?.isLoggedIn == true {
                        self?.handleSessionExpired()
                    }
                }
                return
            }
            DispatchQueue.main.async {
                self.isLoggedIn = true
            }
            self.fetchSubscriptionData(secToken: token)
        }
    }

    // MARK: - Cookie Management

    /// Get cookies from WKWebsiteDataStore, falling back to saved_cookies.txt.
    /// Persists cookies to disk for next launch.
    private func getCookieHeader(completion: @escaping (String?) -> Void) {
        let cookieStore = WKWebsiteDataStore.default().httpCookieStore
        cookieStore.getAllCookies { cookies in
            let relevantCookies = cookies.filter {
                $0.domain.contains("qwencloud.com") || $0.domain.contains("qianwenai.com")
            }
            var cookieHeader = relevantCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")

            // Fallback to saved cookies from file
            if cookieHeader.isEmpty,
               let saved = try? String(contentsOfFile: Self.savedCookiePath, encoding: .utf8),
               !saved.isEmpty {
                cookieHeader = saved
            }

            // Persist cookies for next launch (0600 permissions)
            if !cookieHeader.isEmpty {
                Self.writeSecure(cookieHeader, to: Self.savedCookiePath)
            }

            completion(cookieHeader.isEmpty ? nil : cookieHeader)
        }
    }

    /// Write a file with 0600 permissions (owner read/write only).
    private static func writeSecure(_ content: String, to path: String) {
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o600)
    }

    /// Delete saved cookies (on logout or session expiry).
    private func clearSavedCookies() {
        try? FileManager.default.removeItem(atPath: Self.savedCookiePath)
    }

    // MARK: - Auth

    private func getSecToken(completion: @escaping (String?) -> Void) {
        guard let url = URL(string: Self.userInfoURL) else {
            completion(nil)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        getCookieHeader { [weak self] cookieHeader in
            guard let self = self, let cookieHeader = cookieHeader else {
                completion(nil)
                return
            }
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

            URLSession.shared.dataTask(with: request) { data, _, _ in
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let code = json["code"] as? String else {
                    completion(nil)
                    return
                }
                if code == "ConsoleNeedLogin" {
                    self.clearSavedCookies()
                    DispatchQueue.main.async { self.handleSessionExpired() }
                    completion(nil)
                    return
                }
                let secToken = (json["data"] as? [String: Any])?["secToken"] as? String
                completion(secToken)
            }.resume()
        }
    }

    // MARK: - API Calls

    /// POST to cs-data.qwencloud.com/data/api.json (Bailian gateway — for sfm_bailian / Zelda APIs)
    /// Bailian gateway requires: V:"1.0" wrapper + cornerstoneParam inside Data
    private func callBailianApi(api: String, data: [String: Any], secToken: String, completion: @escaping (Data?) -> Void) {
        let cornerstoneParam: [String: Any] = [
            "domain": "home.qwencloud.com",
            "consoleSite": "QWENCLOUD",
            "console": "ONE_CONSOLE",
            "xsp_lang": "en",
            "protocol": "V2",
            "productCode": "p_efm"
        ]
        var enrichedData = data
        enrichedData["cornerstoneParam"] = cornerstoneParam

        let params: [String: Any] = [
            "Api": api,
            "Data": enrichedData,
            "V": "1.0"
        ]

        let product = "sfm_bailian"
        let action = "IntlBroadScopeAspnGateway"
        let apiEncoded = api.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "\(Self.bailianBase)/data/api.json?product=\(product)&action=\(action)&api=\(apiEncoded)") else {
            completion(nil)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let paramsJSON = (try? JSONSerialization.data(withJSONObject: params)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let encodedParams = paramsJSON.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let body = "product=\(product)&action=\(action)&sec_token=\(secToken)&region=ap-southeast-1&params=\(encodedParams)"
        request.httpBody = body.data(using: .utf8)

        getCookieHeader { cookieHeader in
            if let cookieHeader = cookieHeader {
                request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            }
            URLSession.shared.dataTask(with: request) { data, _, _ in
                completion(data)
            }.resume()
        }
    }

    // MARK: - Data Fetching

    private func fetchSubscriptionData(secToken: String) {
        let group = DispatchGroup()
        var results: [String: Data] = [:]
        let lock = NSLock()

        // API 1: Subscription (specCode, status, remainingDays)
        group.enter()
        callBailianApi(api: "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/subscription", data: ["commodityCode": "sfm_tokenplansolo_public_intl"], secToken: secToken) { data in
            if let data = data {
                lock.lock(); results["zelda_subscription"] = data; lock.unlock()
            }
            group.leave()
        }

        // API 2: Quota config (per5Hour/perWeek limits by specCode)
        group.enter()
        callBailianApi(api: "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/quota-config", data: ["commodityCode": "sfm_tokenplansolo_public_intl"], secToken: secToken) { data in
            if let data = data {
                lock.lock(); results["zelda_quota"] = data; lock.unlock()
            }
            group.leave()
        }

        // API 3: Usage stats (percentages + reset times)
        group.enter()
        callBailianApi(api: "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage", data: ["commodityCode": "sfm_tokenplansolo_public_intl"], secToken: secToken) { data in
            if let data = data {
                lock.lock(); results["zelda_usage"] = data; lock.unlock()
            }
            group.leave()
        }

        group.notify(queue: .main) { [weak self] in
            self?.parseAllResponses(results)
        }
    }

    // MARK: - Response Parsing

    private func parseAllResponses(_ results: [String: Data]) {
        // Helper: extract data.DataV2.data.data from a Zelda response
        func zeldaInnerData(_ rawData: Data?) -> [String: Any]? {
            guard let rawData = rawData,
                  let json = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any],
                  let outer = json["data"] as? [String: Any],
                  let dataV2 = outer["DataV2"] as? [String: Any],
                  let inner = dataV2["data"] as? [String: Any],
                  let payload = inner["data"] as? [String: Any] else { return nil }
            return payload
        }

        // 1. Get specCode from subscription
        var specCode = "lite"
        var planStatus = "UNKNOWN"
        var remainingDays = 0
        if let sub = zeldaInnerData(results["zelda_subscription"]) {
            specCode = sub["specCode"] as? String ?? "lite"
            planStatus = sub["status"] as? String ?? "UNKNOWN"
            remainingDays = (sub["remainingDays"] as? NSNumber)?.intValue ?? 0
        }

        // 2. Get quota limits from quota-config
        var fiveHourTotal: Double = 0
        var weeklyTotal: Double = 0
        if let quota = zeldaInnerData(results["zelda_quota"]),
           let planQuota = quota[specCode] as? [String: Any] {
            fiveHourTotal = (planQuota["five_hour"] as? NSNumber)?.doubleValue ?? 0
            weeklyTotal = (planQuota["weekly"] as? NSNumber)?.doubleValue ?? 0
        }

        // 3. Get usage percentages and reset times from usage
        var fiveHourPct: Double = 0
        var weeklyPct: Double = 0
        var fiveHourReset: Double = 0
        var weeklyReset: Double = 0
        if let usage = zeldaInnerData(results["zelda_usage"]) {
            fiveHourPct = (usage["per5HourPercentage"] as? NSNumber)?.doubleValue ?? 0
            weeklyPct = (usage["per1WeekPercentage"] as? NSNumber)?.doubleValue ?? 0
            fiveHourReset = (usage["per5HourResetTime"] as? NSNumber)?.doubleValue ?? 0
            weeklyReset = (usage["per1WeekResetTime"] as? NSNumber)?.doubleValue ?? 0
        }

        // If we got at least quota + usage data, build the result
        if fiveHourTotal > 0 || weeklyTotal > 0 {
            let usage = UsageData(
                per5HourTotal: fiveHourTotal,
                per5HourUsed: fiveHourTotal * fiveHourPct,
                per5HourRefreshTime: fiveHourReset,
                perWeekTotal: weeklyTotal,
                perWeekUsed: weeklyTotal * weeklyPct,
                perWeekRefreshTime: weeklyReset,
                perMonthTotal: 0,
                perMonthUsed: 0,
                perMonthRefreshTime: 0,
                planName: "Token Plan \(specCode.capitalized) (\(remainingDays)d left)",
                status: planStatus
            )
            applyUsage(usage)
            return
        }

        // Nothing worked - collect error info
        var errorParts: [String] = []
        for (name, data) in results.sorted(by: { $0.key < $1.key }) {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let code = json["code"] as? String ?? "?"
                let msg = json["message"] as? String ?? ""
                errorParts.append("\(name): code=\(code) \(msg)")
            }
        }
        lastError = errorParts.isEmpty ? "No data from any API" : errorParts.joined(separator: " | ")
        rebuildMenu()
        updateStatusBar()
    }

    private func applyUsage(_ usage: UsageData) {
        usageData = usage
        lastError = nil
        isLoggedIn = true
        updateStatusBar()
        rebuildMenu()
    }

    private func handleSessionExpired() {
        isLoggedIn = false
        lastError = "Session expired - please login again"
        clearSavedCookies()
        rebuildMenu()
        updateStatusBar()
    }

    // MARK: - Login

    @objc private func showLogin() {
        if let win = loginWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: config)
        webView.navigationDelegate = self
        loginWebView = webView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Qwen Cloud Login"
        window.contentView = webView
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        loginWindow = window

        guard let url = URL(string: Self.billingURL) else { return }
        webView.load(URLRequest(url: url))
    }

    private func closeLoginWindow() {
        loginWindow?.orderOut(nil)
        loginWindow = nil
        loginWebView = nil
    }

    @objc private func logout() {
        let cookieStore = WKWebsiteDataStore.default().httpCookieStore
        cookieStore.getAllCookies { cookies in
            for cookie in cookies where cookie.domain.contains("qwencloud.com") || cookie.domain.contains("qianwenai.com") {
                cookieStore.delete(cookie)
            }
        }
        clearSavedCookies()
        isLoggedIn = false
        usageData = nil
        lastError = nil
        updateStatusBar()
        rebuildMenu()
    }

    @objc private func openBillingPage() {
        guard let url = URL(string: Self.billingURL) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Session Restore

    private func tryRestoreSession() {
        let cookieStore = WKWebsiteDataStore.default().httpCookieStore
        cookieStore.getAllCookies { [weak self] cookies in
            let hasWKSession = cookies.contains {
                ($0.domain.contains("qwencloud.com") || $0.domain.contains("qianwenai.com"))
                && ($0.name.contains("login") || $0.name.contains("session") || $0.name.contains("token") || $0.name.contains("SSO") || $0.name.contains("cookie2"))
            }
            let hasSavedCookies = (try? String(contentsOfFile: Self.savedCookiePath, encoding: .utf8)).map { !$0.isEmpty } ?? false

            DispatchQueue.main.async {
                if hasWKSession || hasSavedCookies {
                    self?.isLoggedIn = true
                    self?.rebuildMenu()
                    self?.updateStatusBar()
                }
            }
        }
    }
}

// MARK: - WKNavigationDelegate

extension AppDelegate: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url?.absoluteString else { return }

        if url.contains("home.qwencloud.com") && !url.contains("login") && !url.contains("signin") && !url.contains("passport") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.isLoggedIn = true
                self?.lastError = nil
                self?.closeLoginWindow()
                self?.fetchUsage()
                self?.rebuildMenu()
                self?.updateStatusBar()
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {}
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {}
}

// MARK: - Main

@main
struct QwenUsageApp {
    static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
