import SwiftUI
import AppKit
import Security
import UserNotifications

// MARK: - OAuth config
let CLIENT_ID = "Ov23lip4576LQSrJsiv1"
let OAUTH_SCOPE = "notifications repo"
let REPO_SLUG = "anik-fahmid/GitPulse"

// MARK: - Keychain
enum Keychain {
    static let service = "com.wedevs.gitpulse"
    static let account = "github-token"
    static func save(_ token: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        var add = q; add[kSecValueData as String] = token.data(using: .utf8)!
        SecItemAdd(add as CFDictionary, nil)
    }
    static func load() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let d = item as? Data, let s = String(data: d, encoding: .utf8) else { return nil }
        return s
    }
    static func clear() {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}

// MARK: - GitHub
struct GitHub {
    static func req(_ urlStr: String, method: String = "GET", token: String, body: Data? = nil,
                    completion: @escaping (Data?, Int) -> Void) {
        guard let url = URL(string: urlStr) else { completion(nil, -1); return }
        var r = URLRequest(url: url); r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("GitPulse", forHTTPHeaderField: "User-Agent")
        if body != nil { r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        r.httpBody = body
        r.timeoutInterval = 30
        URLSession.shared.dataTask(with: r) { d, resp, _ in
            completion(d, (resp as? HTTPURLResponse)?.statusCode ?? -1)
        }.resume()
    }
    static func startDeviceFlow(completion: @escaping ([String: Any]?) -> Void) {
        post("https://github.com/login/device/code",
             form: "client_id=\(CLIENT_ID)&scope=\(OAUTH_SCOPE.replacingOccurrences(of: " ", with: "%20"))", completion: completion)
    }
    static func pollToken(deviceCode: String, completion: @escaping ([String: Any]?) -> Void) {
        post("https://github.com/login/oauth/access_token",
             form: "client_id=\(CLIENT_ID)&device_code=\(deviceCode)&grant_type=urn:ietf:params:oauth:grant-type:device_code", completion: completion)
    }
    private static func post(_ urlStr: String, form: String, completion: @escaping ([String: Any]?) -> Void) {
        var r = URLRequest(url: URL(string: urlStr)!); r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue("GitPulse", forHTTPHeaderField: "User-Agent")
        r.httpBody = form.data(using: .utf8)
        URLSession.shared.dataTask(with: r) { d, _, _ in
            completion(d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        }.resume()
    }
}

// MARK: - Model
struct Notif: Identifiable {
    let id: String, repo: String, type: String, reason: String
    let title: String, updated: String, commentURL: String, subjectURL: String, unread: Bool
}

let REASONS: [(value: String, label: String)] = [
    ("mention", "Mention (@you)"), ("team_mention", "Team mention"),
    ("review_requested", "Review requested"), ("assign", "Assigned"),
    ("author", "Authored threads"), ("comment", "New comments"),
    ("ci_activity", "CI activity"), ("state_change", "State change"),
    ("subscribed", "Subscribed activity"), ("manual", "Manually subscribed"),
    ("security_alert", "Security alerts"),
]
let DEFAULT_REASONS: Set<String> = ["mention", "team_mention", "review_requested", "assign"]

// Reminder interval choices (seconds). Realtime = 30 min min-gap.
let INTERVALS: [(label: String, seconds: Int)] = [
    ("Realtime (30 min)", 1800), ("Every 1 hour", 3600), ("Every 2 hours", 7200),
    ("Every 4 hours", 14400), ("Every 8 hours", 28800), ("Daily", 86400),
]

struct Config: Codable {
    var repos = ""; var reasons = Array(DEFAULT_REASONS); var unreadOnly = true
    var notify = false; var intervalSeconds = 1800
    var selectedRepos: [String] = []
}
func configURL() -> URL {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gh-notif-reviewer")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("config.json")
}
func loadConfig() -> Config { (try? JSONDecoder().decode(Config.self, from: Data(contentsOf: configURL()))) ?? Config() }
func saveConfig(_ c: Config) { if let d = try? JSONEncoder().encode(c) { try? d.write(to: configURL()) } }

// MARK: - App model (singleton, shared with AppDelegate)
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var token: String? = Keychain.load()
    @Published var login = ""
    @Published var rows: [Notif] = []
    @Published var unreadCount = 0
    @Published var status = "Ready"
    @Published var loading = false

    @Published var repos: String { didSet { persist() } }
    @Published var reasons: Set<String> { didSet { persist() } }
    @Published var unreadOnly: Bool { didSet { persist() } }
    @Published var notify: Bool { didSet { persist(); if notify { requestNotifAuth() }; reschedule() } }
    @Published var intervalSeconds: Int { didSet { persist(); reschedule() } }
    @Published var selectedRepos: Set<String> { didSet { persist() } }
    @Published var allRepos: [String] = []
    @Published var loadingRepos = false
    @Published var updateTag: String? = nil
    @Published var updateURL = "https://github.com/\(REPO_SLUG)/releases/latest"

    private var seen = Set<String>()
    private var seeded = false
    private var timer: Timer?
    // Locally marked-read items — suppressed even if the API still returns them briefly.
    private var readKeys = Set<String>()
    private func key(_ n: Notif) -> String { "\(n.id):\(n.updated)" }
    private func capSets() {
        if seen.count > 1000 { seen = Set(seen.suffix(1000)) }
        if readKeys.count > 1000 { readKeys = Set(readKeys.suffix(1000)) }
    }

    private init() {
        let c = loadConfig()
        repos = c.repos; reasons = Set(c.reasons); unreadOnly = c.unreadOnly
        notify = c.notify; intervalSeconds = c.intervalSeconds
        selectedRepos = Set(c.selectedRepos)
    }

    func persist() { saveConfig(Config(repos: repos, reasons: Array(reasons), unreadOnly: unreadOnly, notify: notify, intervalSeconds: intervalSeconds, selectedRepos: Array(selectedRepos))) }

    // Load all repositories the token can access (paginated).
    func fetchRepos() {
        guard let token = token else { return }
        loadingRepos = true; status = "Loading repositories…"
        var acc: [String] = []
        func page(_ p: Int) {
            GitHub.req("https://api.github.com/user/repos?per_page=100&page=\(p)&affiliation=owner,collaborator,organization_member&sort=full_name", token: token) { d, code in
                var names: [String] = []
                if code == 200, let d = d, let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] {
                    names = arr.compactMap { $0["full_name"] as? String }
                }
                acc.append(contentsOf: names)
                if code == 200 && names.count == 100 && p < 30 { page(p + 1) }
                else {
                    DispatchQueue.main.async {
                        self.allRepos = Array(Set(acc)).sorted { $0.lowercased() < $1.lowercased() }
                        self.loadingRepos = false
                        self.status = "Loaded \(self.allRepos.count) repositories"
                    }
                }
            }
        }
        page(1)
    }

    // ---- auth ----
    func signOut() { Keychain.clear(); token = nil; login = ""; rows = []; unreadCount = 0; seen = []; seeded = false }
    func setToken(_ t: String) { Keychain.save(t); token = t; fetchUser(); refresh(triggerNotify: false) }
    func signInWithToken(_ t: String, completion: @escaping (Bool, String) -> Void) {
        GitHub.req("https://api.github.com/user", token: t) { d, code in
            let j = d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async {
                if code == 200, let name = j?["login"] as? String {
                    Keychain.save(t); self.token = t; self.login = name
                    self.refresh(triggerNotify: false); completion(true, name)
                } else { completion(false, "Invalid token (HTTP \(code)). Needs scopes: notifications, repo.") }
            }
        }
    }
    func fetchUser() {
        guard let t = token else { return }
        GitHub.req("https://api.github.com/user", token: t) { d, _ in
            let j = d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async { self.login = (j?["login"] as? String) ?? "" }
        }
    }

    // ---- notifications auth ----
    func requestNotifAuth() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // ---- polling ----
    func bootstrap() {
        guard token != nil else { return }
        fetchUser(); refresh(triggerNotify: false); reschedule(); checkForUpdates()
    }

    // ---- update check (lightweight, via GitHub Releases) ----
    func currentVersion() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }
    private func versionIsNewer(_ tag: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.lowercased().replacingOccurrences(of: "v", with: "")
                .split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(tag), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
    func checkForUpdates(manual: Bool = false) {
        let api = "https://api.github.com/repos/\(REPO_SLUG)/releases/latest"
        let handle: (Data?, Int) -> Void = { d, code in
            guard code == 200, let d = d,
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let tag = j["tag_name"] as? String else {
                if manual { DispatchQueue.main.async { self.status = "Update check failed" } }
                return
            }
            let page = (j["html_url"] as? String) ?? self.updateURL
            DispatchQueue.main.async {
                if self.versionIsNewer(tag, than: self.currentVersion()) {
                    self.updateTag = tag; self.updateURL = page
                    if manual { self.status = "Update available: \(tag)" }
                } else {
                    self.updateTag = nil
                    if manual { self.status = "You're on the latest (\(self.currentVersion()))" }
                }
            }
        }
        if let t = token { GitHub.req(api, token: t, completion: handle) }
        else {
            var r = URLRequest(url: URL(string: api)!)
            r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            r.setValue("GitPulse", forHTTPHeaderField: "User-Agent")
            URLSession.shared.dataTask(with: r) { d, resp, _ in
                handle(d, (resp as? HTTPURLResponse)?.statusCode ?? -1)
            }.resume()
        }
    }
    func openUpdate() { if let u = URL(string: updateURL) { NSWorkspace.shared.open(u) } }
    func reschedule() {
        timer?.invalidate(); timer = nil
        guard token != nil else { return }
        let secs = max(1800, intervalSeconds)   // enforce 30-min minimum gap
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(secs), repeats: true) { [weak self] _ in
            self?.refresh(triggerNotify: true)
        }
    }

    private func matches(_ n: Notif) -> Bool {
        if !reasons.isEmpty && !reasons.contains(n.reason) { return false }
        // Checked repos take priority (exact match). Empty = all repos.
        if !selectedRepos.isEmpty { return selectedRepos.contains(n.repo) }
        // Fallback: optional free-text substring filter.
        let filter = repos.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        if !filter.isEmpty && !filter.contains(where: { n.repo.lowercased().contains($0) }) { return false }
        return true
    }

    func refresh(triggerNotify: Bool) {
        guard let token = token else { return }
        DispatchQueue.main.async { self.loading = true; self.status = "Fetching…" }
        // Always fetch UNREAD only — this app reviews unread notifications.
        GitHub.req("https://api.github.com/notifications?all=false&per_page=50", token: token) { d, code in
            var parsed: [Notif] = []
            if code == 200, let d = d, let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] {
                for n in arr {
                    let subj = n["subject"] as? [String: Any] ?? [:]
                    parsed.append(Notif(
                        id: n["id"] as? String ?? UUID().uuidString,
                        repo: (n["repository"] as? [String: Any])?["full_name"] as? String ?? "",
                        type: subj["type"] as? String ?? "", reason: n["reason"] as? String ?? "",
                        title: subj["title"] as? String ?? "",
                        updated: (n["updated_at"] as? String ?? "").replacingOccurrences(of: "T", with: " ").replacingOccurrences(of: "Z", with: ""),
                        commentURL: subj["latest_comment_url"] as? String ?? "",
                        subjectURL: subj["url"] as? String ?? "",
                        unread: (n["unread"] as? Bool) ?? true))
                }
            }
            DispatchQueue.main.async {
                self.loading = false
                if code == 401 { self.signOut(); self.status = "Signed out (token invalid)"; return }
                if code != 200 { self.status = "API error \(code)"; return }
                let matching = parsed.filter { self.matches($0) && !self.readKeys.contains(self.key($0)) }
                self.rows = matching
                self.unreadCount = matching.filter { $0.unread }.count
                self.status = "\(matching.count) shown · \(self.unreadCount) unread"
                self.updateBadge()

                // Dedup by id+updated so NEW activity on a known thread still alerts.
                let newUnread = matching.filter { $0.unread && !self.seen.contains(self.key($0)) }
                if !self.seeded {
                    self.seen.formUnion(matching.map { self.key($0) }); self.seeded = true; self.capSets(); return
                }
                self.seen.formUnion(newUnread.map { self.key($0) })
                self.capSets()
                if triggerNotify && self.notify {
                    for n in newUnread { self.postNotification(for: n) }
                }
            }
        }
    }

    func updateBadge() {
        NSApp.dockTile.badgeLabel = unreadCount > 0 ? "\(unreadCount)" : ""
    }

    // ---- desktop notifications ----
    func postNotification(for n: Notif) {
        resolveURL(n) { url in
            let c = UNMutableNotificationContent()
            c.title = "GitHub: \(n.reason) · \(n.repo)"
            c.body = n.title
            c.sound = .default
            c.userInfo = ["url": url]
            let req = UNNotificationRequest(identifier: "gp-\(n.id)", content: c, trigger: nil)
            UNUserNotificationCenter.current().add(req)
        }
    }
    func testNotification() {
        requestNotifAuth()
        let c = UNMutableNotificationContent()
        c.title = "GitPulse test"
        c.body = "Notifications work. Click to open GitHub."
        c.sound = .default
        c.userInfo = ["url": "https://github.com/notifications"]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "gp-test-\(UUID().uuidString)", content: c, trigger: nil))
    }

    func resolveURL(_ n: Notif, completion: @escaping (String) -> Void) {
        let api = n.commentURL.isEmpty ? n.subjectURL : n.commentURL
        let fallback = "https://github.com/\(n.repo)"
        guard !api.isEmpty, let token = token else { completion(fallback); return }
        GitHub.req(api, token: token) { d, _ in
            let j = d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            completion((j?["html_url"] as? String) ?? fallback)
        }
    }
    func open(_ id: Notif.ID) {
        guard let n = rows.first(where: { $0.id == id }) else { return }
        resolveURL(n) { url in DispatchQueue.main.async { if let u = URL(string: url) { NSWorkspace.shared.open(u) } } }
    }
    func markAllRead() {
        guard let token = token else { return }
        // Optimistic: clear + suppress immediately (no spinner, no reappearance).
        let cleared = rows
        for r in rows { readKeys.insert(key(r)) }
        rows = []; unreadCount = 0; updateBadge(); status = "Marking all read…"
        let body = try? JSONSerialization.data(withJSONObject: ["read": true])
        GitHub.req("https://api.github.com/notifications", method: "PUT", token: token, body: body) { _, code in
            DispatchQueue.main.async {
                if (200...205).contains(code) {
                    self.status = "All marked read"
                } else {
                    // Roll back on failure.
                    for r in cleared { self.readKeys.remove(self.key(r)) }
                    self.rows = cleared
                    self.unreadCount = cleared.filter { $0.unread }.count
                    self.updateBadge()
                    if code == 401 { self.signOut(); self.status = "Signed out (token invalid)" }
                    else { self.status = "Mark all read failed (\(code))" }
                }
            }
        }
    }

    // Mark a single notification thread as read (optimistic + suppression).
    func markThreadRead(_ id: Notif.ID) {
        guard let token = token else { return }
        let removed = rows.first { $0.id == id }
        if let r = removed { readKeys.insert(key(r)) }
        rows.removeAll { $0.id == id }
        unreadCount = rows.filter { $0.unread }.count
        updateBadge()
        GitHub.req("https://api.github.com/notifications/threads/\(id)", method: "PATCH", token: token) { _, code in
            DispatchQueue.main.async {
                if (200...205).contains(code) {
                    self.status = "Marked read"
                } else if let r = removed {
                    // Roll back.
                    self.readKeys.remove(self.key(r))
                    self.rows.insert(r, at: 0)
                    self.unreadCount = self.rows.filter { $0.unread }.count
                    self.updateBadge()
                    if code == 401 { self.signOut(); self.status = "Signed out (token invalid)" }
                    else { self.status = "Mark read failed (\(code))" }
                }
            }
        }
    }
}


// MARK: - Login view
struct LoginView: View {
    @EnvironmentObject var model: AppModel
    @State private var userCode = ""
    @State private var verifyURL = "https://github.com/login/device"
    @State private var status = ""
    @State private var busy = false
    @State private var pollTimer: Timer?
    @State private var pat = ""

    var body: some View {
        VStack(spacing: 16) {
            brandMark(size: 44, corner: 20)
            Text("GitPulse").font(.system(size: 26, weight: .bold))
            Text("Sign in with GitHub to review your notifications.").foregroundStyle(.secondary)

            if userCode.isEmpty {
                Button(action: start) {
                    Label("Sign in with GitHub", systemImage: "person.badge.key.fill").padding(.horizontal, 8).padding(.vertical, 4)
                }.buttonStyle(.borderedProminent).controlSize(.large).disabled(busy)
            } else {
                VStack(spacing: 6) {
                    Text("Enter this code on GitHub:").font(.subheadline).foregroundStyle(.secondary)
                    Text(userCode).font(.system(size: 30, weight: .bold, design: .monospaced)).textSelection(.enabled)
                    Button("Open GitHub") { if let u = URL(string: verifyURL) { NSWorkspace.shared.open(u) } }
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Waiting for approval…").font(.caption) }
                }
            }
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.red) }

            Divider().padding(.vertical, 4)
            VStack(spacing: 6) {
                Text("Or paste a Personal Access Token").font(.subheadline).foregroundStyle(.secondary)
                Text("Required for org-private repos (e.g. weDevsOfficial/wpuf-pro).").font(.caption2).foregroundStyle(.tertiary)
                HStack {
                    SecureField("ghp_…", text: $pat).textFieldStyle(.roundedBorder)
                    Button("Use token") {
                        let t = pat.trimmingCharacters(in: .whitespacesAndNewlines); guard !t.isEmpty else { return }
                        busy = true; status = ""
                        model.signInWithToken(t) { ok, msg in busy = false; if !ok { status = msg } }
                    }.disabled(busy || pat.isEmpty)
                }
                Link("Create a token (scopes: notifications, repo)",
                     destination: URL(string: "https://github.com/settings/tokens/new?scopes=notifications,repo&description=GitPulse")!).font(.caption2)
            }
            Button { NSApp.terminate(nil) } label: { Label("Quit", systemImage: "power") }
                .keyboardShortcut("q").font(.caption)
        }
        .padding(40).frame(minWidth: 470, minHeight: 540)
    }
    func start() {
        busy = true; status = ""
        GitHub.startDeviceFlow { j in
            DispatchQueue.main.async {
                busy = false
                guard let j = j, let code = j["user_code"] as? String, let dev = j["device_code"] as? String else {
                    status = "Could not start sign-in. Check network."; return
                }
                userCode = code; verifyURL = (j["verification_uri"] as? String) ?? verifyURL
                if let u = URL(string: verifyURL) { NSWorkspace.shared.open(u) }
                let interval = (j["interval"] as? Int) ?? 5
                pollTimer = Timer.scheduledTimer(withTimeInterval: Double(interval) + 1, repeats: true) { _ in
                    GitHub.pollToken(deviceCode: dev) { r in
                        DispatchQueue.main.async {
                            if let tok = r?["access_token"] as? String { pollTimer?.invalidate(); model.setToken(tok) }
                            else if let err = r?["error"] as? String, err != "authorization_pending", err != "slow_down" {
                                pollTimer?.invalidate(); status = "Sign-in failed: \(err)"; userCode = ""
                            }
                        }
                    }
                }
            }
        }
    }
}

@ViewBuilder
func brandMark(size: CGFloat, corner: CGFloat) -> some View {
    Image(systemName: "bell.badge.fill").font(.system(size: size)).foregroundStyle(.white, .red)
        .padding(size * 0.36)
        .background(LinearGradient(colors: [Color(red: 0.36, green: 0.33, blue: 0.93), Color(red: 0.55, green: 0.36, blue: 0.96)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: corner))
}


// MARK: - Settings modal
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var repoSearch = ""
    let cols = [GridItem(.adaptive(minimum: 180), spacing: 8)]
    var filteredRepos: [String] {
        repoSearch.isEmpty ? model.allRepos
            : model.allRepos.filter { $0.localizedCaseInsensitiveContains(repoSearch) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Settings").font(.title3.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }

            // Alerts
            Toggle("Enable notifications", isOn: $model.notify).toggleStyle(.switch)
            HStack {
                Text("Reminder").foregroundStyle(.secondary)
                Picker("", selection: $model.intervalSeconds) {
                    ForEach(INTERVALS, id: \.seconds) { Text($0.label).tag($0.seconds) }
                }.labelsHidden().frame(width: 190).disabled(!model.notify)
                Button("Test") { model.testNotification() }
            }.font(.callout)

            Divider()
            Text("Notification types (drives badge + alerts)").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: cols, alignment: .leading, spacing: 4) {
                ForEach(REASONS, id: \.value) { r in
                    Toggle(isOn: Binding(
                        get: { model.reasons.contains(r.value) },
                        set: { on in if on { model.reasons.insert(r.value) } else { model.reasons.remove(r.value) } }
                    )) { Text(r.label).font(.callout) }.toggleStyle(.checkbox)
                }
            }

            Divider()
            HStack {
                Text("Repositories — \(model.selectedRepos.isEmpty ? "all" : "\(model.selectedRepos.count) selected")")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(model.loadingRepos ? "Loading…" : "Load repos") { model.fetchRepos() }.disabled(model.loadingRepos)
            }
            TextField("Search repositories…", text: $repoSearch).textFieldStyle(.roundedBorder)
            if !model.allRepos.isEmpty {
                HStack(spacing: 10) {
                    Button("Select all shown") { for r in filteredRepos { model.selectedRepos.insert(r) } }
                    Button("Clear") { model.selectedRepos.removeAll() }
                    Spacer()
                    Text("\(filteredRepos.count) shown").foregroundStyle(.secondary)
                }.font(.caption)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(filteredRepos, id: \.self) { repo in
                            Toggle(isOn: Binding(
                                get: { model.selectedRepos.contains(repo) },
                                set: { on in if on { model.selectedRepos.insert(repo) } else { model.selectedRepos.remove(repo) } }
                            )) { Text(repo).font(.callout) }.toggleStyle(.checkbox)
                        }
                    }.padding(6)
                }
                .frame(height: 150)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.textBackgroundColor)))
            } else {
                Text("Click “Load repos” to list every repository you can access, then check the ones to watch.")
                    .font(.caption).foregroundStyle(.tertiary)
            }

            Divider()
            HStack {
                Button("Check for updates") { model.checkForUpdates(manual: true) }
                if let tag = model.updateTag {
                    Button { model.openUpdate() } label: { Text("Get \(tag)") }.tint(.green)
                }
                Spacer()
                Text("v\(model.currentVersion())").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(role: .destructive) { model.signOut(); dismiss() } label: { Text("Sign out") }
                Spacer()
                Text(model.login.isEmpty ? "" : "@\(model.login)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16).frame(width: 470, height: 680)
    }
}

// MARK: - Panel (the whole app, in a menu-bar window)
struct PanelView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "settings")
    }

    var body: some View {
        Group {
            if model.token == nil { LoginView() } else { main }
        }
    }

    var main: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                brandMark(size: 16, corner: 8)
                VStack(alignment: .leading, spacing: 0) {
                    Text("GitPulse").font(.headline)
                    if !model.login.isEmpty { Text("@\(model.login)").font(.caption2).foregroundStyle(.secondary) }
                }
                Spacer()
                Text("\(model.unreadCount)").font(.headline)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(model.unreadCount > 0 ? Color.red.opacity(0.18) : Color.gray.opacity(0.15))
                    .clipShape(Capsule())
                Button { openSettings() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless).help("Settings")
            }

            if let tag = model.updateTag {
                Button { model.openUpdate() } label: {
                    Label("Update available → \(tag)", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.green).controlSize(.small)
            }

            HStack(spacing: 8) {
                Button { model.refresh(triggerNotify: false) } label: { Label("Fetch", systemImage: "arrow.clockwise") }
                Button("Mark all read") { model.markAllRead() }
                if model.loading { ProgressView().controlSize(.small) }
                Spacer()
                Button { NSApp.terminate(nil) } label: { Label("Quit", systemImage: "power") }
                    .help("Quit GitPulse").keyboardShortcut("q")
            }.font(.callout)

            if model.rows.isEmpty {
                Text(model.loading ? "Loading…" : "Nothing matching your filters.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.rows) { r in row(r); Divider() }
                    }
                }
                .frame(height: 360)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.textBackgroundColor)))
            }

            Text(model.status).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(12).frame(width: 440)
        .onAppear { if model.login.isEmpty { model.fetchUser() } }
    }

    func row(_ r: Notif) -> some View {
        HStack(spacing: 8) {
            Circle().fill(r.unread ? Color.accentColor : Color.clear).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title).font(.callout).lineLimit(2)
                Text("\(r.repo) · \(r.reason)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { model.markThreadRead(r.id) } label: { Image(systemName: "checkmark.circle") }
                .buttonStyle(.borderless).help("Mark as read")
            Button { model.open(r.id) } label: { Image(systemName: "arrow.up.right.square") }
                .buttonStyle(.borderless).help("Open on GitHub")
        }
        .padding(.vertical, 6).padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.open(r.id) }
        .simultaneousGesture(TapGesture().modifiers(.command).onEnded { model.open(r.id) })
        .contextMenu {
            Button("Open on GitHub") { model.open(r.id) }
            Button("Mark as read") { model.markThreadRead(r.id) }
        }
    }
}

// MARK: - App delegate
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)   // never in the Dock
        UNUserNotificationCenter.current().delegate = self
        AppModel.shared.requestNotifAuth()
        AppModel.shared.bootstrap()
    }
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler h: @escaping (UNNotificationPresentationOptions) -> Void) {
        h([.banner, .sound])
    }
    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse,
                                withCompletionHandler h: @escaping () -> Void) {
        if let s = r.notification.request.content.userInfo["url"] as? String, let u = URL(string: s) {
            NSWorkspace.shared.open(u)
        }
        h()
    }
}

// MARK: - App
@main
struct GitPulseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject var model = AppModel.shared
    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(model)
        } label: {
            if model.unreadCount > 0 {
                Label("\(model.unreadCount)", systemImage: "bell.badge.fill")
            } else {
                Image(systemName: "bell")
            }
        }
        .menuBarExtraStyle(.window)

        Window("GitPulse Settings", id: "settings") {
            SettingsView().environmentObject(model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
