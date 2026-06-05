import SwiftUI
import AppKit
import Security
import UserNotifications

// MARK: - OAuth config
let CLIENT_ID = "Ov23lip4576LQSrJsiv1"
let OAUTH_SCOPE = "notifications repo"

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
        r.httpBody = body
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

    private var seen = Set<String>()
    private var seeded = false
    private var timer: Timer?

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
        fetchUser(); refresh(triggerNotify: false); reschedule()
    }
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
        let allFlag = unreadOnly ? "false" : "true"
        GitHub.req("https://api.github.com/notifications?all=\(allFlag)&per_page=50", token: token) { d, code in
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
                let matching = parsed.filter { self.matches($0) }
                self.rows = matching
                self.unreadCount = matching.filter { $0.unread }.count
                self.status = "\(matching.count) shown · \(self.unreadCount) unread"
                self.updateBadge()

                let newUnread = matching.filter { $0.unread && !self.seen.contains($0.id) }
                if !self.seeded {
                    self.seen.formUnion(matching.map { $0.id }); self.seeded = true; return
                }
                self.seen.formUnion(newUnread.map { $0.id })
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
        let a = NSAlert(); a.messageText = "Mark all notifications as read?"
        a.informativeText = "Marks ALL your GitHub notifications as read."
        a.addButton(withTitle: "Mark all read"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let body = try? JSONSerialization.data(withJSONObject: ["read": true])
        GitHub.req("https://api.github.com/notifications", method: "PUT", token: token, body: body) { _, _ in
            DispatchQueue.main.async { self.status = "All marked read"; self.refresh(triggerNotify: false) }
        }
    }
}

// MARK: - App delegate (notification handling)
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        UNUserNotificationCenter.current().delegate = self
        AppModel.shared.requestNotifAuth()
        AppModel.shared.bootstrap()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
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

// MARK: - Main view
struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: Notif.ID?
    @State private var repoExpanded = false
    @State private var repoSearch = ""
    let cols = [GridItem(.adaptive(minimum: 200), spacing: 8)]

    var filteredRepos: [String] {
        repoSearch.isEmpty ? model.allRepos
            : model.allRepos.filter { $0.localizedCaseInsensitiveContains(repoSearch) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                brandMark(size: 26, corner: 12)
                VStack(alignment: .leading, spacing: 0) {
                    Text("GitPulse").font(.system(size: 22, weight: .bold))
                    Text(model.login.isEmpty ? "Review your GitHub notifications" : "Signed in as @\(model.login)")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(model.unreadCount) unread").font(.headline)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(model.unreadCount > 0 ? Color.red.opacity(0.15) : Color.gray.opacity(0.12))
                    .clipShape(Capsule())
                Button("Sign out") { model.signOut() }
            }

            DisclosureGroup(isExpanded: $repoExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("Search repositories…", text: $repoSearch).textFieldStyle(.roundedBorder)
                        Button(model.loadingRepos ? "Loading…" : "Load repos") { model.fetchRepos() }
                            .disabled(model.loadingRepos)
                    }
                    if !model.allRepos.isEmpty {
                        HStack(spacing: 10) {
                            Button("Select all shown") { for r in filteredRepos { model.selectedRepos.insert(r) } }
                            Button("Clear") { model.selectedRepos.removeAll() }
                            Spacer()
                            Text("\(model.selectedRepos.count) selected · \(filteredRepos.count) shown")
                                .foregroundStyle(.secondary)
                        }.font(.caption)
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 1) {
                                ForEach(filteredRepos, id: \.self) { repo in
                                    Toggle(isOn: Binding(
                                        get: { model.selectedRepos.contains(repo) },
                                        set: { on in if on { model.selectedRepos.insert(repo) } else { model.selectedRepos.remove(repo) } }
                                    )) { Text(repo).font(.callout) }
                                    .toggleStyle(.checkbox)
                                }
                            }.padding(6)
                        }
                        .frame(height: 150)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.textBackgroundColor)))
                    } else {
                        Text("Click “Load repos” to list every repository you can access, then check the ones to watch.")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }.padding(.top, 4)
            } label: {
                Text("Repositories — \(model.selectedRepos.isEmpty ? "all" : "\(model.selectedRepos.count) selected")")
                    .font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Notification types (drives badge + alerts)").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: cols, alignment: .leading, spacing: 6) {
                    ForEach(REASONS, id: \.value) { r in
                        Toggle(isOn: Binding(get: { model.reasons.contains(r.value) },
                                             set: { on in if on { model.reasons.insert(r.value) } else { model.reasons.remove(r.value) } })) {
                            Text(r.label)
                        }.toggleStyle(.checkbox)
                    }
                }
            }

            // Alerts row
            HStack(spacing: 14) {
                Toggle("Enable notifications", isOn: $model.notify).toggleStyle(.switch)
                Picker("Reminder", selection: $model.intervalSeconds) {
                    ForEach(INTERVALS, id: \.seconds) { Text($0.label).tag($0.seconds) }
                }.frame(width: 220).disabled(!model.notify)
                Button("Test notification") { model.testNotification() }
                Spacer()
            }

            HStack {
                Toggle("Unread only", isOn: $model.unreadOnly).toggleStyle(.checkbox)
                Button(action: { model.refresh(triggerNotify: false) }) { Label("Fetch", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r").disabled(model.loading)
                Button("Mark all read") { model.markAllRead() }
                if model.loading { ProgressView().controlSize(.small) }
                Spacer()
                Text(model.status).font(.caption).foregroundStyle(.secondary)
            }

            // Results (List with Cmd+click + double-click to open)
            ScrollView {
                LazyVStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text("Repository").frame(width: 200, alignment: .leading)
                        Text("Type").frame(width: 60, alignment: .leading)
                        Text("Reason").frame(width: 130, alignment: .leading)
                        Text("Title").frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.caption.bold()).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 4)
                    Divider()
                    ForEach(model.rows) { r in
                        HStack(spacing: 8) {
                            Text(r.repo).frame(width: 200, alignment: .leading).lineLimit(1)
                            Text(r.type).frame(width: 60, alignment: .leading).foregroundStyle(.secondary)
                            Text(r.reason).frame(width: 130, alignment: .leading).foregroundStyle(.secondary)
                            Text(r.title).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                            if r.unread { Circle().fill(Color.accentColor).frame(width: 7, height: 7) }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(selection == r.id ? Color.accentColor.opacity(0.15) : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { model.open(r.id) }
                        .onTapGesture { selection = r.id }
                        .simultaneousGesture(TapGesture().modifiers(.command).onEnded { model.open(r.id) })
                        .contextMenu { Button("Open on GitHub") { model.open(r.id) } }
                        Divider()
                    }
                }
            }
            .frame(minHeight: 200)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.textBackgroundColor)))

            Text("Double-click or ⌘-click a row to open it on GitHub.").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(18).frame(minWidth: 760, minHeight: 620)
        .onAppear { if model.login.isEmpty { model.fetchUser() } }
    }
}

// MARK: - Menu bar content
struct MenuContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.login.isEmpty ? "GitPulse" : "GitPulse · @\(model.login)")
        Text("\(model.unreadCount) unread (selected types)")
        Divider()
        Button("Open GitPulse window") {
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Open GitHub notifications") { NSWorkspace.shared.open(URL(string: "https://github.com/notifications")!) }
        Button("Fetch now") { model.refresh(triggerNotify: false) }
        Button("Test notification") { model.testNotification() }
        Divider()
        Button("Quit GitPulse") { NSApp.terminate(nil) }
    }
}

// MARK: - Root + App
struct RootView: View {
    @EnvironmentObject var model: AppModel
    var body: some View { Group { if model.token == nil { LoginView() } else { ContentView() } } }
}

@main
struct GitPulseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject var model = AppModel.shared
    var body: some Scene {
        WindowGroup("GitPulse", id: "main") { RootView().environmentObject(model) }
            .defaultSize(width: 880, height: 660)
        MenuBarExtra {
            MenuContent().environmentObject(model)
        } label: {
            // bell + unread count in the menu bar
            if model.unreadCount > 0 {
                Label("\(model.unreadCount)", systemImage: "bell.badge.fill")
            } else {
                Image(systemName: "bell")
            }
        }
    }
}
