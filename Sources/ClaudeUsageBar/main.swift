import AppKit
import Security
import ServiceManagement

// MARK: - API types

struct Bucket: Decodable {
    let utilization: Double?
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

struct Usage: Decodable {
    let fiveHour: Bucket?
    let sevenDay: Bucket?
    let sevenDayOpus: Bucket?
    let sevenDaySonnet: Bucket?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
    }

    var buckets: [(label: String, bucket: Bucket)] {
        let all: [(String, Bucket?)] = [
            ("Session (5h)", fiveHour),
            ("Week (all)", sevenDay),
            ("Week (Opus)", sevenDayOpus),
            ("Week (Sonnet)", sevenDaySonnet),
        ]
        return all.compactMap { label, b in
            guard let b, b.utilization != nil else { return nil }
            return (label, b)
        }
    }
}

enum FetchError: Error, CustomStringConvertible {
    case keychain(OSStatus)
    case credentialFormat
    case http(Int)
    case network(String)

    var description: String {
        switch self {
        case .keychain(let s): return "Keychain read failed (\(s))"
        case .credentialFormat: return "Unexpected credential format"
        case .http(401): return "Token stale — open Claude Code to refresh"
        case .http(let code): return "HTTP \(code)"
        case .network(let m): return m
        }
    }
}

// MARK: - Credentials + fetch

func readAccessToken() throws -> String {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "Claude Code-credentials",
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else {
        throw FetchError.keychain(status)
    }
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = obj["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String
    else {
        throw FetchError.credentialFormat
    }
    return token
}

func fetchUsage(completion: @escaping (Result<Usage, FetchError>) -> Void) {
    let token: String
    do {
        token = try readAccessToken()
    } catch let e as FetchError {
        completion(.failure(e))
        return
    } catch {
        completion(.failure(.network(error.localizedDescription)))
        return
    }

    var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

    URLSession.shared.dataTask(with: req) { data, resp, err in
        if let err {
            completion(.failure(.network(err.localizedDescription)))
            return
        }
        guard let http = resp as? HTTPURLResponse else {
            completion(.failure(.network("No response")))
            return
        }
        guard http.statusCode == 200 else {
            completion(.failure(.http(http.statusCode)))
            return
        }
        guard let data, let usage = try? JSONDecoder().decode(Usage.self, from: data) else {
            completion(.failure(.network("Could not parse response")))
            return
        }
        completion(.success(usage))
    }.resume()
}

// MARK: - Formatting

// The API returns 6-digit fractional seconds, which ISO8601DateFormatter can't parse.
func parseISO(_ s: String) -> Date? {
    let cleaned = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: cleaned)
}

func resetText(_ iso: String?) -> String {
    guard let iso, let date = parseISO(iso) else { return "" }
    let fmt = DateFormatter()
    if Calendar.current.isDateInToday(date) {
        fmt.dateStyle = .none
        fmt.timeStyle = .short
    } else {
        fmt.setLocalizedDateFormatFromTemplate("EEE j")
    }
    return "  ·  resets \(fmt.string(from: date))"
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var usage: Usage?
    private var lastFetch: Date?
    private var lastError: FetchError?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "CC …"
        rebuildMenu()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer?.tolerance = 30
    }

    @objc func refresh() {
        fetchUsage { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let usage):
                    self.usage = usage
                    self.lastFetch = Date()
                    self.lastError = nil
                case .failure(let e):
                    self.lastError = e
                }
                self.updateTitle()
                self.rebuildMenu()
            }
        }
    }

    private func updateTitle() {
        guard let maxUtil = usage?.buckets.compactMap({ $0.bucket.utilization }).max() else {
            statusItem.button?.title = "CC –"
            return
        }
        let pct = Int(maxUtil.rounded())
        statusItem.button?.title = pct >= 80 ? "CC ⚠️ \(pct)%" : "CC \(pct)%"
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        if let usage {
            for (label, bucket) in usage.buckets {
                let pct = Int((bucket.utilization ?? 0).rounded())
                let item = NSMenuItem(title: "\(label):  \(pct)%\(resetText(bucket.resetsAt))", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        if let lastError {
            let item = NSMenuItem(title: "\(lastError)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            if let lastFetch {
                let fmt = DateFormatter()
                fmt.timeStyle = .short
                let stale = NSMenuItem(title: "Showing data from \(fmt.string(from: lastFetch))", action: nil, keyEquivalent: "")
                stale.isEnabled = false
                menu.addItem(stale)
            }
        }

        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "Refresh now", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let loginItem = NSMenuItem(title: "Launch at login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc func toggleLaunchAtLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled {
                try svc.unregister()
            } else {
                try svc.register()
            }
        } catch {
            NSLog("Launch at login toggle failed: \(error)")
        }
        rebuildMenu()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
