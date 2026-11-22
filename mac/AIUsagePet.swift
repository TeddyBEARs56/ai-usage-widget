// AI 사용량 창 — Claude·ChatGPT(Codex) 사용 한도를 화면 위에 계속 띄워 두는 작은 창
//
// 값의 출처
//   Claude  : Claude Code 상태 표시줄이 세션마다 남기는 ~/.cache/ai-usage/claude/<세션>.json
//             (이 앱을 `AIUsagePet --statusline` 으로 상태 표시줄에 걸거나, 직접 만든 statusline.sh 에서 같은 파일을 남긴다)
//             + Claude 데스크톱 앱이 남기는 plan-usage-history.json(초기화 시각 없음). 둘 중 나중 값을 쓴다
//             (Claude Code 로그인 토큰은 읽지 않는다)
//   ChatGPT : `codex app-server` 의 account/rateLimits/read(5분마다) + ~/.codex/sessions 기록에 찍히는 최신 한도
//   세션    : Claude Code 가 실행 중인 세션마다 남기는 ~/.claude/sessions/<pid>.json(+ 대화 기록 끝),
//             Codex 의 ~/.codex/sessions rollout 기록 마지막 표시(+ 그 파일을 연 codex 프로세스가 있는지), 3초마다
//
// 실행 옵션: --print (값만 출력), --snapshot <png> (창 모양을 그림으로 저장), --connect (Claude Code 상태 표시줄에 연결),
//           --statusline (Claude Code 상태 표시줄: 한도를 남기고 상태 표시줄 글자를 낸다),
//           --version, --check-update (올라온 새 판 보기), --update (새 판으로 바꾸기)
//
// 자동 업데이트: 켠 뒤 1분, 그 뒤 6시간마다 GitHub Releases 의 mac-v<버전> 을 보고 높으면 받아 바꾼 뒤 다시 띄운다(Updater)

import AppKit
import CryptoKit
import ServiceManagement
import SwiftUI
import UserNotifications

/// 홈 폴더. 시험할 때는 AIUSAGE_HOME 으로 바꾼다(윈도우 판과 같다)
let homeDir: String = {
    if let home = ProcessInfo.processInfo.environment["AIUSAGE_HOME"], !home.isEmpty { return home }
    return NSHomeDirectory()
}()

// MARK: - 언어

/// 화면 글자의 언어. 처음엔 시스템 언어(선호 언어 목록에서 한국어·영어·일본어·중국어 가운데 먼저 나오는 것, 없으면 영어)를 따르고,
/// 메뉴 「언어」로 고르면 기억한다(앱 설정 language). 상태 표시줄(--statusline)도 같은 설정을 본다.
/// 번역은 앱 안 Resources/strings.json(저장소 i18n/strings.json, 윈도우 판과 같은 파일): 한국어 문장이 열쇠, {0} {1} 은 끼워 넣을 값.
/// 시험: AIUSAGE_LANG=en 으로 언어를, AIUSAGE_STRINGS=<경로> 로 번역 파일을 정한다.
enum L10n {
    static let codes = ["ko", "en", "ja", "zh-Hans"]
    static let nativeNames = ["ko": "한국어", "en": "English", "ja": "日本語", "zh-Hans": "简体中文"]
    static let key = "language"
    private static let lock = NSLock()
    private static var resolved: String?

    /// 고른 값: "auto"(시스템 언어) 또는 언어 코드
    static var choice: String {
        if let forced = ProcessInfo.processInfo.environment["AIUSAGE_LANG"], codes.contains(forced) { return forced }
        let saved = UserDefaults.standard.string(forKey: key) ?? "auto"
        return codes.contains(saved) ? saved : "auto"
    }

    static var current: String {
        lock.lock()
        defer { lock.unlock() }
        if let resolved { return resolved }
        let value = choice == "auto" ? system : choice
        resolved = value
        return value
    }

    static func choose(_ value: String) {
        UserDefaults.standard.set(value, forKey: key)
        lock.lock()
        resolved = nil
        lock.unlock()
    }

    static var system: String {
        for id in Locale.preferredLanguages.map({ $0.lowercased() }) {
            if id.hasPrefix("ko") { return "ko" }
            if id.hasPrefix("ja") { return "ja" }
            if id.hasPrefix("zh") { return "zh-Hans" }
            if id.hasPrefix("en") { return "en" }
        }
        return "en"
    }

    static var locale: Locale {
        Locale(identifier: ["ko": "ko_KR", "ja": "ja_JP", "zh-Hans": "zh_Hans_CN"][current] ?? "en_US")
    }

    static let table: [String: [String: String]] = {
        let path = ProcessInfo.processInfo.environment["AIUSAGE_STRINGS"] ?? Bundle.main.path(forResource: "strings", ofType: "json")
        guard let path, let data = FileManager.default.contents(atPath: path),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return root.compactMapValues { $0 as? [String: String] }
    }()
}

/// 한국어 문장 → 고른 언어(번역이 없으면 영어, 그것도 없으면 한국어 그대로). {0} {1} … 에 값을 차례로 넣는다.
func T(_ korean: String, _ values: Any...) -> String {
    let language = L10n.current
    var text = language == "ko" ? korean : (L10n.table[korean]?[language] ?? L10n.table[korean]?["en"] ?? korean)
    for (index, value) in values.enumerated() { text = text.replacingOccurrences(of: "{\(index)}", with: "\(value)") }
    return text
}

// MARK: - 값

struct LimitWindow: Identifiable {
    let id: String
    let minutes: Int
    let usedPercent: Double
    let resetsAt: Date?
    /// 있으면 모델별 한도(예: Claude 의 「Fable」 주간) — 그 이름을 칸 이름으로 쓴다(Windows 판과 같다)
    var name: String? = nil

    /// 「5시간」「주간」 — 고른 언어로. 모델별 한도는 모델 이름
    var label: String { name ?? windowLabel(minutes: minutes) }

    /// 상태 표시줄과 같은 계산(100 - 사용률 내림). 초기화 시각이 지났으면 100.
    func leftPercent(now: Date) -> Int {
        if let resetsAt, resetsAt <= now { return 100 }
        return max(0, min(100, 100 - Int(usedPercent.rounded(.down))))
    }
}

struct ProviderSnapshot {
    fileprivate var observations: [UsageEvent] = []
    /// 모델별 주간 한도의 가장 새 관측(「모델별 한도도 알림」에만 쓴다 — 사용 추이·기록에는 넣지 않는다)
    fileprivate var modelObservations: [String: UsageEvent] = [:]
    var windows: [LimitWindow] = []
    /// 모델별 줄을 뺄지 고려한 보일 줄
    func visibleWindows(showModels: Bool) -> [LimitWindow] { windows.filter { showModels || $0.name == nil } }
    var observedAt: Date?
    var plan: String?
    var message: String?
    var source: String?  // 오른쪽 클릭 메뉴에 보일 값의 출처
}

private let isoWithFraction: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let isoPlain = ISO8601DateFormatter()

func parseDate(_ s: String) -> Date? { isoWithFraction.date(from: s) ?? isoPlain.date(from: s) }

/// 숫자 또는 숫자 문자열 → Double (시각이 ISO 문자열이면 epoch 초로)
func number(_ value: Any?) -> Double? {
    switch value {
    case let n as NSNumber: return n.doubleValue
    case let s as String: return Double(s) ?? parseDate(s)?.timeIntervalSince1970
    default: return nil
    }
}

func windowLabel(minutes: Int) -> String {
    switch minutes {
    case 300: return T("5시간")
    case 10_080: return T("주간")
    case let m where m > 0 && m % 1_440 == 0: return T("{0}일", m / 1_440)
    case let m where m > 0 && m % 60 == 0: return T("{0}시간", m / 60)
    case let m where m > 0: return T("{0}분", m)
    default: return T("한도")
    }
}

func planName(_ raw: String?) -> String? {
    guard let raw, !raw.isEmpty, raw != "unknown" else { return nil }
    let known = ["free": "Free", "go": "Go", "plus": "Plus", "pro": "Pro", "prolite": "Pro Lite",
                 "promax": "Pro Max", "team": "Team", "business": "Business", "enterprise": "Enterprise", "edu": "Edu"]
    return known[raw] ?? raw
}

// MARK: - Claude

/// 세션마다 마지막으로 받은 한도를 모아, 가장 최근 창(초기화 시각이 가장 늦은 것)에서 가장 많이 쓴 값을 쓴다.
/// 같은 창 안에서 사용률은 줄지 않으므로, 오래 쉬던 세션이 옛 값을 다시 써도 표시가 뒤로 가지 않는다.
/// 지금 로그인한 계정 값만 쓴다: 기록에 적힌 계정(account)이 다르면 빼고, 계정이 안 적힌 옛 기록은 계정을 바꾼 뒤 쓰인 것만.
final class ClaudeReader {
    private let dir = homeDir + "/.cache/ai-usage/claude"
    private var cache: [String: (mtime: Date, limits: [String: Any])] = [:]

    /// 모델별 주간 한도의 열쇠 앞머리(「seven_day:Fable」) — Windows 판과 같다
    static let modelPrefix = "seven_day:"

    func read(now: Date) -> ProviderSnapshot {
        let fm = FileManager.default
        var entries: [(mtime: Date, limits: [String: Any], command: Bool)] = []
        var alive = Set<String>()
        for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let path = dir + "/" + name
            guard let mtime = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { continue }
            if now.timeIntervalSince(mtime) > 8 * 86_400 {  // 주간 창보다 오래된 세션 파일은 정리
                try? fm.removeItem(atPath: path)
                continue
            }
            alive.insert(path)
            let command = name == ClaudeUsageCommand.fileName  // `claude /usage` 로 받은 값(같은 모양으로 남는다)
            if let hit = cache[path], hit.mtime == mtime {
                entries.append((hit.mtime, hit.limits, command))
                continue
            }
            guard let data = fm.contents(atPath: path),
                  let limits = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date == mtime else { continue }  // 읽는 동안 바뀌면 다음에
            cache[path] = (mtime, limits)
            entries.append((mtime, limits, command))
        }
        cache = cache.filter { alive.contains($0.key) }
        let me = ClaudeCodeAccount.identity()
        let since = AccountSwitch.since("claude", id: me, now: now)
        // 지금 계정이 적힌 기록이 있으면 계정이 안 적힌 옛 기록(이 판 전에 쓰인 것)은 쓰지 않는다
        let tagged = me != nil && entries.contains { $0.limits["account"] as? String == me }
        entries = entries.filter { entry in
            if let account = entry.limits["account"] as? String { return account == me }  // 로그아웃이면 어느 계정 것도 아니다
            return !entry.command && !tagged && entry.mtime >= since  // /usage 기록은 계정이 꼭 적혀 있어야 한다
        }

        var sourceRows: [UsageEvent] = []
        for entry in entries {
            for (name, minutes) in [("five_hour", 300), ("seven_day", 10080)] {
                guard let w = entry.limits[name] as? [String: Any], let used = number(w["used_percentage"]) else { continue }
                let window = LimitWindow(id: name, minutes: minutes, usedPercent: used,
                                         resetsAt: number(w["resets_at"]).map(Date.init(timeIntervalSince1970:)))
                sourceRows += UsageEvent.windows([window], at: entry.mtime, provider: "claude", id: me,
                                                 source: entry.command ? ClaudeUsageCommand.historySource : "claude-session")
            }
        }
        // Claude Code 를 안 쓰는 동안에는 데스크톱 앱 기록이 더 새것일 수 있다(같은 계정일 때만)
        let statusAt = entries.map { $0.mtime }.max()
        let desktop = ClaudeDesktopUsage.latest(org: ClaudeCodeAccount.organization(), now: now)
        var snap = ProviderSnapshot()
        if let d = desktop, let org = d.org, org == ClaudeCodeAccount.organization(), d.at >= since {
            for (name, minutes) in [("five_hour", 300), ("seven_day", 10080)] {
                if let used = d.used[name] {
                    let w = LimitWindow(id: name, minutes: minutes, usedPercent: used, resetsAt: nil)
                    sourceRows += UsageEvent.windows([w], at: d.at, provider: "claude", id: me, source: "claude-desktop")
                }
            }
        }
        snap.observations = sourceRows
        var usedStatus = false, usedDesktop = false
        for (key, minutes) in [("five_hour", 300), ("seven_day", 10_080)] {
            let found = entries.compactMap { entry -> (used: Double, reset: Double)? in
                guard let w = entry.limits[key] as? [String: Any], let used = number(w["used_percentage"]) else { return nil }
                return (used, number(w["resets_at"]) ?? 0)
            }
            var used: Double?
            var reset: Double = 0
            if let latest = found.map({ $0.reset }).max() {
                used = found.filter { $0.reset >= latest - Double(resetTolerance)/1000 }.map { $0.used }.max() ?? 0
                reset = latest
            }
            var fromDesktop = false
            if let desktop, let value = desktop.used[key], used == nil || desktop.at > statusAt ?? .distantPast {
                if let current = used, reset > desktop.at.timeIntervalSince1970 {
                    used = max(current, value)  // 상태 표시줄이 본 창이 그때도 열려 있었다: 같은 창이라 초기화 시각을 이어 쓴다
                } else {
                    // 데스크톱 앱 기록에는 초기화 시각이 없다. 창 길이보다 오래된 기록이면 그 창은 이미 끝났다.
                    used = now.timeIntervalSince(desktop.at) >= Double(minutes * 60) ? 0 : value
                    reset = 0
                }
                fromDesktop = true
            }
            guard let used else { continue }
            if fromDesktop { usedDesktop = true } else { usedStatus = true }
            snap.windows.append(LimitWindow(id: key, minutes: minutes, usedPercent: used,
                                            resetsAt: reset > 0 ? Date(timeIntervalSince1970: reset) : nil))
        }
        var seen = [usedStatus ? statusAt : nil, usedDesktop ? desktop?.at : nil].compactMap { $0 }
        // 모델별 주간 한도(예: Fable)는 `claude /usage` 에만 있다: 1시간 안에 받은 가장 새 /usage 기록의 것을 주간 아래에 붙인다
        if let latest = entries.filter({ $0.command }).max(by: { $0.mtime < $1.mtime }), latest.mtime <= now,
           let models = latest.limits["models"] as? [String: Any] {
            var shown = false
            for name in models.keys.sorted() where !name.isEmpty {
                guard let w = models[name] as? [String: Any], let used = number(w["used_percentage"]) else { continue }
                let reset = number(w["resets_at"]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
                let window = LimitWindow(id: Self.modelPrefix + name, minutes: 10_080, usedPercent: used, resetsAt: reset, name: name)
                if let event = UsageEvent.windows([window], at: latest.mtime, provider: "claude", id: me,
                                                  source: ClaudeUsageCommand.historySource).first {
                    snap.modelObservations[name] = event
                }
                if now.timeIntervalSince(latest.mtime) <= 3_600 { snap.windows.append(window); shown = true }
            }
            if shown { seen.append(latest.mtime) }
        }
        snap.observedAt = seen.max()
        // 가장 새 기록이 `claude /usage` 로 받은 것이면 그렇게 적는다
        let statusName = entries.max(by: { $0.mtime < $1.mtime })?.command == true ? T("Claude Code /usage") : T("Claude Code 상태 표시줄")
        snap.source = usedStatus && usedDesktop ? T("Claude Code·데스크톱 앱") : usedDesktop ? T("Claude 데스크톱 앱 기록") : statusName
        if snap.windows.isEmpty { snap.message = ClaudeCodeLink.emptyMessage() }
        return snap
    }
}

/// Claude 데스크톱 앱이 사용량을 서버에서 받을 때마다 남기는 기록(로그인 정보 없이 읽는다).
/// 앱을 쓰는 동안(창을 열고 대화할 때 등)에만 쌓이고, 4.5분에 한 번까지만 남으며, 초기화 시각은 없다.
/// 공식 문서에 없는 파일이라 앱 업데이트로 바뀔 수 있다 — 못 읽으면 상태 표시줄 값만 쓴다.
enum ClaudeDesktopUsage {
    static let fileName = "plan-usage-history.json"

    /// 기록 후보(있는 파일만). 앱의 데이터 폴더 이름은 Claude-Data·Claude·Claude-3p 이고, Claude-Data 는 설치마다
    /// 하위 폴더(claude_<id>)를 둔다(Windows 판과 같은 규칙). 지금 맥 판 앱은 ~/Library/Application Support/Claude 에 둔다.
    static func paths() -> [String] {
        let fm = FileManager.default
        let base = homeDir + "/Library/Application Support"
        var result: [String] = []
        for folder in ["Claude-Data", "Claude", "Claude-3p"] {
            let dir = base + "/" + folder
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }
            result.append(dir + "/" + fileName)
            for sub in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted() { result.append(dir + "/" + sub + "/" + fileName) }
        }
        return result.filter { fm.fileExists(atPath: $0) }
    }

    struct Sample {
        let org: String?
        let at: Date
        let used: [String: Double]  // five_hour·seven_day 사용률
    }

    /// 가장 최근 기록. Claude Code 계정(조직)을 알면 그 조직 것만, 8일보다 오래된 것은 뺀다.
    /// 후보가 여럿이면(옛 자리에 남은 파일, 여러 설치) 모두 보고 가장 새 기록을 쓴다
    static func latest(org: String?, now: Date) -> Sample? {
        var best: Sample?
        for path in paths() {
            guard let data = FileManager.default.contents(atPath: path),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let samples = root["samples"] as? [[String: Any]] else { continue }
            for sample in samples {
                guard let t = number(sample["t"]) else { continue }
                let at = Date(timeIntervalSince1970: t / 1000)
                guard now.timeIntervalSince(at) < 8 * 86_400, at > best?.at ?? .distantPast else { continue }
                if let org, let sampleOrg = sample["org"] as? String, sampleOrg != org { continue }
                let u = sample["u"] as? [String: Any] ?? sample  // 1판은 fh·sd 가 바로 밑에 있다
                var used: [String: Double] = [:]
                if let v = number(u["fh"]) { used["five_hour"] = v }
                if let v = number(u["sd"]) { used["seven_day"] = v }
                if !used.isEmpty { best = Sample(org: sample["org"] as? String, at: at, used: used) }
            }
        }
        return best
    }

    /// 가장 최근에 쓰인 기록 파일과 그 시각(값이 왜 멈췄는지 알리려고). 없으면 nil
    static func lastWrite() -> (path: String, at: Date)? {
        paths().compactMap { path -> (String, Date)? in
            ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date).map { (path, $0) }
        }.max { $0.1 < $1.1 }
    }

    /// 데스크톱 앱은 트레이(메뉴 막대) 아이콘을 누른 뒤 하루 동안만 사용량을 계속 받고, 그 밖에는 앱을 켤 때 한 번만 받아 기록이 멈춘다.
    /// 기록이 이보다 오래 안 바뀌었으면 그렇게 알린다(Windows 판과 같다)
    static let staleAfter: TimeInterval = 3_600

    static func staleHint(now: Date) -> String? {
        guard let last = lastWrite(), now.timeIntervalSince(last.at) >= staleAfter else { return nil }
        return T("Claude 데스크톱 앱 기록이 {0} 뒤로 멈춤 — 메뉴 막대의 Claude 아이콘을 누르면 그 뒤 하루 동안 다시 받습니다", fullTime(last.at))
    }
}

// MARK: - Claude Code /usage

/// `claude -p "/usage"` 로 지금 한도를 묻는다(Windows 판과 같은 규칙). Codex 의 app-server 처럼 인증은 Claude Code 가 알아서 한다(로그인 토큰을 읽지 않는다).
/// /usage 는 모델을 부르지 않는 Claude Code 안의 명령(local_command)이라 한도를 쓰지 않는다. 혹시 모델을 불렀으면(num_turns·비용 > 0)
/// 다시는 부르지 않게 끄고(~/.cache/ai-usage/claude-usage-disabled) 기록한다.
/// 받은 값은 상태 표시줄 기록과 같은 모양으로 ~/.cache/ai-usage/claude/usage-command.json 에 남겨 같은 규칙(계정·창)으로 합친다.
/// 대화 기록을 남기지 않게 --no-session-persistence 로, 늘 같은 폴더(~/.cache/ai-usage/claude-usage)에서 띄운다.
/// 결과는 사람이 읽는 영어 문장이라 Claude Code 업데이트로 바뀔 수 있다 — 못 읽으면 이 출처만 건너뛰고 claude-usage.log 에 남긴다.
/// 끄기: `defaults write com.local.ai-usage-pet claudeUsage -bool false` 또는 AIUSAGE_CLAUDE_USAGE=0
enum ClaudeUsageCommand {
    static let fileName = "usage-command.json"
    static let historySource = "claude-usage"
    static let settingKey = "claudeUsage"
    static var cacheDir: String { homeDir + "/.cache/ai-usage" }
    static var resultPath: String { cacheDir + "/claude/" + fileName }
    static var logPath: String { cacheDir + "/claude-usage.log" }
    static var disabledPath: String { cacheDir + "/claude-usage-disabled" }
    private static var workDir: String { cacheDir + "/claude-usage" }

    /// 대화가 이어질 때 너무 자주 묻지 않게: 두 번 사이 최소 간격
    static let minInterval: TimeInterval = 60
    /// 이 맥 밖(claude.ai 웹·모바일·데스크톱 앱 Chat)에서 쓴 것은 알 길이 없어 이만큼마다 묻는다
    static let fallbackInterval: TimeInterval = 300
    private static let timeout: TimeInterval = 60

    private static let lock = NSLock()
    private static var running = false
    private static var processStopReason: String?
    private static var lastLoggedError: String?
    private static var lastLoggedLimits: [String: (used: Double, reset: Double)]?
    private(set) static var lastCheckedAt: Date?
    private(set) static var lastError: String?
    private(set) static var lastSeconds: Double?

    /// 꺼져 있으면 그 이유. 설정·환경 변수로 껐거나, /usage 가 모델을 부른 적이 있어 스스로 껐을 때
    static func disabledReason() -> String? {
        if let reason = lock.withLock({ processStopReason }) { return reason }
        if ProcessInfo.processInfo.environment["AIUSAGE_CLAUDE_USAGE"] == "0" { return T("꺼 둠(AIUSAGE_CLAUDE_USAGE=0)") }
        if UserDefaults.standard.object(forKey: settingKey) as? Bool == false { return T("꺼 둠(claudeUsage=false)") }
        if FileManager.default.fileExists(atPath: disabledPath) {
            return T("꺼짐 — /usage 가 모델을 불러 멈췄습니다({0} 를 지우면 다시 켜짐)", disabledPath)
        }
        return nil
    }

    static func findClaude() -> String? {
        let fm = FileManager.default
        var candidates = [homeDir + "/.local/bin/claude", homeDir + "/.claude/local/claude",
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") { candidates.append(String(dir) + "/claude") }
        if let found = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) { return found }
        return desktopBundled()
    }

    /// Claude 데스크톱 앱이 Code 탭용으로 품고 있는 Claude Code(claude-code/<버전>/<id>/claude.app) 중 가장 높은 버전.
    /// Claude Code CLI 를 따로 깔지 않고 데스크톱 앱만 쓰는 사람도 /usage 를 물을 수 있게.
    private static func desktopBundled() -> String? {
        let fm = FileManager.default
        var found: [(version: [Int], path: String)] = []
        let base = homeDir + "/Library/Application Support"
        var roots = ["Claude", "Claude-3p"].map { base + "/" + $0 }
        roots += ((try? fm.contentsOfDirectory(atPath: base + "/Claude-Data")) ?? []).map { base + "/Claude-Data/" + $0 }
        for root in roots.map({ $0 + "/claude-code" }) {
            for name in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
                let parts = name.split(separator: ".").compactMap { Int($0) }
                guard parts.count >= 2, parts.count == name.split(separator: ".").count else { continue }
                let dir = root + "/" + name
                var paths = [dir + "/claude"]
                for build in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
                    paths += [dir + "/" + build + "/claude", dir + "/" + build + "/claude.app/Contents/MacOS/claude"]
                }
                for path in paths where fm.isExecutableFile(atPath: path) { found.append((parts, path)) }
            }
        }
        return found.max { $0.version.lexicographicallyPrecedes($1.version) }?.path
    }

    /// 묻고 결과를 남긴다(호출한 스레드에서 끝날 때까지 — 창은 뒤에서 부른다). 성공하면 nil, 아니면 이유. 이미 묻는 중이면 nil.
    /// reason 은 기록(claude-usage.log)에 남길 계기(시작·활동·5분·새로고침 등).
    @discardableResult
    static func fetch(reason: String) -> String? {
        if let off = disabledReason() { lock.withLock { lastError = off }; return off }
        let busy = lock.withLock { () -> Bool in
            if running { return true }
            running = true
            return false
        }
        if busy { return nil }
        defer { lock.withLock { running = false } }
        if let stopped = disabledReason() { lock.withLock { lastError = stopped }; return stopped }
        cleanOldTemps()
        let started = Date()
        let before = ClaudeCodeAccount.identity()
        let result = run()
        var error = result.error
        if result.modelCalled {
            do {
                try FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
                let stamp = formatterPOSIX("yyyy-MM-dd HH:mm:ss").string(from: Date())
                try Data("\(stamp) /usage 가 모델을 불렀다(num_turns·비용 > 0). 이 파일을 지우면 다시 묻는다.\n".utf8)
                    .write(to: URL(fileURLWithPath: disabledPath))
            } catch let e {
                let message = T("/usage 가 모델을 불러 이 실행에서 중지했습니다. 중지 파일을 저장하지 못했습니다: {0}", e.localizedDescription)
                error = message
                lock.withLock { processStopReason = message }
            }
        } else if error == nil, let limits = result.limits {
            let after = ClaudeCodeAccount.identity()
            if after == nil { error = T("Claude Code 에 로그인되어 있지 않습니다") }
            else if after != before { error = T("묻는 동안 계정이 바뀌었습니다") }
            else { error = save(limits, account: after!) }
        }
        let seconds = Date().timeIntervalSince(started)
        lock.withLock { lastCheckedAt = Date(); lastError = error; lastSeconds = seconds }
        log(reason: reason, limits: result.limits, error: error, seconds: seconds)
        return error
    }

    private struct RunResult {
        var limits: [String: (used: Double, reset: Double)]?
        var error: String?
        var modelCalled = false
    }

    private static func run() -> RunResult {
        guard let exe = findClaude() else { return RunResult(error: T("claude 명령을 찾지 못했습니다(Claude Code 또는 Claude 데스크톱 앱 필요)")) }
        do { try FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true) }
        catch { return RunResult(error: T("claude 를 실행하지 못했습니다")) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = ["-p", "/usage", "--output-format", "json", "--no-session-persistence"]
        process.currentDirectoryURL = URL(fileURLWithPath: workDir)
        var env = ProcessInfo.processInfo.environment
        // npm 판 claude 는 node 스크립트라 그 폴더(node 가 같이 있는 곳)를 PATH 앞에 붙인다
        let exeDir = (exe as NSString).deletingLastPathComponent
        env["PATH"] = ([exeDir] + (env["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"])
            .joined(separator: ":")
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice  // 입력을 기다리지 않게
        do { try process.run() } catch { return RunResult(error: T("claude 를 실행하지 못했습니다")) }
        var output = Data()
        let reading = DispatchGroup()
        reading.enter()
        DispatchQueue.global(qos: .utility).async {
            output = out.fileHandleForReading.readDataToEndOfFile()
            reading.leave()
        }
        if reading.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            kill(process.processIdentifier, SIGKILL)
            _ = reading.wait(timeout: .now() + 2)
            return RunResult(error: T("claude 가 응답하지 않습니다"))
        }
        process.waitUntilExit()
        return parse(String(decoding: output, as: UTF8.self), now: Date())
    }

    /// `claude -p "/usage" --output-format json` 의 출력을 읽는다(시험할 수 있게 따로 둔다)
    private static func parse(_ output: String, now: Date) -> RunResult {
        var root: [String: Any]?
        for raw in output.split(separator: "\n").reversed() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("{"), let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            root = obj
            break
        }
        guard let root else { return RunResult(error: T("claude 의 답을 읽지 못했습니다")) }
        // 모델을 불렀다면(한도를 썼다면) 값이 맞아도 쓰지 않고 멈춘다
        if (number(root["num_turns"]) ?? 0) > 0 || (number(root["total_cost_usd"]) ?? 0) > 0 {
            return RunResult(error: T("/usage 가 모델을 불렀습니다 — 한도를 쓰지 않도록 멈춥니다"), modelCalled: true)
        }
        if root["is_error"] as? Bool == true || root["local_command"] as? String != "usage" {
            return RunResult(error: T("claude 가 /usage 를 실행하지 못했습니다"))
        }
        let text = root["result"] as? String ?? ""
        let limits = parseText(text, now: now)
        if !limits.isEmpty { return RunResult(limits: limits) }
        return RunResult(error: text.contains("Current ")
            ? T("/usage 결과 형식을 읽지 못했습니다(Claude Code 업데이트로 바뀌었을 수 있음)")
            : T("/usage 에 한도가 없습니다 — Claude 구독(Pro·Max·Team)으로 로그인했는지 확인"))
    }

    // 「Current session: 8% used · resets Nov 20, 3:10pm (Asia/Seoul)」「Current week (all models): 70% used · resets …」
    // 「Current week (Fable): 89% used · resets …」(모델별 주간 — 옛 판은 「(Sonnet only)」)
    private static let usageLine = try! NSRegularExpression(
        pattern: #"^Current (?:(?<session>session)|week \((?<scope>[^)]+)\))\s*:\s*(?<used>\d+(?:\.\d+)?)\s*%\s*used(?:\s*·\s*resets\s+(?<reset>.+?))?\s*$"#,
        options: [.caseInsensitive])

    /// 열쇠: five_hour, seven_day, 모델별 주간은 「seven_day:<모델>」(ClaudeReader.modelPrefix)
    static func parseText(_ text: String, now: Date) -> [String: (used: Double, reset: Double)] {
        var result: [String: (used: Double, reset: Double)] = [:]
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let ns = line as NSString
            guard let m = usageLine.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            func group(_ name: String) -> String? {
                let r = m.range(withName: name)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
            let key: String
            if group("session") != nil { key = "five_hour" }
            else {
                var scope = (group("scope") ?? "").trimmingCharacters(in: .whitespaces)
                if scope.caseInsensitiveCompare("all models") == .orderedSame { key = "seven_day" }
                else {
                    if scope.lowercased().hasSuffix(" only") { scope = String(scope.dropLast(5)).trimmingCharacters(in: .whitespaces) }
                    guard !scope.isEmpty else { continue }
                    key = ClaudeReader.modelPrefix + scope
                }
            }
            guard let usedText = group("used"), let used = Double(usedText), used.isFinite else { continue }
            let reset = group("reset").flatMap { parseReset($0, now: now) } ?? 0
            result[key] = (used, reset)
        }
        return result
    }

    // 「Nov 20, 3:10pm (Asia/Seoul)」「Nov 22, 10am (Asia/Seoul)」「3:10pm」「Dec 1, 2027, 9:00am」
    private static let resetText = try! NSRegularExpression(
        pattern: #"^(?:(?<mon>[A-Za-z]{3})[A-Za-z]*\.?\s+(?<day>\d{1,2})(?:,\s*(?<year>\d{4}))?,?\s+(?:at\s+)?)?(?<h>\d{1,2})(?::(?<m>\d{2}))?\s*(?<ap>[ap]\.?m\.?)?\s*(?:\((?<tz>[^)]+)\))?$"#,
        options: [.caseInsensitive])

    /// 초기화 시각 글을 유닉스 초로. 해가 없으면 지금에 가장 가까운 앞날로, 날짜가 없으면 오늘(지났으면 내일)로 본다. 못 읽으면 nil.
    static func parseReset(_ text: String, now: Date) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let ns = trimmed as NSString
        guard let m = resetText.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func group(_ name: String) -> String? {
            let r = m.range(withName: name)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        let zone = group("tz").flatMap { TimeZone(identifier: $0.trimmingCharacters(in: .whitespaces)) } ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let local = calendar.dateComponents([.year, .month, .day], from: now)
        guard var hour = group("h").flatMap({ Int($0) }) else { return nil }
        let minute = group("m").flatMap { Int($0) } ?? 0
        if let ap = group("ap") {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (ap.lowercased().hasPrefix("p") ? 12 : 0)
        }
        guard hour <= 23, minute <= 59 else { return nil }
        var year = local.year ?? 2000, month = local.month ?? 1, day = local.day ?? 1
        let hasDate = group("mon") != nil
        if let mon = group("mon") {
            let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
            guard let index = months.firstIndex(of: mon.lowercased()) else { return nil }
            month = index + 1
            guard let d = group("day").flatMap({ Int($0) }) else { return nil }
            day = d
        }
        let hasYear = group("year") != nil
        if let y = group("year").flatMap({ Int($0) }) { year = y }
        func at(_ y: Int, _ mo: Int, _ d: Int) -> Date? {
            var c = DateComponents(year: y, month: mo, day: d, hour: hour, minute: minute)
            c.timeZone = zone
            guard let date = calendar.date(from: c), calendar.component(.day, from: date) == d else { return nil }
            return date
        }
        guard var result = at(year, month, day) else { return nil }
        if !hasDate && result < now { result = result.addingTimeInterval(86_400) }  // 시각만 있으면 다음에 오는 그 시각
        else if hasDate && !hasYear && result < now.addingTimeInterval(-86_400), let next = at(year + 1, month, day) { result = next }  // 12월 → 1월
        return result.timeIntervalSince1970.rounded(.down)
    }

    /// 상태 표시줄 기록과 같은 모양으로 남긴다(바꿔치기로 써서 읽는 쪽이 반쯤 쓴 파일을 보지 않게)
    private static func save(_ limits: [String: (used: Double, reset: Double)], account: String) -> String? {
        let dir = cacheDir + "/claude"
        let temp = dir + "/.usage-command.\(getpid()).\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()).tmp"
        defer { try? FileManager.default.removeItem(atPath: temp) }
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            var node: [String: Any] = [:], models: [String: Any] = [:]
            for (key, value) in limits {
                let window: [String: Any] = ["used_percentage": value.used, "resets_at": value.reset]
                if key.hasPrefix(ClaudeReader.modelPrefix) { models[String(key.dropFirst(ClaudeReader.modelPrefix.count))] = window }
                else { node[key] = window }
            }
            if !models.isEmpty { node["models"] = models }
            node["account"] = account
            node["source"] = "usage"
            try JSONSerialization.data(withJSONObject: node).write(to: URL(fileURLWithPath: temp))
            if ClaudeCodeAccount.identity() != account { return T("묻는 동안 계정이 바뀌었습니다") }
            guard rename(temp, resultPath) == 0 else { throw POSIXError(.EIO) }
            return nil
        } catch {
            return T("결과를 남기지 못했습니다: {0}", error.localizedDescription)
        }
    }

    private static func cleanOldTemps() {
        let dir = cacheDir + "/claude"
        let cutoff = Date().addingTimeInterval(-86_400)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        where name.hasPrefix(".usage-command.") && name.hasSuffix(".tmp") {
            let path = dir + "/" + name
            if let m = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date, m < cutoff {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }

    /// 두 결과가 같은 값인지. 서버가 주는 초기화 시각은 같은 창이어도 1분쯤 오가므로 2분 안의 차이는 같은 것으로 본다.
    private static func sameLimits(_ a: [String: (used: Double, reset: Double)]?, _ b: [String: (used: Double, reset: Double)]?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        guard a.count == b.count else { return false }
        for (key, x) in a {
            guard let y = b[key], x.used == y.used, abs(x.reset - y.reset) <= 120 else { return false }
        }
        return true
    }

    /// 값이 바뀌었거나 실패했을 때만 한 줄 남긴다(같은 값·같은 실패가 이어지면 남기지 않는다). 256KB 를 넘으면 뒤쪽 절반만 남긴다.
    private static func log(reason: String, limits: [String: (used: Double, reset: Double)]?, error: String?, seconds: Double) {
        let skip = lock.withLock { () -> Bool in
            if error != nil ? error == lastLoggedError : (lastLoggedError == nil && sameLimits(limits, lastLoggedLimits)) { return true }
            lastLoggedError = error
            lastLoggedLimits = error == nil ? limits : nil
            return false
        }
        if skip { return }
        func name(_ key: String) -> String {
            key == "five_hour" ? "5시간" : key == "seven_day" ? "주간" : key.replacingOccurrences(of: ClaudeReader.modelPrefix, with: "주간 ")
        }
        func order(_ key: String) -> Int { key == "five_hour" ? 0 : key == "seven_day" ? 1 : 2 }
        let summary = error ?? (limits ?? [:]).sorted { (order($0.key), $0.key) < (order($1.key), $1.key) }.map { key, value -> String in
            var s = "\(name(key)) \(value.used.formatted(.number.locale(Locale(identifier: "en_US_POSIX")).grouping(.never)))%"
            if value.reset > 0 { s += "(초기화 \(formatterPOSIX("MM-dd HH:mm").string(from: Date(timeIntervalSince1970: value.reset))))" }
            return s
        }.joined(separator: " · ")
        let line = "\(formatterPOSIX("yyyy-MM-dd HH:mm:ss").string(from: Date())) [\(reason)] \(summary) (\(String(format: "%.1f", seconds))초)\n"
        try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        if let size = (try? FileManager.default.attributesOfItem(atPath: logPath))?[.size] as? NSNumber, size.intValue > 256 * 1024,
           let text = try? String(contentsOfFile: logPath, encoding: .utf8) {
            let half = text.index(text.startIndex, offsetBy: text.count / 2)
            let rest = text[half...].firstIndex(of: "\n").map { String(text[text.index(after: $0)...]) } ?? ""
            try? rest.write(toFile: logPath, atomically: true, encoding: .utf8)
        }
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else {
            try? Data(line.utf8).write(to: URL(fileURLWithPath: logPath))
        }
    }
}

/// 날짜를 늘 같은 모양으로(기록 파일용 — 고른 언어와 상관없이)
private func formatterPOSIX(_ format: String) -> DateFormatter {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = format
    return f
}

/// Claude Code 가 응답할 때마다 대화 기록(~/.claude/projects/…/*.jsonl)에 바로 쓰는 것을 지켜본다 — CLI·데스크톱 앱 Code 탭 모두.
/// 바뀐 때만 적어 두고, 받는 쪽(창의 타이머)이 take() 로 가져가 /usage 를 묻는다. 폴더가 아직 없으면 ensure() 가 나중에 다시 건다.
final class ClaudeActivityWatcher {
    private var stream: FSEventStreamRef?
    private let lock = NSLock()
    private var first: Date?, last: Date?
    private let queue = DispatchQueue(label: "ai-usage.claude-activity")

    func ensure() {
        guard stream == nil else { return }
        let dir = homeDir + "/.claude/projects"
        guard FileManager.default.fileExists(atPath: dir) else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<ClaudeActivityWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            if list.contains(where: { $0.hasSuffix(".jsonl") }) || count == 0 { watcher.mark() }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [dir] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        if FSEventStreamStart(s) { stream = s } else { FSEventStreamInvalidate(s); FSEventStreamRelease(s) }
    }

    private func mark() {
        let now = Date()
        lock.withLock { if first == nil { first = now }; last = now }
    }

    /// 아직 가져가지 않은 활동(처음·마지막). 없으면 nil
    func pending() -> (first: Date, last: Date)? {
        lock.withLock { first.flatMap { f in last.map { (f, $0) } } }
    }

    /// 활동을 가져갔다(이제 /usage 를 묻는다)
    func take() { lock.withLock { first = nil; last = nil } }

    /// 지금 /usage 를 물을 때인지와 그 계기. 처음, 5분이 지났을 때, 또는 활동이 있었고 1분이 지났으며
    /// 활동이 5초 잠잠하거나(응답이 끝남) 30초 넘게 이어질 때(긴 작업 중에도 갱신)
    static func due(now: Date, lastAsked: Date?, pending: (first: Date, last: Date)?) -> String? {
        guard let asked = lastAsked else { return "시작" }
        if now.timeIntervalSince(asked) >= ClaudeUsageCommand.fallbackInterval { return "5분" }
        if let p = pending, now.timeIntervalSince(asked) >= ClaudeUsageCommand.minInterval,
           now.timeIntervalSince(p.last) >= 5 || now.timeIntervalSince(p.first) >= 30 { return "활동" }
        return nil
    }

    deinit {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
    }
}

/// Claude Code 가 로그인한 조직(~/.claude.json 의 oauthAccount.organizationUuid, 비밀값 아님).
/// 데스크톱 앱이 다른 계정이면 그 기록은 쓰지 않으려고 본다. 파일이 바뀔 때만 다시 읽는다.
enum ClaudeCodeAccount {
    private static var cached: (mtime: Date, org: String?, identity: String?)?

    /// Claude Code 에 로그인한 조직(데스크톱 앱 기록을 고를 때)
    static func organization() -> String? { read()?.org }

    /// Claude Code 에 로그인한 계정 — 「사용자 id|조직 id」. 한도는 계정마다 따로라 이것으로 값을 가른다(로그인 정보가 없으면 nil)
    static func identity() -> String? { read()?.identity }

    private static func read() -> (org: String?, identity: String?)? {
        let path = homeDir + "/.claude.json"
        guard let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return nil }
        if let cached, cached.mtime == mtime { return (cached.org, cached.identity) }
        var org: String?, identity: String?
        if let data = FileManager.default.contents(atPath: path),
           let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let account = root["oauthAccount"] as? [String: Any] {
            org = account["organizationUuid"] as? String
            let user = account["accountUuid"] as? String
            if user != nil || org != nil { identity = "\(user ?? "")|\(org ?? "")" }
        }
        cached = (mtime, org, identity)
        return (org, identity)
    }
}

/// 계정을 바꾼 때를 기억한다(~/.cache/ai-usage/accounts.json). 어느 계정 값인지 적혀 있지 않은 기록은
/// 마지막으로 계정이 바뀐 뒤에 쓰인 것만 지금 계정 값으로 본다. 처음 보는 계정이면 바뀐 때를 모르니 다 쓴다.
enum AccountSwitch {
    static let path = homeDir + "/.cache/ai-usage/accounts.json"
    private static let lock = NSLock()

    /// kind(claude·codex)의 지금 계정이 id 일 때, 그 계정으로 바뀐 시각
    static func since(_ kind: String, id: String?, now: Date = Date()) -> Date {
        guard let id else { return .distantPast }
        lock.lock()
        defer { lock.unlock() }
        var root = (FileManager.default.contents(atPath: path)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        let saved = root[kind] as? [String: Any]
        if let saved, saved["id"] as? String == id { return Date(timeIntervalSince1970: number(saved["since"]) ?? 0) }
        let since = saved == nil ? Date.distantPast : now  // 처음이면 바뀐 때를 모른다
        root[kind] = ["id": id, "since": saved == nil ? 0 : now.timeIntervalSince1970]
        if let data = try? JSONSerialization.data(withJSONObject: root) {
            try? FileManager.default.createDirectory(atPath: homeDir + "/.cache/ai-usage", withIntermediateDirectories: true)
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        return since
    }
}

/// Claude Code 상태 표시줄이 이 앱에 걸려 있는지 보고, 안 걸렸거나 끊겼으면 건다(설치.sh 와 같은 claude-settings.js 로).
enum ClaudeCodeLink {
    enum State { case noClaudeCode, notConnected, broken, connected }

    static let claudeDir = homeDir + "/.claude"
    static let settingsPath = claudeDir + "/settings.json"
    static let wrapperPath = claudeDir + "/ai-usage-statusline.sh"
    static let originalPath = claudeDir + "/ai-usage-statusline.original.json"
    /// 상태 표시줄이 마지막으로 돈 때와 한도 값(rate_limits)이 왔는지 — 값이 안 나올 때 이유를 말하려고 남긴다
    static let seenPath = homeDir + "/.cache/ai-usage/claude-statusline.json"

    static func command() -> String? {
        guard let data = FileManager.default.contents(atPath: settingsPath),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return (root["statusLine"] as? [String: Any])?["command"] as? String
    }

    static func state() -> State {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: claudeDir, isDirectory: &isDir), isDir.boolValue else { return .noClaudeCode }
        guard let command = command(), !command.isEmpty else { return .notConnected }
        let fm = FileManager.default
        if command.contains("ai-usage-statusline.sh") {  // 쓰던 상태 표시줄을 감싼 경우
            guard fm.isExecutableFile(atPath: wrapperPath),
                  let script = try? String(contentsOfFile: wrapperPath, encoding: .utf8),
                  let bin = appPath(in: script) else { return .broken }
            return fm.isExecutableFile(atPath: bin) ? .connected : .broken
        }
        if command.contains("AIUsagePet") {
            guard let bin = appPath(in: command) else { return .broken }
            return fm.isExecutableFile(atPath: bin) ? .connected : .broken
        }
        // 직접 만든 상태 표시줄 스크립트가 같은 곳(~/.cache/ai-usage)에 남기면 연결된 것으로 본다
        if let script = scriptPath(command), let text = try? String(contentsOfFile: script, encoding: .utf8),
           text.contains("ai-usage") {
            return .connected
        }
        return .notConnected
    }

    /// `"…/AIUsagePet" --statusline` 의 따옴표 안 경로
    static func appPath(in text: String) -> String? {
        guard let range = text.range(of: #""[^"\n]+"[ \t]+--statusline"#, options: .regularExpression) else { return nil }
        return text[range].split(separator: "\"").first.map(String.init)
    }

    /// `~/.claude/statusline.sh`, `bash ~/x.sh` 같은 명령에서 스크립트 파일
    static func scriptPath(_ command: String) -> String? {
        let words = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard var word = words.first(where: { !["bash", "sh", "zsh", "/bin/bash", "/bin/sh", "/bin/zsh"].contains($0) }) else { return nil }
        word = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if word.hasPrefix("~/") { word = homeDir + word.dropFirst(1) }
        if word.hasPrefix("$HOME/") { word = homeDir + word.dropFirst(5) }
        return word.hasPrefix("/") ? word : nil
    }

    /// Claude 칸에 값이 하나도 없을 때 보일 이유
    static func emptyMessage() -> String {
        switch state() {
        case .noClaudeCode:
            return T("Claude Code 나 Claude 데스크톱 앱을 쓰면 표시됩니다")
        case .notConnected:
            return T("Claude Code 에 연결되지 않았습니다 — 오른쪽 클릭 → 「Claude Code 에 연결」")
        case .broken:
            return T("Claude Code 연결이 끊겼습니다 — 오른쪽 클릭 → 「Claude Code 에 연결」")
        case .connected:
            if let data = FileManager.default.contents(atPath: seenPath),
               let seen = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               seen["limits"] as? Bool == false {
                return T("Claude Code 가 한도 값을 보내지 않습니다 — Claude 구독(Pro·Max·Team)으로 로그인했는지, Claude Code 가 최신인지 확인")
            }
            return T("Claude Code 에서 한 번 대화하면 표시됩니다")
        }
    }

    /// claude-settings.js install 을 돌린다. 결과 한 단어(new·wrapped·repaired·already·error:…)를 돌려준다.
    @discardableResult
    static func connect() -> String {
        guard let script = Bundle.main.path(forResource: "claude-settings", ofType: "js"),
              let bin = Bundle.main.executablePath else { return "error:" + T("앱 안에 claude-settings.js 가 없습니다") }
        try? FileManager.default.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)
        let stamp = makeFormatter("yyyyMMdd-HHmmss").string(from: Date())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", script, "install", settingsPath, bin, wrapperPath, originalPath,
                             "\(settingsPath).bak-\(stamp)"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do { try process.run() } catch { return "error:" + T("osascript 를 실행하지 못했습니다") }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if FileManager.default.fileExists(atPath: wrapperPath) { chmod(wrapperPath, 0o755) }  // 새로 쓴 감싸는 스크립트는 실행 권한이 없다
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - ChatGPT(Codex)

final class CodexReader {
    private var lastLogKey = ""
    private var fetching = false
    private var account: String?
    private var logAccounts: [String: String?] = [:]  // 기록 파일 → 만든 계정(파일마다 한 번만 읽는다)
    private(set) var fromLog: ProviderSnapshot?
    private(set) var fromServer: ProviderSnapshot?
    private(set) var serverError: String?
    private(set) var serverCheckedAt: Date?

    /// 기록과 서버 가운데 더 나중에 확인한 값을 쓴다
    var current: ProviderSnapshot {
        let both = [fromLog, fromServer].compactMap { $0 }
        if let best = both.max(by: { ($0.observedAt ?? .distantPast) < ($1.observedAt ?? .distantPast) }) { return best }
        return ProviderSnapshot(message: serverError ?? T("Codex 한도를 읽는 중…"))
    }

    /// Codex 를 쓰는 동안 기록 파일에 찍히는 최신 한도(파일이 바뀌었을 때만 다시 읽는다).
    /// 지금 로그인한 계정(~/.codex/auth.json 의 account_id)이 만든 기록만 쓴다. 계정이 바뀌었으면 true —
    /// 앞 계정 값은 버렸으니 부른 쪽이 서버에 바로 다시 묻는다.
    @discardableResult
    func readLog(now: Date = Date()) -> Bool {
        let me = Self.currentAccount()
        var switched = false
        if me != account {
            switched = account != nil  // 다른 계정으로 바꿨거나 로그아웃: 앞 계정 값을 버린다
            fromLog = nil; fromServer = nil; serverError = nil
            account = me
        }
        let since = AccountSwitch.since("codex", id: me, now: now)
        let files = Self.recentRolloutFiles(now: now)
        guard let newest = files.first else { return switched }
        let key = "\(newest.path)|\(newest.mtime.timeIntervalSince1970)|\(me ?? "")"
        guard key != lastLogKey else { return switched }
        lastLogKey = key
        logAccounts = logAccounts.filter { path, _ in files.contains { $0.path == path } }
        for file in files.prefix(10) {
            if logAccounts[file.path] == nil { logAccounts[file.path] = .some(Self.creatorAccount(inLog: file.path)) }
            if let owner = logAccounts[file.path] ?? nil {
                if owner != me { continue }  // 다른 계정으로 쓴 기록(로그아웃·API 키면 어느 계정 것도 아니다)
            } else if file.mtime < since {
                continue  // 계정이 안 적힌 기록은 계정을 바꾼 뒤 것만
            }
            if let snap = Self.lastLimits(inLog: file.path, mtime: file.mtime, owner: logAccounts[file.path] ?? nil) {
                fromLog = snap
                return switched
            }
        }
        fromLog = nil
        return switched
    }

    /// 지금 Codex 에 로그인한 ChatGPT 계정(auth.json 의 tokens.account_id 만 읽는다). API 키 로그인이면 nil
    static func currentAccount() -> String? {
        guard let data = FileManager.default.contents(atPath: homeDir + "/.codex/auth.json"),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return (root["tokens"] as? [String: Any])?["account_id"] as? String
    }

    /// Only the session metadata payload identifies the account that produced this log.
    static func creatorAccount(inLog path: String) -> String? {
        guard let file = fopen(path, "r") else { return nil }
        var buffer: UnsafeMutablePointer<CChar>?
        var capacity = 0
        defer { free(buffer); fclose(file) }
        let count = getline(&buffer, &capacity, file)
        guard count > 0, let buffer, buffer[count - 1] == 10,
              let meta = (try? JSONSerialization.jsonObject(with: Data(bytes: buffer, count: count))) as? [String: Any],
              meta["type"] as? String == "session_meta" else { return nil }
        return (meta["payload"] as? [String: Any])?["creator_account_id"] as? String
    }

    func refreshServer(retry: Bool = true, done: @escaping () -> Void) {
        guard !fetching else { return }
        fetching = true
        let owner = Self.currentAccount()
        DispatchQueue.global(qos: .utility).async {
            let result = Self.fetchServerSync()
            DispatchQueue.main.async {
                self.fetching = false
                let applied = self.applyServer(result, owner: owner)
                done()
                if !applied && retry { self.refreshServer(retry: false, done: done) }
            }
        }
    }

    func readServerSync() {
        for _ in 0..<2 {
            let owner = Self.currentAccount()
            if applyServer(Self.fetchServerSync(), owner: owner) { break }
        }
    }

    private func applyServer(_ result: (snapshot: ProviderSnapshot?, error: String?), owner: String?) -> Bool {
        guard owner == Self.currentAccount() else { readLog(); return false }
        serverCheckedAt = Date()
        if var snap = result.snapshot {
            if let at = snap.observedAt {
                snap.observations = UsageEvent.windows(snap.windows, at: at, provider: "codex", id: owner, source: "codex-server")
            }
            fromServer = snap
            serverError = nil
        } else {
            serverError = result.error
        }
        return true
    }

    static func windows(from limits: [String: Any]) -> [LimitWindow] {
        var out: [LimitWindow] = []
        for key in ["primary", "secondary"] {
            guard let w = limits[key] as? [String: Any], let used = number(w["usedPercent"] ?? w["used_percent"]) else { continue }
            let rawMinutes = number(w["windowDurationMins"] ?? w["window_minutes"]) ?? 0
            guard used.isFinite, (0...Double(Int32.max)).contains(rawMinutes) else { continue }
            let minutes = Int(rawMinutes)
            let reset = number(w["resetsAt"] ?? w["resets_at"]).map { Date(timeIntervalSince1970: $0) }
            out.append(LimitWindow(id: key, minutes: minutes, usedPercent: used, resetsAt: reset))
        }
        return out.sorted { $0.minutes < $1.minutes }
    }

    /// 오늘·어제 날짜 폴더의 rollout 기록, 최근 것부터
    static func recentRolloutFiles(now: Date = Date()) -> [(path: String, mtime: Date)] {
        let fm = FileManager.default
        let cal = Calendar.current
        var files: [(path: String, mtime: Date)] = []
        for back in 0...1 {
            guard let day = cal.date(byAdding: .day, value: -back, to: now) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: day)
            let dir = homeDir + String(format: "/.codex/sessions/%04ld/%02ld/%02ld", c.year ?? 0, c.month ?? 0, c.day ?? 0)
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where name.hasPrefix("rollout-") && name.hasSuffix(".jsonl") {
                let path = dir + "/" + name
                if let mtime = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date {
                    files.append((path, mtime))
                }
            }
        }
        return files.sorted { $0.mtime > $1.mtime }
    }

    static func lastLimits(inLog path: String, mtime: Date, owner: String?) -> ProviderSnapshot? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 2_000_000 ? size - 2_000_000 : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        let marker = Data("\"rate_limits\"".utf8)
        for line in data.split(separator: 0x0A).reversed() where line.range(of: marker) != nil {
            guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let payload = event["payload"] as? [String: Any],
                  let limits = payload["rate_limits"] as? [String: Any] else { continue }
            if let id = limits["limit_id"] as? String, id != "codex" { continue }
            let windows = windows(from: limits)
            if windows.isEmpty { continue }
            let eventAt = (event["timestamp"] as? String).flatMap(parseDate)
            let rows = eventAt.map { UsageEvent.windows(windows, at: $0, provider: "codex", id: owner, source: "codex-rollout") } ?? []
            return ProviderSnapshot(observations: rows, windows: windows,
                                    observedAt: (event["timestamp"] as? String).flatMap(parseDate) ?? mtime,
                                    plan: planName(limits["plan_type"] as? String))
        }
        return nil
    }

    /// codex 를 까는 방법마다 놓이는 곳(독립 설치·Homebrew·npm·nvm·ChatGPT 앱에 들어 있는 것) 가운데 먼저 있는 것
    static func codexExecutable() -> String? {
        let home = homeDir
        var candidates = [home + "/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                          home + "/.codex/packages/standalone/current/bin/codex",
                          home + "/.npm-global/bin/codex", home + "/.volta/bin/codex", home + "/.bun/bin/codex"]
        let nvm = home + "/.nvm/versions/node"
        for version in ((try? FileManager.default.contentsOfDirectory(atPath: nvm)) ?? []).sorted().reversed() {
            candidates.append("\(nvm)/\(version)/bin/codex")
        }
        candidates.append("/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex")
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// `codex app-server` 를 잠깐 띄워 account/rateLimits/read 로 지금 한도를 묻는다(인증은 codex 가 알아서 한다)
    static func fetchServerSync() -> (snapshot: ProviderSnapshot?, error: String?) {
        guard let exe = codexExecutable() else { return (nil, T("codex 명령을 찾지 못했습니다")) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = ["app-server"]
        process.currentDirectoryURL = URL(fileURLWithPath: homeDir)
        // Dock 에서 연 앱은 PATH 가 짧다. npm 으로 깐 codex 는 node 스크립트라 같은 폴더의 node 를 찾을 수 있게 앞에 붙인다.
        var env = ProcessInfo.processInfo.environment
        let exeDir = (exe as NSString).deletingLastPathComponent
        env["PATH"] = [exeDir, "/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"].joined(separator: ":")
        process.environment = env
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (nil, T("codex 를 실행하지 못했습니다")) }

        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: killer)
        defer {
            killer.cancel()
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        var buffer = Data()
        func send(_ line: String) -> Bool {
            (try? input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))) != nil
        }
        func receive(id: Int) -> [String: Any]? {
            while true {
                if let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.subdata(in: buffer.startIndex..<newline)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                       message["method"] == nil, (message["id"] as? NSNumber)?.intValue == id {
                        return message
                    }
                    continue
                }
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { return nil }  // 끝났거나 20초가 지나 끊었다
                buffer.append(chunk)
            }
        }

        guard send(#"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"ai-usage-widget","version":"1.0"}}}"#),
              receive(id: 1) != nil else { return (nil, T("codex 가 응답하지 않습니다")) }
        _ = send(#"{"method":"initialized"}"#)
        guard send(#"{"id":2,"method":"account/rateLimits/read"}"#),
              let response = receive(id: 2) else { return (nil, T("codex 가 응답하지 않습니다")) }
        guard let result = response["result"] as? [String: Any] else {
            return (nil, T("Codex 한도를 읽지 못했습니다(로그인 확인)"))
        }
        let byId = result["rateLimitsByLimitId"] as? [String: Any]
        let limits = (byId?["codex"] as? [String: Any]) ?? (result["rateLimits"] as? [String: Any]) ?? [:]
        var snap = ProviderSnapshot(windows: windows(from: limits), observedAt: Date(),
                                    plan: planName(limits["planType"] as? String))
        if snap.windows.isEmpty { snap.message = T("표시할 한도가 없습니다") }
        return (snap, nil)
    }
}

// MARK: - 세션 (지금 켜 둔 Claude Code·Codex 작업이 작업 중인지, 내 입력을 기다리는지, 끝났는지) — Windows 판 Sessions.cs 와 같은 규칙

/// 창에 놓는 순서도 이 순서: 입력 필요 → 작업 중 → 작업 완료 → 알 수 없음
enum SessionState: Int {
    case waiting, working, done, unknown
}

enum SessionTool { case claude, codex }

struct AgentSession: Identifiable {
    let id: String
    let tool: SessionTool
    let name: String
    let cwd: String
    let state: SessionState
    let since: Date  // 작업 중이면 시작한 때, 그 밖에는 그 상태가 된 때
    var background = false  // 답은 마쳤지만 뒤에서 명령이 아직 도는 Claude 세션
    var aborted = false  // 중단됐거나 끝 표시 없이 꺼진 Codex 작업(작업 완료로 보이고 메뉴에 「(중단됨)」)
    var titled = false  // Codex 앱이 붙인 대화 제목을 이름으로 쓴다
    var link: String?  // 그 대화를 여는 링크(Claude 데스크톱 앱 claude://…/epitaxy/local_…, Codex 앱 codex://threads/<id>)
    var pid: pid_t?  // 그 세션을 돌리는 프로세스(링크가 없는 터미널 세션은 그 터미널 앱을 앞으로)
}

/// 상태 순서대로, 같은 상태에서는 최근에 바뀐 것부터
func sortSessions(_ list: [AgentSession]) -> [AgentSession] {
    list.sorted { a, b in
        a.state.rawValue != b.state.rawValue ? a.state.rawValue < b.state.rawValue : a.since > b.since
    }
}

/// 보일 줄: 8개까지, 넘으면 7줄과 「외 N개」
let sessionMaxRows = 8
func visibleSessions(_ list: [AgentSession]) -> (shown: [AgentSession], hidden: Int) {
    list.count <= sessionMaxRows ? (list, 0) : (Array(list.prefix(sessionMaxRows - 1)), list.count - sessionMaxRows + 1)
}

func readJSONObject(_ path: String) -> [String: Any]? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

/// 실행 중인 프로세스의 실행 파일 경로(없으면 nil)
func executablePath(_ pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return String(cString: buffer)
}

/// 프로세스가 시작한 때(없으면 nil)
func processStart(_ pid: pid_t) -> Date? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
}

/// 부모 프로세스(없으면 nil)
func parentProcess(_ pid: pid_t) -> pid_t? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    let parent = pid_t(info.pbi_ppid)
    return parent > 1 && parent != pid ? parent : nil
}

/// 파일 끝에서 최대 maxBytes 만큼을 줄 단위로(맨 앞의 잘린 줄은 버림)
func tailLines(_ path: String, maxBytes: UInt64) -> [Data] {
    guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    let start = size > maxBytes ? size - maxBytes : 0
    try? handle.seek(toOffset: start)
    guard let data = try? handle.readToEnd() else { return [] }
    var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
    if start > 0, !lines.isEmpty { lines.removeFirst() }
    return lines.map { Data($0) }
}

/// 대화 기록 끝에서 읽은 것
struct TranscriptTail {
    var turnEndedAt: Date?  // 마지막 차례가 끝난 시각(turn_duration)
    var promptAt: Date?     // 차례가 아직 안 끝났으면 그 차례를 연 내 말의 시각
    var title: String?      // /rename 으로 붙인 이름(custom-title), 없으면 Claude 가 붙인 제목(ai-title)
}

/// Claude Code 는 실행 중인 세션마다 ~/.claude/sessions/<pid>.json 에 상태를 남긴다
/// (status: busy·shell=작업 중, waiting·blocked=입력 필요, idle=작업 완료). 터미널 CLI 와 데스크톱 앱 Code 탭 세션 모두.
/// 공식 문서에 없는 형식이라 모르는 값이 오면 「알 수 없음」으로 둔다.
final class ClaudeSessionReader {
    private var lastState: [String: SessionState] = [:]
    private var workingSince: [String: Date] = [:]
    private var transcriptPaths: [String: String] = [:]
    private var tailCache: [String: (size: UInt64, tail: TranscriptTail)] = [:]
    /// 세션마다 기록에서 마지막으로 찾은 제목. 긴 차례 도중에는 기록 끝 512KB 에 제목 줄이 없을 수 있어 앞의 것을 그대로 쓴다
    private var titles: [String: String] = [:]

    func read(now: Date) -> [AgentSession] {
        let dir = homeDir + "/.claude/sessions"
        var result: [AgentSession] = []
        var seen = Set<String>()
        for file in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where file.hasSuffix(".json") {
            guard let obj = readJSONObject(dir + "/" + file),
                  let pid = number(obj["pid"]).flatMap({ $0.isFinite && $0 >= 1 && $0 <= Double(Int32.max) ? pid_t($0) : nil }),
                  Self.alive(pid, procStart: obj["procStart"] as? String) else { continue }  // 꺼진 세션이 남긴 파일은 건너뛴다
            if let kind = obj["kind"] as? String, kind != "interactive" { continue }  // claude -p(이 앱의 /usage 조회 등)는 빼고
            let sessionId = obj["sessionId"] as? String ?? (file as NSString).deletingPathExtension
            let cwd = obj["cwd"] as? String ?? ""
            let changedAt = number(obj["statusUpdatedAt"]).map { Date(timeIntervalSince1970: $0 / 1000) } ?? now
            let key = "\(pid):\(sessionId)"
            seen.insert(key)

            // 차례 도중(작업 중·입력 필요)인 세션을 처음 보면 더 깊이(8MB) 읽는다 — 그 차례를 연 내 말과
            // 지난 차례 끝에 적힌 제목이 화면 캡처 등에 밀려 멀리 있을 수 있다. 끝난 세션은 제목이 기록 맨 끝에 있다
            let status = obj["status"] as? String
            let tail = transcriptTail(sessionId: sessionId, deep: lastState[key] == nil && status != "idle")
            if let title = tail.title { titles[sessionId] = title }
            let name = Self.sessionName(obj, title: titles[sessionId], cwd: cwd)

            var state: SessionState
            var since = changedAt
            var promptAt: Date?
            var background = false
            switch status {
            case "busy", "shell":
                // 뒤에서 도는 작업(백그라운드 명령 등)이 남아 있으면 답을 마친 뒤에도 busy 로 남는다 → 대화 기록 끝으로 가린다
                // (데스크톱 앱 Code 탭 세션은 기록에 차례 끝 표시가 없어 status 를 그대로 믿는다)
                if let ended = tail.turnEndedAt {
                    state = .done
                    since = ended
                    background = true
                } else {
                    state = .working
                    promptAt = tail.promptAt
                }
            case "idle": state = .done
            case "waiting", "blocked": state = .waiting
            default: state = .unknown
            }

            if state == .working {
                if lastState[key] == .working, let kept = workingSince[key] {
                    since = kept
                } else if let before = lastState[key], before != .working {
                    since = promptAt ?? now  // 이 앱이 보는 동안 작업 중으로 바뀜
                } else {
                    since = promptAt ?? changedAt  // 앱을 막 켰을 때
                }
                workingSince[key] = since
            } else {
                workingSince[key] = nil
            }
            lastState[key] = state
            // 데스크톱 앱 Code 탭 세션은 앱 사이드바의 세션 id(hostSessionId)로 그 세션을 바로 연다
            let host = obj["hostSessionId"] as? String
            let link = host.flatMap { $0.range(of: "^local_[0-9A-Za-z-]{1,64}$", options: .regularExpression) != nil ? "claude://claude.ai/epitaxy/" + $0 : nil }
            result.append(AgentSession(id: "claude:" + key, tool: .claude, name: name, cwd: cwd, state: state, since: since,
                                       background: background, link: link, pid: pid))
        }
        lastState = lastState.filter { seen.contains($0.key) }
        workingSince = workingSince.filter { seen.contains($0.key) }
        let liveIds = Set(seen.map { String($0.split(separator: ":", maxSplits: 1).last ?? "") })
        titles = titles.filter { liveIds.contains($0.key) }
        return result
    }

    /// 그 pid 가 아직 Claude Code 인가(실행 파일 경로에 claude — 맥의 Claude Code 는 실행 파일 이름이 판 번호다).
    /// procStart(프로세스 시작 시각, 맥에서는 「Mon Nov 16 00:53:33 2026」 UTC)가 있으면 같은 pid 를 다른 프로세스가 다시 쓴 것도 가린다
    static func alive(_ pid: pid_t, procStart: String?) -> Bool {
        guard pid > 0, let exe = executablePath(pid), exe.lowercased().contains("claude") else { return false }
        guard let text = procStart, let recorded = parseProcStart(text), let started = processStart(pid) else { return true }
        let gap = abs(started.timeIntervalSince(recorded))
        // 시간대를 붙이지 않고 적은 판이 있어도 놓치지 않게, 이 맥의 시간대만큼 어긋난 것도 같은 프로세스로 본다
        let zone = Double(abs(TimeZone.current.secondsFromGMT(for: started)))
        return gap < 2 || abs(gap - zone) < 2
    }

    private static let procStartFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return f
    }()

    static func parseProcStart(_ text: String) -> Date? {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return procStartFormat.date(from: words)
    }

    /// 보일 이름: 직접 붙인 이름(데스크톱 앱 사이드바 제목·/rename) → 대화 기록의 제목(Claude 가 붙인 것) → 지금 폴더 이름.
    /// sessions/<pid>.json 의 name 은 직접 붙이지 않았으면(nameSource 가 user 가 아니면) 켤 때 시작 폴더로 한 번 만든
    /// 「폴더-16진수 2자리」라서, 다른 폴더로 옮기거나 일이 바뀌어도 그대로다 — 그래서 쓰지 않는다.
    static func sessionName(_ obj: [String: Any], title: String?, cwd: String) -> String {
        let given = (obj["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if obj["nameSource"] as? String == "user", !given.isEmpty { return given }
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        let folder = folderName(cwd)
        return folder.isEmpty ? "Claude" : folder
    }

    /// 대화 기록(~/.claude/projects/<폴더>/<세션>.jsonl) 끝에서: 마지막 차례가 끝났는지(turn_duration), 아니면 그 차례를 연 내 말의 시각,
    /// 그리고 세션 제목
    private func transcriptTail(sessionId: String, deep: Bool) -> TranscriptTail {
        guard let path = transcriptPath(sessionId) else { return TranscriptTail() }
        // 기록이 그대로면 지난번 결과를 쓴다(3초마다 512KB 를 다시 읽지 않게)
        let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.uint64Value ?? 0
        if let cached = tailCache[path], cached.size == size { return cached.tail }
        let result = Self.scanTail(path, maxBytes: deep ? 8 << 20 : 512 << 10)
        tailCache[path] = (size, result)
        return result
    }

    static func scanTail(_ path: String, maxBytes: UInt64) -> TranscriptTail {
        var result = TranscriptTail()
        var turnFound = false
        var customTitle: String?
        var aiTitle: String?
        let customMark = Data("\"type\":\"custom-title\"".utf8)
        let aiMark = Data("\"type\":\"ai-title\"".utf8)
        for line in tailLines(path, maxBytes: maxBytes).reversed() {
            if turnFound && customTitle != nil && aiTitle != nil { break }
            // 제목 줄: Claude Code 가 차례마다 기록 끝에 다시 적는다. /resume 목록과 같이 custom-title 이 먼저다
            if line.range(of: customMark) != nil || line.range(of: aiMark) != nil {
                guard let entry = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                switch entry["type"] as? String {
                case "custom-title" where customTitle == nil: customTitle = entry["customTitle"] as? String
                case "ai-title" where aiTitle == nil: aiTitle = entry["aiTitle"] as? String
                default: break
                }
                continue
            }
            if turnFound { continue }
            guard line.range(of: Data("\"type\":\"user\"".utf8)) != nil
                    || line.range(of: Data("\"turn_duration\"".utf8)) != nil,
                  let entry = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            let at = (entry["timestamp"] as? String).flatMap(parseDate)
            switch entry["type"] as? String {
            case "system" where entry["subtype"] as? String == "turn_duration":
                result.turnEndedAt = at
                turnFound = true
            case "user":
                if entry["isMeta"] as? Bool == true { continue }
                let message = entry["message"] as? [String: Any]
                let parts = message?["content"] as? [[String: Any]] ?? []
                let types = Set(parts.compactMap { $0["type"] as? String })
                if message?["content"] is String || (!types.contains("tool_result") && !types.isEmpty) {
                    result.promptAt = at
                    turnFound = true
                }
            default:
                continue
            }
        }
        result.title = customTitle ?? aiTitle
        return result
    }

    private func transcriptPath(_ sessionId: String) -> String? {
        if let cached = transcriptPaths[sessionId], FileManager.default.fileExists(atPath: cached) { return cached }
        let root = homeDir + "/.claude/projects"
        for folder in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] {
            let path = "\(root)/\(folder)/\(sessionId).jsonl"
            if FileManager.default.fileExists(atPath: path) {
                transcriptPaths[sessionId] = path
                return path
            }
        }
        return nil
    }
}

/// 경로의 마지막 폴더 이름(끝의 / \ 는 무시)
func folderName(_ path: String) -> String {
    var trimmed = Substring(path)
    while let last = trimmed.last, last == "/" || last == "\\" { trimmed = trimmed.dropLast() }
    return trimmed.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
}

/// Codex 는 작업마다 ~/.codex/sessions/<날짜>/rollout-*.jsonl 에 기록을 남긴다.
/// 마지막 표시가 task_started 면 작업 중, task_complete 면 작업 완료, turn_aborted 면 중단(작업 완료로 보이고 메뉴에 「(중단됨)」).
/// 작업 중으로 남았는데 그 파일을 연 codex 프로세스가 없으면 도중에 꺼진 것(역시 중단).
/// Windows 판은 다른 프로세스가 연 파일을 알기 어려워 「기록이 20분 넘게 안 바뀌었거나 codex 가 없으면 중단」으로 본다 — 그 밖의 규칙은 같다.
final class CodexSessionReader {
    /// 끝난 작업을 창에 남겨 두는 시간
    static let keepFinished: TimeInterval = 30 * 60

    private struct Track {
        var offset: UInt64 = 0
        var cwd = ""
        var isSubagent = false
        var lastKind: String?
        var lastAt: Date?
    }
    private var tracks: [String: Track] = [:]
    private var threadNames: [String: String] = [:]
    private var namesSize: UInt64?

    func read(now: Date) -> [AgentSession] {
        let open = Self.openRolloutFiles()
        var files = Self.recentlyWritten(now: now)
        // 열려 있는 기록은 오래전에 바뀌었어도 본다(맥은 codex 가 연 파일을 바로 안다)
        for path in open where !files.contains(where: { $0.path == path }) {
            if let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date { files.append((path, mtime)) }
        }
        let names = threadNamesNow()
        var result: [AgentSession] = []
        var seen = Set<String>()
        for file in files {
            let isOpen = open.contains(file.path)
            if !isOpen && now.timeIntervalSince(file.mtime) > Self.keepFinished { continue }
            seen.insert(file.path)
            var track = tracks[file.path] ?? Track()
            Self.readNewLines(file.path, into: &track)
            tracks[file.path] = track
            if track.isSubagent { continue }  // Codex 가 스스로 띄운 하위 작업은 빼고 본 작업만

            let state: SessionState
            let since: Date
            var aborted = false
            switch track.lastKind {
            case "task_complete":
                state = .done; since = track.lastAt ?? file.mtime
            case "turn_aborted":
                state = .done; since = track.lastAt ?? file.mtime; aborted = true
            case "task_started" where isOpen:
                state = .working; since = track.lastAt ?? file.mtime
            case "task_started":
                state = .done; since = file.mtime; aborted = true
            default:
                continue  // 아직 시작한 작업이 없다
            }
            if state == .done && now.timeIntervalSince(since) > Self.keepFinished { continue }
            // 이름: Codex 앱이 붙인 대화 제목, 없으면(CLI) 작업 폴더
            let id = Self.threadId(file.path)
            let title = names[id]
            let folder = folderName(track.cwd)
            let name = title ?? (folder.isEmpty ? "Codex" : folder)
            result.append(AgentSession(id: "codex:" + file.path, tool: .codex, name: name, cwd: track.cwd, state: state, since: since,
                                       aborted: aborted, titled: title != nil, link: Self.threadLink(id)))
        }
        tracks = tracks.filter { seen.contains($0.key) }
        // 제목 없는 CLI 작업을 같은 폴더에서 다시 돌리면(설계 → 구현 등) 앞의 끝난 기록은 빼고 최근 것만.
        // 제목이 있는 Codex 앱 대화는 같은 폴더라도 서로 다른 대화라 그대로 둔다
        let latest = Dictionary(result.filter { !$0.titled }.map { ($0.cwd, $0.since) }, uniquingKeysWith: max)
        return result.filter { $0.titled || $0.state == .working || $0.cwd.isEmpty || $0.since >= latest[$0.cwd, default: $0.since] }
    }

    /// 최근(끝난 작업을 남겨 두는 시간 안)에 바뀐 rollout 기록. Codex 앱은 대화를 처음 만든 날짜 폴더(예: 10/30)에 계속 이어 쓰므로
    /// 날짜 폴더가 아니라 바뀐 시각으로 고른다
    static func recentlyWritten(now: Date) -> [(path: String, mtime: Date)] {
        let root = homeDir + "/.codex/sessions"
        guard let walker = FileManager.default.enumerator(atPath: root) else { return [] }
        var files: [(path: String, mtime: Date)] = []
        while let relative = walker.nextObject() as? String {
            let name = (relative as NSString).lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl"),
                  let mtime = walker.fileAttributes?[.modificationDate] as? Date,
                  now.timeIntervalSince(mtime) <= keepFinished else { continue }
            files.append((root + "/" + relative, mtime))
        }
        return files
    }

    /// rollout-2026-10-30T11-22-00-<대화 id>.jsonl 의 대화 id
    static func threadId(_ path: String) -> String {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return name.count > 36 ? String(name.suffix(36)) : name
    }

    /// Codex 앱에서 그 대화를 여는 링크(대화 id 가 UUID 모양일 때만)
    static func threadLink(_ id: String) -> String? {
        id.range(of: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", options: .regularExpression) != nil
            ? "codex://threads/" + id : nil
    }

    /// ~/.codex/session_index.jsonl: 대화 id 마다 제목(thread_name). 이름을 바꾸면 줄이 덧붙으므로 마지막 것이 지금 제목
    private func threadNamesNow() -> [String: String] {
        let path = homeDir + "/.codex/session_index.jsonl"
        let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.uint64Value ?? 0
        if size == namesSize { return threadNames }
        var next: [String: String] = [:]
        if let data = FileManager.default.contents(atPath: path) {
            for line in data.split(separator: 0x0A) {
                guard let entry = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                      let id = entry["id"] as? String,
                      let title = (entry["thread_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { continue }
                next[id] = title
            }
        }
        threadNames = next
        namesSize = size
        return next
    }

    /// 지난번 읽은 곳 다음부터 끝난 줄만 읽는다(기록은 수 MB 까지 커진다)
    private static func readNewLines(_ path: String, into track: inout Track) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < track.offset { track = Track() }  // 파일이 새로 쓰였으면 처음부터
        guard size > track.offset else { return }
        try? handle.seek(toOffset: track.offset)
        guard let data = try? handle.readToEnd(), let lastNewline = data.lastIndex(of: 0x0A) else { return }
        let complete = data[data.startIndex...lastNewline]
        track.offset += UInt64(complete.count)
        let markers = ["\"session_meta\"", "\"task_started\"", "\"task_complete\"", "\"turn_aborted\""].map { Data($0.utf8) }
        for line in complete.split(separator: 0x0A) where markers.contains(where: { line.range(of: $0) != nil }) {
            guard let entry = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let payload = entry["payload"] as? [String: Any] else { continue }
            let at = (entry["timestamp"] as? String).flatMap(parseDate)
            switch entry["type"] as? String {
            case "session_meta":
                track.cwd = payload["cwd"] as? String ?? track.cwd
                track.isSubagent = payload["source"] is [String: Any]  // 하위 작업은 source 가 {subagent: …}
            case "event_msg":
                if let kind = payload["type"] as? String, ["task_started", "task_complete", "turn_aborted"].contains(kind) {
                    track.lastKind = kind
                    track.lastAt = at
                }
            default:
                break
            }
        }
    }

    /// 실행 파일 이름이 codex 로 시작하는(대소문자 무시) 프로세스들이 열어 둔 rollout 기록 파일
    static func openRolloutFiles() -> Set<String> {
        var result = Set<String>()
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return result }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        for pid in pids.prefix(Int(max(0, filled))) where pid > 0 {
            guard let exe = executablePath(pid), (exe as NSString).lastPathComponent.lowercased().hasPrefix("codex") else { continue }
            let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard bytes > 0 else { continue }
            let stride = MemoryLayout<proc_fdinfo>.stride
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
            let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
            for fd in fds.prefix(Int(max(0, got)) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var info = vnode_fdinfowithpath()
                let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
                let path = withUnsafeBytes(of: info.pvip.vip_path) { raw in
                    String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
                }
                if path.contains("/rollout-") && path.hasSuffix(".jsonl") { result.insert(path) }
            }
        }
        return result
    }
}

/// 세션 줄을 누르면 그 대화를 연다: 데스크톱 앱 세션은 앱의 링크(claude://…, codex://threads/…)로 그 대화를,
/// 링크가 없는 터미널 세션은 그 프로세스를 띄운 터미널 앱(Ghostty·cmux·터미널 등)을 앞으로(어느 탭인지까지는 못 고른다)
enum SessionOpener {
    static func open(_ s: AgentSession) {
        if let link = s.link, let url = URL(string: link), NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
            return
        }
        guard let pid = s.pid, let app = terminalApp(of: pid), let bundle = app.bundleURL else { return }
        // 이 앱은 초점을 뺏지 않는 창이라 앞에 있지 않다 — macOS 14 부터는 앞에 없는 앱이 다른 앱을 직접 앞으로 못 꺼내므로
        // Finder·Dock 처럼 LaunchServices 로 「열기」를 해서 앞으로 가져온다(이미 떠 있으면 새로 띄우지 않는다)
        app.unhide()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: bundle, configuration: configuration)
    }

    /// 그 프로세스와 부모들 가운데 화면에 창을 띄우는 앱(Dock 에 보이는 앱). 12대까지 올라간다
    static func terminalApp(of pid: pid_t) -> NSRunningApplication? {
        var current: pid_t? = pid
        for _ in 0..<12 {
            guard let p = current else { return nil }
            if let app = NSRunningApplication(processIdentifier: p), app.activationPolicy == .regular { return app }
            current = parentProcess(p)
        }
        return nil
    }
}

// MARK: - 글자

private func makeFormatter(_ format: String) -> DateFormatter {
    let f = DateFormatter()
    f.locale = Locale(identifier: "ko_KR")
    f.dateFormat = format
    return f
}
private var formatters: [String: DateFormatter] = [:]
private let formattersLock = NSLock()

/// 고른 언어의 시각 형식(요일 이름 등). 언어마다 한 번 만들어 둔다.
private func formatter(_ format: String) -> DateFormatter {
    let key = L10n.current + "|" + format
    formattersLock.lock()
    defer { formattersLock.unlock() }
    if let cached = formatters[key] { return cached }
    let made = DateFormatter()
    made.locale = L10n.locale
    made.dateFormat = format
    formatters[key] = made
    return made
}

func clock(_ date: Date) -> String { formatter("HH:mm").string(from: date) }
func fullTime(_ date: Date) -> String { formatter(T("M월 d일(E) HH:mm")).string(from: date) }

func resetText(_ date: Date?, now: Date) -> String {
    guard let date else { return "" }
    if date <= now { return T("초기화됨") }
    if Calendar.current.isDate(date, inSameDayAs: now) { return clock(date) }
    return formatter(date.timeIntervalSince(now) < 6 * 86_400 ? "E HH:mm" : "M/d").string(from: date)
}

func ageText(_ date: Date?, now: Date) -> String {
    guard let date else { return "" }
    let seconds = max(0, now.timeIntervalSince(date))
    if seconds < 60 { return T("방금") }
    if seconds < 3_600 { return T("{0}분 전", Int(seconds / 60)) }
    if seconds < 86_400 { return T("{0}시간 전", Int(seconds / 3_600)) }
    return T("{0}일 전", Int(seconds / 86_400))
}

/// 「12분」「1시간 5분」, 1분이 안 되면 nil
func durationText(since: Date, now: Date) -> String? {
    let minutes = Int(max(0, now.timeIntervalSince(since)) / 60)
    if minutes < 1 { return nil }
    if minutes < 60 { return T("{0}분", minutes) }
    return minutes % 60 == 0 ? T("{0}시간", minutes / 60) : T("{0}시간 {1}분", minutes / 60, minutes % 60)
}

/// 세션 줄 오른쪽 글자: 「작업 중 12분」「입력 필요」「작업 완료 8분 전」(Windows 판 AgentSession.StatusText 와 같다)
func sessionStatusText(_ s: AgentSession, now: Date) -> String {
    switch s.state {
    case .working: return [T("작업 중"), durationText(since: s.since, now: now)].compactMap { $0 }.joined(separator: " ")
    case .waiting: return T("입력 필요")
    case .done: return T("작업 완료 {0}", ageText(s.since, now: now))
    case .unknown: return T("알 수 없음")
    }
}

/// 메뉴·--print 한 줄: 「Claude · 이름 — 작업 중 12분 · ~/폴더」
func describeSession(_ s: AgentSession, now: Date) -> String {
    let home = homeDir
    let place = s.cwd.hasPrefix(home) ? "~" + s.cwd.dropFirst(home.count) : s.cwd
    let note = s.background ? " " + T("(뒤에서 명령이 아직 도는 중)") : s.aborted ? " " + T("(중단됨)") : ""
    return "\(s.tool == .claude ? "Claude" : "Codex") · \(s.name) — \(sessionStatusText(s, now: now))\(note)\(place.isEmpty ? "" : " · \(place)")"
}

/// 「세션」 아래 한 줄씩(--print·--sessions, Windows 판 Report.DescribeSessions 와 같다)
func describeSessions(_ sessions: [AgentSession], now: Date) -> String {
    var lines = [T("세션")]
    lines += sessions.isEmpty ? ["  " + T("열린 세션이 없습니다")] : sessions.map { "  " + describeSession($0, now: now) }
    return lines.joined(separator: "\n")
}

/// 상태 표시줄과 같은 기준: 50% 이상 초록, 20% 이상 노랑, 그 아래 빨강
func statusColor(_ left: Int) -> Color {
    if left >= 50 { return Color(nsColor: .systemGreen) }
    if left >= 20 { return Color(nsColor: .systemYellow) }
    return Color(nsColor: .systemRed)
}

func describe(_ title: String, _ snap: ProviderSnapshot, now: Date) -> String {
    var lines = [T("{0} — 마지막 값 {1}", title + (snap.plan.map { " (\($0))" } ?? ""), snap.observedAt.map(fullTime) ?? T("없음"))]
    if snap.windows.isEmpty { lines.append("  \(snap.message ?? T("값 없음"))") }
    for w in snap.windows {
        lines.append("  " + T("{0}: 사용 {1}% → {2}% 남음, 초기화 {3}", w.label, w.usedPercent, w.leftPercent(now: now), w.resetsAt.map(fullTime) ?? "-"))
    }
    return lines.joined(separator: "\n")
}

// MARK: - 화면

/// 창에 보일 칸 — 오른쪽 클릭·Dock 메뉴에서 고르고 기억한다(처음엔 둘 다, 하나는 꼭 남는다)
enum Shown {
    static let claudeKey = "showClaude"
    static let codexKey = "showCodex"
    static let sessionsKey = "showSessions"
    static let modelsKey = "showModelLimits"  // 모델별 한도(Fable 등) 줄 — 처음엔 켜짐
    static let modelAlertsKey = "modelLimitAlerts"  // 모델별 한도도 알림 — 처음엔 꺼짐
    // 칸 접기(머리줄을 누르면 접고 펴고, 기억한다 — Windows 판 FoldSessions·FoldClaude·FoldCodex)
    static let foldSessionsKey = "foldSessions"
    static let foldClaudeKey = "foldClaude"
    static let foldCodexKey = "foldCodex"
    static func get(_ key: String) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
    static func folded(_ key: String) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? false }
}

/// 표시 방식: 떠 있는 창(0) 또는 메뉴 막대 간단 모드(1), 그리고 메뉴 막대 게이지 크기(75 작게, 100 크게) — Windows 판 DisplayMode·TaskbarSize
enum Display {
    static let modeKey = "displayMode"
    static let sizeKey = "menuBarSize"
    static var mode: Int {
        get { [0, 1].contains(UserDefaults.standard.integer(forKey: modeKey)) ? UserDefaults.standard.integer(forKey: modeKey) : 0 }
        set { UserDefaults.standard.set(newValue, forKey: modeKey) }
    }
    static var size: Int {
        get { UserDefaults.standard.integer(forKey: sizeKey) == 75 ? 75 : 100 }
        set { UserDefaults.standard.set(newValue, forKey: sizeKey) }
    }
}

/// 창 안 칸. 순서는 「칸 순서」 메뉴에서 고르고 기억한다(처음엔 세션 → Claude → ChatGPT)
enum Pane: String {
    case sessions, claude, codex

    static let orderKey = "paneOrder"
    static let standard: [Pane] = [.sessions, .claude, .codex]
    /// 메뉴에 나오는 순서 전부(3칸이면 6가지). 맨 앞이 기본.
    static let orders: [[Pane]] = [
        [.sessions, .claude, .codex], [.sessions, .codex, .claude],
        [.claude, .codex, .sessions], [.codex, .claude, .sessions],
        [.claude, .sessions, .codex], [.codex, .sessions, .claude],
    ]

    var title: String {
        switch self {
        case .sessions: return T("세션")
        case .claude: return "Claude"
        case .codex: return "ChatGPT"
        }
    }

    /// 저장된 순서. 빠졌거나 모르는 칸은 기본 순서대로 뒤에 채운다(칸이 늘거나 줄어도 깨지지 않게)
    static func loadOrder() -> [Pane] {
        var result: [Pane] = []
        for pane in (UserDefaults.standard.stringArray(forKey: orderKey) ?? []).compactMap(Pane.init(rawValue:))
        where !result.contains(pane) { result.append(pane) }
        for pane in standard where !result.contains(pane) { result.append(pane) }
        return result
    }
}

enum PetSetting: String, CaseIterable {
    case background = "petBackgroundLevel", window = "petWindowPercent", text = "petTextPercent"

    var values: [Int] {
        switch self {
        case .background: return [0, 1, 2, 3]
        case .window: return [85, 100, 115, 130]
        case .text: return [90, 100, 115, 130]
        }
    }
    var title: String {
        switch self {
        case .background: return T("배경 투명도")
        case .window: return T("창 크기")
        case .text: return T("글자 크기")
        }
    }
    var labels: [String] {
        self == .background ? [T("없음"), T("조금"), T("중간"), T("많이")] :
            [T("작게"), T("보통"), T("크게"), T("아주 크게")]
    }
}

struct PetAppearance {
    var background = 0
    var window = 100
    var text = 100

    subscript(setting: PetSetting) -> Int {
        get {
            switch setting {
            case .background: return background
            case .window: return window
            case .text: return text
            }
        }
        set {
            switch setting {
            case .background: background = newValue
            case .window: window = newValue
            case .text: text = newValue
            }
        }
    }

    static func load() -> Self {
        var result = Self()
        for setting in PetSetting.allCases {
            guard let n = UserDefaults.standard.object(forKey: setting.rawValue) as? NSNumber,
                  CFGetTypeID(n) != CFBooleanGetTypeID(), !CFNumberIsFloatType(n),
                  setting.values.contains(n.intValue) else { continue }
            result[setting] = n.intValue
        }
        return result
    }

    var opacity: Double { [1, 0.70, 0.48, 0.26][background] }
    func length(_ points: CGFloat) -> CGFloat { points * CGFloat(window) / 100 }
    func typeSize(_ points: CGFloat) -> CGFloat { length(points) * CGFloat(text) / 100 }
    /// 모델별 줄(예: 「Fable」)처럼 긴 칸 이름에 맞춰 이름 칸을 늘린 만큼(기본 글자 크기 기준, 최대 64) — 늘린 만큼 창도 넓어진다
    var labelExtra: CGFloat = 0
    var labelWidth: CGFloat { (L10n.current == "en" ? 40 : 30) + labelExtra }
    var width: CGFloat { length(290 + (labelWidth + 62 + 70) * CGFloat(text - 100) / 100 + labelExtra) }

    @ViewBuilder func shaded(_ text: Text) -> some View {
        if background == 3 {
            text.background {
                text.foregroundStyle(.black)
                    .shadow(color: .black, radius: length(2))
                    .compositingGroup()
                    .opacity(0.55)
                    .offset(y: length(1))
                    .accessibilityHidden(true)
            }
        } else { text }
    }
}

private struct PetAppearanceKey: EnvironmentKey { static let defaultValue = PetAppearance() }
extension EnvironmentValues {
    var petAppearance: PetAppearance {
        get { self[PetAppearanceKey.self] }
        set { self[PetAppearanceKey.self] = newValue }
    }
}

final class UsageModel: ObservableObject {
    @Published var appearance = PetAppearance.load()
    @Published var order = Pane.loadOrder()
    @Published var claude = ProviderSnapshot()
    @Published var codex = ProviderSnapshot()
    @Published var sessions: [AgentSession] = []
    @Published var now = Date()
    @Published var showClaude = Shown.get(Shown.claudeKey)
    @Published var showCodex = Shown.get(Shown.codexKey)
    @Published var showSessions = Shown.get(Shown.sessionsKey)
    @Published var showModels = Shown.get(Shown.modelsKey)
    @Published var foldSessions = Shown.folded(Shown.foldSessionsKey)
    @Published var foldClaude = Shown.folded(Shown.foldClaudeKey)
    @Published var foldCodex = Shown.folded(Shown.foldCodexKey)
    /// 마우스가 올라간 세션 줄(밝은 바탕)
    @Published var hovered: String?
    /// 누를 수 있는 곳(떠 있는 창·세션 패널 안 좌표, 위에서부터). 그릴 때마다 바뀌므로 다시 그리게 하지 않는다
    var hits: [HitTarget: CGRect] = [:]
    var panelHits: [HitTarget: CGRect] = [:]
}

let claudeTint = Color(red: 0.851, green: 0.467, blue: 0.341)
let codexTint = Color(red: 0.063, green: 0.639, blue: 0.498)

/// 누를 수 있는 곳: 칸 머리줄(접고 펴기), 세션 줄(그 대화 열기). 창 안 좌표(위에서부터)는 HitTargetKey 로 모은다
enum HitTarget: Hashable {
    case header(Pane)
    case session(String)
}

struct HitTargetKey: PreferenceKey {
    static let defaultValue: [HitTarget: CGRect] = [:]
    static func reduce(value: inout [HitTarget: CGRect], nextValue: () -> [HitTarget: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// 이 뷰의 자리를 이름 붙인 좌표계(떠 있는 창 「pet」, 세션 패널 「panel」) 안에서 남긴다
    func hitTarget(_ target: HitTarget, in space: String) -> some View {
        background(GeometryReader { geo in
            Color.clear.preference(key: HitTargetKey.self, value: [target: geo.frame(in: .named(space))])
        })
    }
}

func hitTarget(at point: NSPoint, in hits: [HitTarget: CGRect]) -> HitTarget? {
    // 세션 줄이 머리줄보다 먼저(겹치지 않지만 혹시 겹치면 줄을 고른다)
    let found = hits.filter { $0.value.contains(point) }.map(\.key)
    return found.first { if case .session = $0 { return true } else { return false } } ?? found.first
}

struct PetView: View {
    @ObservedObject var model: UsageModel

    var body: some View {
        let look = model.appearance
        // 고른 순서대로, 켜 둔 칸만(세션은 열린 세션이 있을 때만). 칸 사이에만 구분선을 넣는다.
        let panes = model.order.filter(isShown)
        VStack(alignment: .leading, spacing: look.length(9)) {
            ForEach(Array(panes.enumerated()), id: \.element) { index, pane in
                if index > 0 {
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: look.length(1))
                }
                paneView(pane)
            }
        }
        .padding(.horizontal, look.length(12))
        .padding(.vertical, look.length(10))
        .frame(width: look.width)
        .coordinateSpace(name: "pet")
        .onPreferenceChange(HitTargetKey.self) { [model] hits in model.hits = hits }
        .environment(\.petAppearance, look)
    }

    private func isShown(_ pane: Pane) -> Bool {
        switch pane {
        case .sessions: return model.showSessions && !model.sessions.isEmpty
        case .claude: return model.showClaude
        case .codex: return model.showCodex
        }
    }

    @ViewBuilder private func paneView(_ pane: Pane) -> some View {
        let look = model.appearance
        // 접은 Claude·ChatGPT 의 막대가 같은 자리에서 시작하게 이름 칸은 긴 쪽 너비로
        let nameFont = NSFont.systemFont(ofSize: look.typeSize(12), weight: .semibold)
        let nameColumn = ["Claude", "ChatGPT"].map { ($0 as NSString).size(withAttributes: [.font: nameFont]).width.rounded(.up) }.max() ?? 0
        switch pane {
        case .sessions:
            SessionSection(sessions: model.sessions, now: model.now, folded: model.foldSessions, hovered: model.hovered)
        case .claude:
            ProviderSection(pane: .claude, name: "Claude", detail: nil, color: claudeTint, snap: model.claude, now: model.now,
                            showModels: model.showModels, folded: model.foldClaude, nameColumn: nameColumn)
        case .codex:
            ProviderSection(pane: .codex, name: "ChatGPT", detail: ["Codex", model.codex.plan].compactMap { $0 }.joined(separator: " · "),
                            color: codexTint, snap: model.codex, now: model.now, showModels: model.showModels,
                            folded: model.foldCodex, nameColumn: nameColumn)
        }
    }
}

/// 머리줄 오른쪽 끝: 펼침 ▲ / 접힘 ▼ (누르면 바뀐다)
struct Caret: View {
    @Environment(\.petAppearance) private var look
    let folded: Bool

    var body: some View {
        Path { p in
            let w = look.length(8), h = look.length(8) * 0.55
            if folded {
                p.move(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: w, y: 0)); p.addLine(to: CGPoint(x: w / 2, y: h))
            } else {
                p.move(to: CGPoint(x: 0, y: h)); p.addLine(to: CGPoint(x: w, y: h)); p.addLine(to: CGPoint(x: w / 2, y: 0))
            }
            p.closeSubpath()
        }
        .fill(Color(nsColor: .tertiaryLabelColor))
        .frame(width: look.length(8), height: look.length(8) * 0.55)
    }
}

struct ProviderSection: View {
    @Environment(\.petAppearance) private var look

    let pane: Pane
    let name: String
    let detail: String?
    let color: Color
    let snap: ProviderSnapshot
    let now: Date
    var showModels = true
    var folded = false
    var nameColumn: CGFloat = 0

    var body: some View {
        let windows = snap.visibleWindows(showModels: showModels)
        VStack(alignment: .leading, spacing: look.length(5)) {
            if folded { foldedHeader } else { header }
            if !folded {
                if windows.isEmpty {
                    look.shaded(Text(snap.message ?? T("값이 없습니다"))).font(.system(size: look.typeSize(11))).foregroundStyle(.secondary)
                }
                ForEach(windows) { window in
                    WindowRow(window: window, now: now)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: look.length(6)) {
            Circle().fill(color).frame(width: look.length(7), height: look.length(7))
            look.shaded(Text(name)).font(.system(size: look.typeSize(12), weight: .semibold))
            if let detail, !detail.isEmpty {
                look.shaded(Text(detail)).font(.system(size: look.typeSize(10))).foregroundStyle(.secondary)
            }
            Spacer(minLength: look.length(4))
            look.shaded(Text(ageText(snap.observedAt, now: now))).font(.system(size: look.typeSize(10))).foregroundStyle(.tertiary)
            Caret(folded: false)
        }
        .contentShape(Rectangle())
        .hitTarget(.header(pane), in: "pet")
    }

    /// 「● Claude ▬▬── 26% ▼」: 주간 한도만(없으면 첫 한도)
    private var foldedHeader: some View {
        let weekly = snap.windows.first { $0.name == nil && $0.minutes == 10_080 } ?? snap.windows.first { $0.name == nil }
        let percentFont = NSFont.monospacedDigitSystemFont(ofSize: look.typeSize(11), weight: .semibold)
        let percentWidth = ("100%" as NSString).size(withAttributes: [.font: percentFont]).width.rounded(.up)
        return HStack(spacing: look.length(6)) {
            Circle().fill(color).frame(width: look.length(7), height: look.length(7))
            look.shaded(Text(name)).font(.system(size: look.typeSize(12), weight: .semibold))
                .frame(width: nameColumn + look.length(4), alignment: .leading)
            if let weekly {
                let left = weekly.leftPercent(now: now)
                let tint = statusColor(left)
                Bar(fraction: Double(left) / 100, color: tint)
                look.shaded(Text("\(left)%")).font(.system(size: look.typeSize(11), weight: .semibold).monospacedDigit())
                    .foregroundStyle(tint).frame(width: percentWidth, alignment: .trailing)
            } else {
                look.shaded(Text(snap.message ?? T("값이 없습니다"))).font(.system(size: look.typeSize(10))).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            Caret(folded: true)
        }
        .contentShape(Rectangle())
        .hitTarget(.header(pane), in: "pet")
    }
}

struct WindowRow: View {
    @Environment(\.petAppearance) private var look

    let window: LimitWindow
    let now: Date

    var body: some View {
        let left = window.leftPercent(now: now)
        let tint = statusColor(left)
        let reset = resetText(window.resetsAt, now: now)
        HStack(spacing: look.length(8)) {
            look.shaded(Text(window.label)).font(.system(size: look.typeSize(11))).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail).frame(width: look.typeSize(look.labelWidth), alignment: .leading)
            Bar(fraction: Double(left) / 100, color: tint)
            look.shaded(Text(T("{0}% 남음", left))).font(.system(size: look.typeSize(11), weight: .semibold).monospacedDigit())
                .foregroundStyle(tint).frame(width: look.typeSize(62), alignment: .trailing)
            Group {
                if reset.isEmpty || reset == T("초기화됨") {
                    look.shaded(Text(reset))
                } else {
                    look.shaded(Text("\(Image(systemName: "arrow.counterclockwise")) \(reset)"))
                }
            }
            .font(.system(size: look.typeSize(10)).monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: look.typeSize(70), alignment: .trailing)
        }
    }
}

struct Bar: View {
    @Environment(\.petAppearance) private var look

    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(color).frame(width: max(look.length(3), geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: look.length(5))
    }
}

/// 세션 칸 — 머리줄 「≡ 세션 ▲」(접으면 「입력 1 · 진행 2 · 완료 2 ▼」) 아래 한 줄씩
struct SessionSection: View {
    @Environment(\.petAppearance) private var look

    let sessions: [AgentSession]
    let now: Date
    var folded = false
    var hovered: String?
    var space = "pet"

    var body: some View {
        VStack(alignment: .leading, spacing: look.length(5)) {
            HStack(spacing: look.length(6)) {
                Image(systemName: "list.bullet").font(.system(size: look.length(10), weight: .semibold)).foregroundStyle(.secondary).frame(width: look.length(7))
                look.shaded(Text(T("세션"))).font(.system(size: look.typeSize(12), weight: .semibold))
                Spacer(minLength: look.length(4))
                if folded { SessionCounts(sessions: sessions) }
                Caret(folded: folded)
            }
            .contentShape(Rectangle())
            .hitTarget(.header(.sessions), in: space)
            if !folded {
                SessionRows(sessions: sessions, now: now, hovered: hovered, space: space)
            }
        }
    }
}

/// 접은 세션 칸의 개수: 0개는 빼고, 입력 필요는 주황·작업 중은 파랑·작업 완료는 회색
struct SessionCounts: View {
    @Environment(\.petAppearance) private var look
    let sessions: [AgentSession]

    var body: some View {
        let entries: [(state: SessionState, text: String, color: Color)] = [
            (.waiting, T("입력 {0}", count(.waiting)), sessionTint(.waiting)),
            (.working, T("진행 {0}", count(.working)), sessionTint(.working)),
            (.done, T("완료 {0}", count(.done)), Color.secondary),
        ]
        let parts = entries.filter { count($0.state) > 0 }
        HStack(spacing: 0) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 { look.shaded(Text(" · ")).foregroundStyle(.tertiary) }
                look.shaded(Text(part.text)).foregroundStyle(part.color)
            }
        }
        .font(.system(size: look.typeSize(10)).monospacedDigit())
        .fixedSize()
    }

    private func count(_ state: SessionState) -> Int { sessions.filter { $0.state == state }.count }
}

/// 세션 줄들: 8개까지, 넘으면 7줄과 「외 N개」
struct SessionRows: View {
    @Environment(\.petAppearance) private var look
    let sessions: [AgentSession]
    let now: Date
    var hovered: String?
    var space = "pet"

    var body: some View {
        let (shown, hidden) = visibleSessions(sessions)
        ForEach(shown) { session in
            SessionRow(session: session, now: now, hovered: hovered == session.id)
                .hitTarget(.session(session.id), in: space)
        }
        if hidden > 0 {
            look.shaded(Text(T("외 {0}개", hidden))).font(.system(size: look.typeSize(10))).foregroundStyle(.tertiary)
                .padding(.leading, look.length(11))
        }
    }
}

/// 세션 상태 색: 입력 필요 주황, 작업 중 파랑, 작업 완료 초록, 그 밖엔 흐린 회색
func sessionTint(_ state: SessionState) -> Color {
    switch state {
    case .waiting: return Color(nsColor: .systemOrange)
    case .working: return Color(nsColor: .systemBlue)
    case .done: return Color(nsColor: .systemGreen)
    case .unknown: return Color(nsColor: .tertiaryLabelColor)
    }
}

/// 세션 한 줄: 「● 이름 ……………… ◌ 작업 중 12분」 — 앞의 점은 도구(주황 Claude, 초록 Codex). Windows 판과 같은 모양
struct SessionRow: View {
    @Environment(\.petAppearance) private var look

    let session: AgentSession
    let now: Date
    var hovered = false

    var body: some View {
        let tint = sessionTint(session.state)
        HStack(spacing: look.length(6)) {
            Circle().fill(session.tool == .claude ? claudeTint : codexTint).frame(width: look.length(5), height: look.length(5))
            look.shaded(Text(session.name)).font(.system(size: look.typeSize(11))).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: look.length(6))
            HStack(spacing: look.length(4)) {
                SessionIcon(state: session.state, color: tint)
                look.shaded(Text(sessionStatusText(session, now: now)))
                    .font(.system(size: look.typeSize(10), weight: .medium).monospacedDigit())
                    .foregroundStyle(tint)
            }
            .fixedSize()
        }
        .contentShape(Rectangle())
        .background {
            if hovered {
                RoundedRectangle(cornerRadius: look.length(5)).fill(Color.white.opacity(0.12))
                    .padding(.horizontal, -look.length(5)).padding(.vertical, -look.length(2.5))
            }
        }
    }
}

/// 상태 기호: 작업 중은 도는 고리, 입력 필요는 주황 동그라미 안 「!」, 작업 완료는 초록 체크, 알 수 없음은 비움
struct SessionIcon: View {
    @Environment(\.petAppearance) private var look
    let state: SessionState
    let color: Color

    var body: some View {
        Group {
            switch state {
            case .working:
                if renderingStill || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    Circle().trim(from: 0, to: 0.75)
                        .stroke(color, style: StrokeStyle(lineWidth: max(1.5, look.length(1.6)), lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(look.length(1.5))
                } else {
                    SpinningArc(color: .systemBlue, lineWidth: max(1.5, look.length(1.6)))
                }
            case .waiting:
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: look.length(11), weight: .semibold)).foregroundStyle(color)
            case .done:
                Image(systemName: "checkmark").font(.system(size: look.length(9.5), weight: .bold)).foregroundStyle(color)
            case .unknown:
                Color.clear
            }
        }
        .frame(width: look.length(12), height: look.length(12))
    }
}

/// 그림 저장(--snapshot) 중에는 도는 표시 대신 멈춘 기호를 그린다(ImageRenderer 는 AppKit 뷰를 못 그린다)
var renderingStill = false

/// 작업 중 표시 — 270° 고리가 1.5초에 한 바퀴 돈다(Windows 판과 같은 모양). 회전은 Core Animation 에 맡겨 화면 합성기가 돌리므로
/// 앱 CPU 를 거의 안 쓴다(SwiftUI 애니메이션은 앱이 매 프레임 다시 그려 3~5% 를 썼다). 「동작 줄이기」를 켜 두면 멈춰 있다.
struct SpinningArc: NSViewRepresentable {
    let color: NSColor
    let lineWidth: CGFloat
    func makeNSView(context: Context) -> SpinnerView { SpinnerView(frame: .zero) }
    func updateNSView(_ view: SpinnerView, context: Context) {
        view.configure(color: color, lineWidth: lineWidth)
    }
}

final class SpinnerView: NSView {
    private let arc = CAShapeLayer()
    private var lineWidth: CGFloat = 1.5

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        arc.fillColor = nil
        arc.lineCap = .round
        layer?.addSublayer(arc)
    }

    required init?(coder: NSCoder) { nil }

    func configure(color: NSColor, lineWidth: CGFloat) {
        arc.strokeColor = color.cgColor
        self.lineWidth = lineWidth
        arc.lineWidth = lineWidth
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.bounds = bounds
        arc.position = CGPoint(x: bounds.midX, y: bounds.midY)  // 가운데를 축으로 돈다
        let inset = lineWidth / 2 + max(0, (bounds.width - bounds.width * 0.82) / 2)
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2, startAngle: .pi / 2,
                    endAngle: .pi / 2 - 1.5 * .pi, clockwise: true)
        arc.path = path
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        arc.contentsScale = window.backingScaleFactor
        guard arc.animation(forKey: "spin") == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi  // 시계 방향
        spin.duration = 1.5
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        arc.add(spin, forKey: "spin")
    }
}

// MARK: - 창

/// 글자 위를 눌러도 창이 끌리도록 클릭은 모두 이 뷰가 받는다(누를 곳은 PanelInput 이 가려낸다)
final class ContainerView: NSVisualEffectView {
    let input = PanelInput()

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { input.mouseDown(event, in: window) }
    override func rightMouseUp(with event: NSEvent) { input.onRightClick?(event) }
    override func updateTrackingAreas() { super.updateTrackingAreas(); input.track(self) }
    override func mouseMoved(with event: NSEvent) { input.moved(event) }
    override func mouseExited(with event: NSEvent) { input.onHover?(nil) }
}

final class TranslucentRoot: NSView {
    let input = PanelInput()

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { input.mouseDown(event, in: window) }
    override func rightMouseUp(with event: NSEvent) { input.onRightClick?(event) }
    override func updateTrackingAreas() { super.updateTrackingAreas(); input.track(self) }
    override func mouseMoved(with event: NSEvent) { input.moved(event) }
    override func mouseExited(with event: NSEvent) { input.onHover?(nil) }
}

/// 떠 있는 창·세션 패널의 마우스: 끌면 창을 옮기고(draggable), 끌지 않고 눌렀다 떼면 그 자리를 onClick 으로,
/// 마우스를 올리면 onHover 로(앞에 있지 않은 창이어도). 자리는 SwiftUI 와 같은 좌표(내용의 왼쪽 위에서부터)
final class PanelInput {
    var draggable = true
    var onClick: ((NSPoint) -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    var onHover: ((NSPoint?) -> Void)?
    /// 좌표를 잴 뷰(SwiftUI 를 품은 뷰)
    weak var content: NSView?
    private var area: NSTrackingArea?

    func point(_ event: NSEvent) -> NSPoint? {
        guard let content else { return nil }
        let p = content.convert(event.locationInWindow, from: nil)
        return NSPoint(x: p.x, y: content.isFlipped ? p.y : content.bounds.height - p.y)
    }

    func mouseDown(_ event: NSEvent, in window: NSWindow?) {
        guard let window else { return }
        let startMouse = NSEvent.mouseLocation
        let startOrigin = window.frame.origin
        var moved = false
        // 손을 뗄 때까지: 3pt 넘게 움직이면 창을 옮기고, 아니면 누른 것으로 본다
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if next.type == .leftMouseUp { break }
            let now = NSEvent.mouseLocation
            if !moved && hypot(now.x - startMouse.x, now.y - startMouse.y) < 3 { continue }
            guard draggable else { continue }
            moved = true
            window.setFrameOrigin(NSPoint(x: startOrigin.x + now.x - startMouse.x, y: startOrigin.y + now.y - startMouse.y))
        }
        if !moved, let p = point(event) { onClick?(p) }
    }

    func moved(_ event: NSEvent) { onHover?(point(event)) }

    func track(_ view: NSView) {
        if let area { view.removeTrackingArea(area) }
        let next = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: view, userInfo: nil)
        view.addTrackingArea(next)
        area = next
    }
}

func roundedMask(radius: CGFloat) -> NSImage {
    let edge = radius * 2 + 1
    let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
}

// MARK: - 메뉴 막대 간단 모드

/// 메뉴 막대 간단 모드: 시계 왼쪽에 한도마다 동그란 게이지(Windows 판 TaskbarGauge 와 같은 그림).
/// 테두리 길이가 남은 비율, 가운데 숫자가 남은 %, 앞의 색 점이 회사(주황 Claude, 초록 ChatGPT).
/// 입력이 필요한 세션이 있으면 맨 앞에 주황 「!」. 왼쪽 클릭 = 세션 패널, 오른쪽 클릭 = 메뉴(한 번·두 번은 AppDelegate 가 가린다)
final class MenuBarGauge: NSObject, NSViewToolTipOwner {
    /// 원 하나: 마우스를 올리면 보일 글과 남은 %(값이 없으면 nil)
    struct Ring { let tip: String; let left: Int? }
    /// 회사 하나: 앞의 색 점과 원들
    struct Group { let dot: NSColor; let rings: [Ring] }

    /// 그릴 것 하나(왼쪽 끝 x)
    fileprivate enum Mark { case badge, separator, dot(NSColor), ring(Int?) }
    struct Layout {
        fileprivate var marks: [(x: CGFloat, mark: Mark)] = []
        var hits: [(x: CGFloat, width: CGFloat, tip: String)] = []
        var size = NSSize.zero
        var ring: CGFloat = 0, gap: CGFloat = 0, dot: CGFloat = 0, badge: CGFloat = 0, stroke: CGFloat = 0
    }

    private let item: NSStatusItem
    var onLeftClick: (() -> Void)?
    var onRightClick: (() -> Void)?
    private var tips: [NSView.ToolTipTag: String] = [:]
    private var drawnKey: String?

    override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        item.autosaveName = "AIUsageGauge"  // ⌘ 를 누르고 끌어 옮긴 자리를 기억한다
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel(T("AI 사용량"))
        }
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { onRightClick?() } else { onLeftClick?() }
    }

    func remove() { NSStatusBar.system.removeStatusItem(item) }

    /// 게이지 단추의 창(이 창을 누른 것은 세션 패널 바깥 클릭이 아니다)
    var window: NSWindow? { item.button?.window }

    /// 게이지가 화면에 놓인 자리(세션 패널을 그 아래에 띄운다)
    var screenFrame: NSRect? {
        guard let button = item.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    /// 메뉴 막대 게이지 자리에서 메뉴를 연다(메뉴 막대 아이콘 메뉴처럼 바로 아래에)
    func showMenu(_ menu: NSMenu) {
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    /// 자리 잡기 — Windows 판 Render 와 같은 비율(원 지름 = 메뉴 막대 높이 - 6pt, 작게는 그 75%)
    static func layout(groups: [Group], waiting: Int, size: Int, barHeight: CGFloat) -> Layout {
        var l = Layout()
        l.ring = max(12, ((barHeight - 6) * CGFloat(size) / 100).rounded())
        l.gap = max(2, (l.ring * 0.22).rounded())
        l.dot = max(4, (l.ring * 0.2).rounded())
        l.stroke = max(1.5, l.ring * 0.1)
        l.badge = max(10, (l.ring * 0.62).rounded())
        let pad: CGFloat = 2
        var x = pad
        if waiting > 0 {  // 입력이 필요한 세션이 있으면 맨 앞에 주황 「!」
            l.marks.append((x, .badge))
            l.hits.append((x, l.badge, T("입력이 필요한 세션 {0}개", waiting)))
            x += l.badge + l.gap
        }
        for group in groups {
            if let last = l.marks.last, case .badge = last.mark {} else if !l.marks.isEmpty {
                x += l.gap
                l.marks.append((x, .separator))
                x += 1 + l.gap
            }
            l.marks.append((x, .dot(group.dot)))
            x += l.dot + l.gap
            for (index, ring) in group.rings.enumerated() {
                if index > 0 { x += l.gap }
                l.marks.append((x, .ring(ring.left)))
                l.hits.append((x, l.ring, ring.tip))
                x += l.ring
            }
        }
        l.size = NSSize(width: max(x + pad, pad * 2 + l.ring), height: barHeight)
        return l
    }

    /// 그리기(dark: 메뉴 막대가 어두운지). 밝은 메뉴 막대면 글자·테두리를 어둡게, 색은 진하게(Windows 판과 같은 값)
    static func draw(_ l: Layout, dark: Bool) {
        func rgb(_ hex: Int, _ alpha: CGFloat = 1) -> NSColor {
            NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        }
        let text = dark ? rgb(0xF2F2F4) : rgb(0x1E1E20)
        let track = dark ? NSColor(white: 1, alpha: 60 / 255) : NSColor(white: 0, alpha: 45 / 255)
        func status(_ left: Int) -> NSColor {
            dark ? (left >= 50 ? rgb(0x30D158) : left >= 20 ? rgb(0xFFD60A) : rgb(0xFF453A))
                 : (left >= 50 ? rgb(0x1F9D47) : left >= 20 ? rgb(0xB88600) : rgb(0xD92D20))
        }
        let mid = l.size.height / 2
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        func label(_ s: String, in rect: NSRect, size: CGFloat, color: NSColor) {
            let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: centered]
            let height = (s as NSString).size(withAttributes: attributes).height
            (s as NSString).draw(in: NSRect(x: rect.minX - 4, y: rect.midY - height / 2, width: rect.width + 8, height: height), withAttributes: attributes)
        }
        for (x, mark) in l.marks {
            switch mark {
            case .badge:
                let rect = NSRect(x: x, y: mid - l.badge / 2, width: l.badge, height: l.badge)
                rgb(0xFF9F0A).setFill()
                NSBezierPath(ovalIn: rect).fill()
                label("!", in: rect, size: l.badge * 0.72, color: rgb(0x1E1E20))
            case .separator:
                track.setFill()
                NSRect(x: x, y: mid - l.ring * 0.3, width: 1, height: l.ring * 0.6).fill()
            case .dot(let color):
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: mid - l.dot / 2, width: l.dot, height: l.dot)).fill()
            case .ring(let left):
                let box = NSRect(x: x + l.stroke / 2, y: mid - l.ring / 2 + l.stroke / 2, width: l.ring - l.stroke, height: l.ring - l.stroke)
                let base = NSBezierPath(ovalIn: box)
                base.lineWidth = l.stroke
                track.setStroke()
                base.stroke()
                if let left, left > 0 {
                    let arc = NSBezierPath()
                    arc.appendArc(withCenter: NSPoint(x: box.midX, y: box.midY), radius: box.width / 2,
                                  startAngle: 90, endAngle: 90 - 360 * CGFloat(min(100, left)) / 100, clockwise: true)
                    arc.lineWidth = l.stroke
                    arc.lineCapStyle = .round
                    status(left).setStroke()
                    arc.stroke()
                }
                let s = left.map(String.init) ?? "–"
                // Windows 판은 원 지름의 36% 글자 — 메뉴 막대는 작아서 두 자리까지는 46%, 세 자리(100)는 34%
                label(s, in: NSRect(x: x, y: mid - l.ring / 2, width: l.ring, height: l.ring),
                      size: max(5.5, l.ring * (s.count >= 3 ? 0.34 : 0.46)), color: text)
            }
        }
    }

    func update(groups: [Group], waiting: Int, size: Int) {
        guard let button = item.button else { return }
        let l = Self.layout(groups: groups, waiting: waiting, size: size, barHeight: NSStatusBar.system.thickness)
        let key = "\(size)|\(waiting)|" + l.hits.map { "\($0.x):\($0.tip)" }.joined(separator: "|")
            + groups.map { $0.rings.map { "\($0.left ?? -1)" }.joined(separator: ",") }.joined(separator: ";")
        guard key != drawnKey else { return }
        drawnKey = key
        // 그릴 때마다 메뉴 막대가 어두운지 본다(바탕 화면에 따라 바뀐다)
        button.image = NSImage(size: l.size, flipped: false) { _ in
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            Self.draw(l, dark: dark)
            return true
        }
        item.length = l.size.width
        button.removeAllToolTips()
        tips = [:]
        for hit in l.hits {
            let tag = button.addToolTip(NSRect(x: hit.x, y: 0, width: hit.width, height: l.size.height), owner: self, userData: nil)
            tips[tag] = hit.tip
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        tips[tag] ?? ""
    }
}

/// 메뉴 막대 게이지를 누르면 바로 아래로 내려오는 세션 패널(Windows 판 SessionPopup 과 같은 내용).
/// 줄을 누르면 그 대화를 열고 닫힌다. 바깥을 누르거나 Esc, 게이지를 다시 누르면 닫힌다.
/// 초점을 뺏지 않는 패널이지만 Esc 를 받으려고 key 창은 된다(쓰던 앱은 앞에 그대로)
final class SessionPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

struct SessionPanelView: View {
    @ObservedObject var model: UsageModel

    var body: some View {
        let look = PetAppearance()  // 떠 있는 창의 「창 크기」·「글자 크기」와는 따로(Windows 판과 같다)
        let counts = [(SessionState.waiting, T("입력 필요")), (SessionState.working, T("작업 중"))]
            .map { entry in (entry.1, model.sessions.filter { $0.state == entry.0 }.count) }
            .filter { $0.1 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
        VStack(alignment: .leading, spacing: look.length(5)) {
            HStack(spacing: look.length(6)) {
                Text(T("세션")).font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 4)
                Text(counts).font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
            }
            if model.sessions.isEmpty {
                Text(T("열린 세션이 없습니다")).font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                SessionRows(sessions: model.sessions, now: model.now, hovered: model.hovered, space: "panel")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 340, alignment: .leading)
        .coordinateSpace(name: "panel")
        .onPreferenceChange(HitTargetKey.self) { [model] hits in model.panelHits = hits }
        .environment(\.petAppearance, look)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private lazy var history = UsageHistory()
    private lazy var alerts = LimitAlerts()
    private let trends = TrendModel()
    private var trendWindow: NSWindow?
    private var scanned = SourceScan()
    private var readOnlyRows: [UsageEvent] = []
    private var scanning = false
    private var activeUser: UsageAccount?
    private var permission: Bool?
    private var requestedPermission = false
    private var sending = false
    private var enabled: Bool { UserDefaults.standard.object(forKey: "limitAlerts") as? Bool ?? true }
    private var modelAlerts: Bool { UserDefaults.standard.object(forKey: Shown.modelAlertsKey) as? Bool ?? false }
    // Claude Code 가 응답하면(대화 기록이 바뀌면) 곧 `claude /usage` 를 묻고, 그 밖에는 5분마다 — 5초마다 때인지 본다(Windows 판과 같다)
    private let activity = ClaudeActivityWatcher()
    private var usageAskedAt: Date?
    private var askingUsage = false
    private var liveRows: [UsageEvent] { UsageEvent.liveRows(claude: model.claude, codex: codex) }
    private var trendOpen: Bool { trendWindow?.isVisible == true || trendWindow?.isMiniaturized == true }

    @objc private func openTrend() {
        if trendWindow == nil {
            // 크기는 고정(Windows 판과 같다) — 창 안 그림이 늘 같은 모양이도록
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 630, height: 490),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.appearance = NSAppearance(named: .darkAqua)
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: TrendScreen(data: trends, model: model))
            w.center()
            trendWindow = w
        }
        if !trendOpen { trends.month = false }
        trendWindow?.title = T("사용 추이")
        trendWindow?.deminiaturize(nil); trendWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        syncUsage()
        scanHistory()
    }

    private func scanHistory() {
        guard !scanning else { return }
        scanning = true
        let n = millis(Date()), user = UsageAccount(now: n), previous = scanned
        DispatchQueue.global(qos: .utility).async {
            var scanner = previous
            let rows = scanner.read(user, now: n)
            let updated = scanner
            DispatchQueue.main.async {
                self.scanning = false
                let current = millis(Date())
                let live = UsageAccount(now: current)
                guard live == user else {
                    if self.trendOpen {
                        self.showResults(live, now: current)
                        if live.since != current { self.scanHistory() }
                    }
                    return
                }
                if historyWriter && self.history.merge(rows, now: current) { self.scanned = updated }
                if !historyWriter { self.readOnlyRows = rows }
                self.showResults(user, now: current)
            }
        }
    }
    private func showResults(_ user: UsageAccount, now: Int64) {
        trends.now = now
        trends.results = TrendResult.calculate(history.visibleRows + readOnlyRows, user: user, now: now)
        trendWindow?.title = T("사용 추이")
    }
    private func syncUsage() {
        let n = millis(Date()), user = UsageAccount(now: n)
        let changed = activeUser != user
        activeUser = user
        if historyWriter {
            if !enabled { alerts.cancel() }
            else {
                if !model.showClaude { alerts.cancel("claude") }
                if !model.showCodex { alerts.cancel("codex") }
            }
            history.recordLive(liveRows, user: user, now: n)
        }
        if trendOpen {
            showResults(user, now: n)
            if changed { scanHistory() }
        }
        sendNextAlert()
    }

    private func sendNextAlert() {
        guard historyWriter, !sending, enabled, Bundle.main.bundleURL.pathExtension == "app",
              !(Bundle.main.bundleIdentifier ?? "").isEmpty else { return }
        let n = millis(Date()), keys = UsageAccount(now: n).keys.filter { $0.key == "claude" ? model.showClaude : model.showCodex }
        guard let c = alerts.nextLive(claude: model.claude, codex: codex, keys: keys, now: n, enabled: enabled,
                                      models: modelAlerts, skipped: permission == false) else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        if permission == nil {
            guard !requestedPermission else { return }
            requestedPermission = true
            sending = true
            center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                DispatchQueue.main.async {
                    self.sending = false
                    guard error == nil else { return }
                    self.permission = granted
                    self.sendNextAlert()
                }
            }
            return
        }
        let previous = alerts.state
        guard alerts.save(c.state) else { return }
        if permission == false { sendNextAlert(); return }
        let content = UNMutableNotificationContent()
        content.title = c.notice.title; content.body = c.notice.body ?? ""; content.sound = .default
        sending = true
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
            DispatchQueue.main.async {
                self.sending = false
                if error != nil {
                    if self.alerts.state == c.state { _ = self.alerts.save(previous) }
                } else { self.sendNextAlert() }
            }
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
    @objc private func toggleAlerts() {
        UserDefaults.standard.set(!enabled, forKey: "limitAlerts")
        if !enabled && historyWriter { alerts.cancel() }
        sendNextAlert()
    }
    /// 「모델별 한도도 알림」 — 「한도 알림」이 꺼져 있으면 흐리게(누를 수 없음)
    @objc private func toggleModelAlerts() {
        guard enabled else { return }
        UserDefaults.standard.set(!modelAlerts, forKey: Shown.modelAlertsKey)
        if historyWriter { alerts.applyPreferences(enabled: enabled, models: modelAlerts) }
        sendNextAlert()
    }
    /// 「모델별 한도 보이기 (Fable 등)」 — 작은 창·상세 줄에서 모델별 줄을 빼거나 넣는다(/usage 조회·기록은 그대로)
    @objc private func toggleModelDisplay() {
        model.showModels.toggle()
        UserDefaults.standard.set(model.showModels, forKey: Shown.modelsKey)
        updateLabelExtra()
        afterUpdate()
    }

    /// 보일 칸 이름 중 가장 긴 것에 맞춰 이름 칸을 늘린다(최대 64, 기본 이름만 있으면 0 — 지금 모양 그대로)
    private func updateLabelExtra() {
        let font = NSFont.systemFont(ofSize: 11)
        let names = (model.showClaude ? model.claude.visibleWindows(showModels: model.showModels) : [])
            + (model.showCodex ? model.codex.visibleWindows(showModels: model.showModels) : [])
        let widest = names.map { ($0.label as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let base: CGFloat = L10n.current == "en" ? 40 : 30
        let extra = min(64, max(0, (widest - base).rounded(.up)))
        if model.appearance.labelExtra != extra { model.appearance.labelExtra = extra }
    }

    /// 지금 `claude /usage` 를 물을 때인지 본다(처음·Claude Code 응답 직후·5분마다)
    @objc private func checkClaudeUsage() {
        guard model.showClaude, ClaudeUsageCommand.disabledReason() == nil else { return }
        activity.ensure()
        if let reason = ClaudeActivityWatcher.due(now: Date(), lastAsked: usageAskedAt, pending: activity.pending()) {
            askClaudeUsage(reason)
        }
    }

    private func askClaudeUsage(_ reason: String) {
        guard !askingUsage, model.showClaude, ClaudeUsageCommand.disabledReason() == nil else { return }
        askingUsage = true
        usageAskedAt = Date()
        activity.take()
        DispatchQueue.global(qos: .utility).async {
            ClaudeUsageCommand.fetch(reason: reason)
            DispatchQueue.main.async {
                self.askingUsage = false
                self.refreshLocal()
            }
        }
    }

    private let model = UsageModel()
    private let claude = ClaudeReader()
    private let codex = CodexReader()
    private let claudeSessions = ClaudeSessionReader()
    private let codexSessions = CodexSessionReader()
    private var panel: NSPanel!
    /// 사람이 둔 창의 왼쪽 아래 모서리. 창 높이가 바뀌어도 이 자리를 지키고 위로 늘거나 준다.
    private var anchor = NSPoint.zero
    private var applyingFrame = false
    private var appliedOrigin: NSPoint?
    private var anchorFromOldTop = false  // 예전 판이 기억한 위 모서리로 처음 띄웠으면, 값이 다 찬 높이로 한 번 다시 잰다
    private var container: ContainerView!
    private let translucentRoot = TranslucentRoot()
    private let background = NSView()
    private var hosting: NSHostingView<PetView>!
    private var updating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Updater.afterLaunch()
        // 앱을 옮기거나 다시 깔아 상태 표시줄이 없는 경로를 가리키면, 이 앱이 걸었던 것이니 묻지 않고 새 경로로 고친다
        if ClaudeCodeLink.state() == .broken { ClaudeCodeLink.connect() }
        buildMainMenu()
        buildPanel()
        refreshAll()
        applyDisplayMode()
        Timer.scheduledTimer(timeInterval: 15, target: self, selector: #selector(refreshLocal), userInfo: nil, repeats: true)
        Timer.scheduledTimer(timeInterval: 3, target: self, selector: #selector(refreshSessions), userInfo: nil, repeats: true)
        Timer.scheduledTimer(timeInterval: 300, target: self, selector: #selector(refreshServer), userInfo: nil, repeats: true)
        Timer.scheduledTimer(timeInterval: 5, target: self, selector: #selector(checkClaudeUsage), userInfo: nil, repeats: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + Updater.firstDelay) { [weak self] in self?.checkForUpdate(manual: false) }
        Timer.scheduledTimer(timeInterval: Updater.interval, target: self, selector: #selector(autoCheckForUpdate), userInfo: nil, repeats: true)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refreshAll),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(savePosition),
                                               name: NSWindow.didMoveNotification, object: panel)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    private func buildPanel() {
        hosting = NSHostingView(rootView: PetView(model: model))
        let size = hosting.fittingSize
        container = ContainerView(frame: NSRect(origin: .zero, size: size))
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        for input in [container.input, translucentRoot.input] {
            input.content = hosting
            input.onClick = { [weak self] point in self?.click(point) }
            input.onHover = { [weak self] point in self?.hover(point) }
            // 오른쪽 한 번이면 메뉴(두 번째 클릭을 기다려 조금 늦게), 두 번이면 메뉴 막대 간단 모드로 — Windows 판과 같다
            input.onRightClick = { [weak self] event in
                guard let self, let view = self.panel.contentView else { return }
                let at = view.convert(event.locationInWindow, from: nil)
                self.rightClick(single: { [weak self] in self?.showMenu(at: at) }, double: { [weak self] in self?.setDisplayMode(1) })
            }
        }
        background.wantsLayer = true
        background.autoresizingMask = [.width, .height]
        translucentRoot.addSubview(background)
        hosting.autoresizingMask = [.width, .height]

        // Codex 펫처럼: 다른 창 위, 모든 데스크톱·전체 화면 앱 위에 뜨고, 눌러도 지금 쓰는 앱의 초점을 뺏지 않는다
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        applyAppearance()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        placePanel(reset: false)
        if Display.mode == 0 { panel.orderFrontRegardless() }
    }

    private func applyAppearance() {
        let look = model.appearance
        let root: NSView = look.background == 0 ? container : translucentRoot
        if panel.contentView !== root || hosting.superview !== root {
            hosting.removeFromSuperview()
            panel.contentView = root
            hosting.frame = root.bounds
            root.addSubview(hosting)
        }
        if look.background == 0 {
            container.maskImage = roundedMask(radius: look.length(14))
        } else {
            background.frame = root.bounds
            background.layer?.cornerRadius = look.length(14)
            background.layer?.backgroundColor = NSColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: look.opacity).cgColor
        }
        if ProcessInfo.processInfo.environment["AIUSAGE_DEBUG_VIEWS"] == "1" {
            func dumpView(_ view: NSView, _ indent: String) {
                fputs("\(indent)\(type(of: view))\n", stderr)
                for child in view.subviews { dumpView(child, indent + "  ") }
            }
            dumpView(root, "")
        }
    }

    @objc private func refreshLocal() {
        model.now = Date()
        model.claude = claude.read(now: model.now)
        let codexSwitched = codex.readLog(now: model.now)
        model.codex = codex.current
        updateLabelExtra()
        syncUsage()
        refreshSessions()
        afterUpdate()
        if codexSwitched { refreshServer() }  // ChatGPT 계정이 바뀌었다: 5분 기다리지 않고 새 계정 값을 묻는다
    }

    /// 세션 상태는 자주 바뀌므로 3초마다 읽는다(파일 몇 개와 기록 끝부분만 읽어 가볍다).
    /// 「세션 보이기」를 꺼도 읽는다 — 메뉴 막대 게이지를 누르면 나오는 세션 패널이 쓴다(Windows 판과 같다)
    @objc private func refreshSessions() {
        let now = Date()
        let sessions = sortSessions(claudeSessions.read(now: now) + codexSessions.read(now: now))
        let resized = sessions.count != model.sessions.count  // 세션 칸이 생기거나 없어지거나 줄 수가 바뀌면 창 높이를 맞춘다
        model.now = now
        model.sessions = sessions
        if let id = model.hovered, !sessions.contains(where: { $0.id == id }) { model.hovered = nil }
        if resized { afterUpdate() } else { updateGauge() }
        if sessionPanel?.isVisible == true { DispatchQueue.main.async { self.placeSessionPanel(animated: false) } }
    }

    @objc private func refreshServer() {
        guard model.showCodex else { return }  // ChatGPT 칸을 껐으면 codex 를 띄우지 않는다
        codex.refreshServer { [weak self] in
            guard let self else { return }
            self.model.codex = self.codex.current
            self.updateLabelExtra()
            self.syncUsage()
            self.afterUpdate()
        }
    }

    @objc private func refreshAll() {
        refreshLocal()
        refreshServer()
        askClaudeUsage("새로고침")
    }

    private func afterUpdate() {
        panel.contentView?.toolTip = detailLines().joined(separator: "\n")
        updateGauge()
        DispatchQueue.main.async { self.fitPanel() }  // SwiftUI 가 새 값으로 다시 그린 뒤 크기를 맞춘다
    }

    /// 내용 높이가 바뀌면 왼쪽 아래 모서리를 그대로 두고(위로 늘고 준다) 창 크기를 맞춘다
    private func fitPanel() {
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        if anchorFromOldTop {
            anchorFromOldTop = false
            anchor.y = panel.frame.maxY - size.height
            saveAnchor()
        }
        guard size != panel.frame.size else { return }
        applyFrame(size: size)
    }

    /// 자리(anchor)에 창을 놓는다. 위로 늘다가 화면 위 끝을 넘으면 넘친 만큼만 아래로 민다(자리는 그대로 기억).
    private func applyFrame(size: NSSize) {
        var origin = anchor
        let probe = NSPoint(x: anchor.x + 10, y: anchor.y + 10)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(probe) }) ?? panel.screen {
            let visible = screen.visibleFrame
            origin.x = max(visible.minX, min(anchor.x, visible.maxX - size.width))
            origin.y = min(anchor.y, visible.maxY - size.height)
        }
        applyingFrame = true
        appliedOrigin = origin
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        appliedOrigin = panel.frame.origin // AppKit may round fractional scaled coordinates.
        applyingFrame = false
        panel.invalidateShadow()
    }

    private func placePanel(reset: Bool) {
        let defaults = UserDefaults.standard
        if !reset, let saved = defaults.array(forKey: "bottomLeft") as? [Double], saved.count == 2 {
            let point = NSPoint(x: saved[0], y: saved[1])
            if NSScreen.screens.contains(where: { $0.frame.contains(NSPoint(x: point.x + 10, y: point.y + 10)) }) {
                anchor = point
                applyFrame(size: panel.frame.size)
                return
            }
        }
        // 1.2 까지는 위 모서리를 기억했다 — 그 자리에서 이어서 시작한다
        if !reset, let old = defaults.array(forKey: "topLeft") as? [Double], old.count == 2 {
            let point = NSPoint(x: old[0], y: old[1])
            if NSScreen.screens.contains(where: { $0.visibleFrame.contains(NSPoint(x: point.x + 10, y: point.y - 10)) }) {
                anchor = NSPoint(x: point.x, y: point.y - panel.frame.height)
                anchorFromOldTop = true
                applyFrame(size: panel.frame.size)
                return
            }
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        anchor = NSPoint(x: visible.maxX - panel.frame.width - 16, y: visible.maxY - 16 - panel.frame.height)
        applyFrame(size: panel.frame.size)
        if reset { saveAnchor() }
    }

    /// 창을 끌어 옮겼을 때만 새 자리로 기억한다(높이 맞추기·화면 위 끝에 밀린 이동은 빼고)
    @objc private func savePosition() {
        guard !applyingFrame, panel.frame.origin != appliedOrigin else { return }
        anchor = panel.frame.origin
        appliedOrigin = anchor
        saveAnchor()
    }

    private func saveAnchor() {
        UserDefaults.standard.set([anchor.x, anchor.y], forKey: "bottomLeft")
        UserDefaults.standard.removeObject(forKey: "topLeft")
    }

    @objc private func screensChanged() { placePanel(reset: false) }  // 모니터를 빼서 화면 밖에 남으면 기본 위치로
    @objc private func resetPosition() { placePanel(reset: true) }
    @objc private func quit() { NSApp.terminate(nil) }

    private func detailLines() -> [String] {
        let now = model.now
        var lines: [String] = []
        func add(_ title: String, _ snap: ProviderSnapshot) {
            lines.append(T("{0} · 마지막 값 {1}", title, snap.observedAt.map(fullTime) ?? T("없음")))
            for w in snap.visibleWindows(showModels: model.showModels) {
                lines.append("    " + T("{0} {1}% 남음 · 초기화 {2}", w.label, w.leftPercent(now: now), w.resetsAt.map(fullTime) ?? "-"))
            }
        }
        for pane in model.order {  // 창과 같은 순서로
            switch pane {
            case .claude where model.showClaude:
                add("Claude (\(model.claude.source ?? T("Claude Code 상태 표시줄")))", model.claude)
                // Claude 값이 오래됐고 데스크톱 앱 기록도 멈췄으면 다시 받게 하는 법을 알린다
                if model.claude.observedAt.map({ now.timeIntervalSince($0) >= ClaudeDesktopUsage.staleAfter }) ?? true,
                   let hint = ClaudeDesktopUsage.staleHint(now: now) { lines.append("    " + hint) }
                let usageError = ClaudeUsageCommand.disabledReason() ?? ClaudeUsageCommand.lastError
                lines.append(T("Claude /usage 확인 {0}", ClaudeUsageCommand.lastCheckedAt.map(clock) ?? T("전")) + (usageError.map { " — \($0)" } ?? ""))
            case .codex where model.showCodex:
                add(T("ChatGPT (Codex 한도)"), model.codex)
                lines.append(T("Codex 서버 확인 {0}", codex.serverCheckedAt.map(clock) ?? T("전")) + (codex.serverError.map { " — \($0)" } ?? ""))
            default:
                break
            }
        }
        return lines
    }

    /// 떠 있는 창을 오른쪽 클릭한 자리에서 메뉴를 연다
    private func showMenu(at point: NSPoint) {
        guard let view = panel.contentView else { return }
        contextMenu().popUp(positioning: nil, at: point, in: view)
    }

    /// 떠 있는 창·메뉴 막대 게이지의 오른쪽 클릭 메뉴(Windows 판 1.4.3 과 같은 구조).
    /// 위는 요약(세션 이름·상태, 회사마다 남은 한도 한 줄), 아래는 묶음(보기·모양·알림·설정). 긴 글은 「…」로 줄이고 전체는 풍선으로
    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        let now = model.now
        if model.showSessions && !model.sessions.isEmpty {
            menu.addItem(menuHeader(T("세션")))
            let shown = model.sessions.count <= 8 ? model.sessions : Array(model.sessions.prefix(7))
            for s in shown {
                let name = shortened(s.name, 24)
                let item = menuItem(name, #selector(openSessionItem(_:)))
                item.attributedTitle = rowTitle(name, sessionStatusText(s, now: now))
                item.image = toolDot(s.tool)
                item.toolTip = describeSession(s, now: now)
                item.representedObject = s.id
                menu.addItem(item)
            }
            if model.sessions.count > 8 { menu.addItem(menuHeader(T("외 {0}개", model.sessions.count - 7))) }
        }
        menu.addItem(menuHeader(T("남은 한도")))
        for pane in model.order {
            if pane == .claude && model.showClaude { menu.addItem(summaryItem("Claude", model.claude, now: now)) }
            if pane == .codex && model.showCodex { menu.addItem(summaryItem("ChatGPT", model.codex, now: now)) }
        }
        let details = NSMenu()
        for line in detailLines() {
            let info = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            info.isEnabled = false
            details.addItem(info)
        }
        menu.addItem(groupItem(T("자세히"), nil, details))
        menu.addItem(.separator())
        menu.addItem(menuItem(T("지금 새로고침"), #selector(refreshAll)))
        menu.addItem(menuItem(T("사용 추이…"), #selector(openTrend)))
        menu.addItem(.separator())
        addGroupMenus(to: menu)
        menu.addItem(.separator())
        menu.addItem(menuItem(T("종료"), #selector(quit)))
        return menu
    }

    /// 메뉴 글 폭 상한 — 긴 세션 이름 때문에 메뉴가 넓어지지 않게
    private func shortened(_ text: String, _ limit: Int = 28) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// 누를 수 없는 흐린 머리줄(「세션」「남은 한도」)
    private func menuHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// 「왼쪽 ⇥ 오른쪽」: 오른쪽 값은 흐리게, 같은 자리에 오른쪽 정렬(탭)
    private func rowTitle(_ left: String, _ right: String?, dimmed: Bool = false) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: 250)]
        let text = NSMutableAttributedString(string: left, attributes: [
            .font: font, .paragraphStyle: style, .foregroundColor: dimmed ? NSColor.disabledControlTextColor : NSColor.labelColor,
        ])
        if let right {
            text.append(NSAttributedString(string: "\t" + right, attributes: [
                .font: font, .paragraphStyle: style, .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        return text
    }

    /// 세션 줄 앞의 작은 점(주황 Claude, 초록 Codex)
    private func toolDot(_ tool: SessionTool) -> NSImage {
        let color = tool == .claude ? NSColor(srgbRed: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255, alpha: 1)
                                    : NSColor(srgbRed: 0x10 / 255, green: 0xA3 / 255, blue: 0x7F / 255, alpha: 1)
        return NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).fill()
            return true
        }
    }

    /// 「Claude  5시간 94% · 주간 14%」(모델별 줄은 빼고), 오른쪽에 확인 시각
    private func summaryItem(_ name: String, _ snap: ProviderSnapshot, now: Date) -> NSMenuItem {
        let windows = snap.windows.filter { $0.name == nil }
        let text = windows.isEmpty ? "\(name) · \(snap.message ?? T("값이 없습니다"))"
            : "\(name)  " + windows.map { "\($0.label) \($0.leftPercent(now: now))%" }.joined(separator: " · ")
        let item = NSMenuItem(title: shortened(text, 40), action: nil, keyEquivalent: "")
        item.attributedTitle = rowTitle(shortened(text, 40), snap.observedAt.map(clock), dimmed: true)
        item.isEnabled = false
        if text.count > 40 { item.toolTip = text }
        return item
    }

    /// 하위 메뉴 항목(오른쪽에 지금 값을 흐리게)
    private func groupItem(_ title: String, _ value: String?, _ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let value { item.attributedTitle = rowTitle(title, value) }
        item.submenu = submenu
        return item
    }

    @objc private func openSessionItem(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String, let s = model.sessions.first(where: { $0.id == id }) else { return }
        SessionOpener.open(s)
    }

    // MARK: 자동 업데이트

    private func updateMenuItem() -> NSMenuItem {
        menuItem(T("업데이트 확인 (지금 {0})", Updater.current), #selector(manualCheckForUpdate))
    }

    @objc private func autoCheckForUpdate() { checkForUpdate(manual: false) }
    @objc private func manualCheckForUpdate() { checkForUpdate(manual: true) }

    /// 새 판이 있으면 받아 바꾸고 다시 띄운다. 자동 확인은 조용히 하고, 메뉴에서 누른 확인만 결과를 알린다.
    private func checkForUpdate(manual: Bool) {
        guard !updating, manual || Updater.autoEnabled else { return }
        updating = true
        DispatchQueue.global(qos: .utility).async {
            let outcome = Updater.run()
            DispatchQueue.main.async { [self] in
                updating = false
                switch outcome {
                case .installed(_, let old):
                    Updater.relaunch(after: getpid(), app: Bundle.main.bundleURL, old: old)
                    NSApp.terminate(nil)
                case .upToDate(let latest):
                    if manual { inform(T("최신 버전입니다"), T("지금 {0}", Updater.current) + (latest.map { " " + T("· 올라온 최신 {0}", $0) } ?? "")) }
                case .failed(let message):
                    if manual { inform(T("업데이트하지 못했습니다"), message) }
                }
            }
        }
    }

    private func inform(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Claude Code 가 있는데 상태 표시줄이 안 걸렸거나 끊겼을 때만 「Claude Code 에 연결」
    private func addConnectItem(to menu: NSMenu) {
        let state = ClaudeCodeLink.state()
        guard state == .notConnected || state == .broken else { return }
        menu.addItem(menuItem(T("Claude Code 에 연결…"), #selector(connectClaudeCode)))
    }

    @objc private func connectClaudeCode() {
        let alert = NSAlert()
        alert.messageText = T("Claude Code 에 연결할까요?")
        alert.informativeText = T("Claude 값을 받으려고 Claude Code 상태 표시줄(~/.claude/settings.json)에 이 앱을 겁니다.\n쓰시던 상태 표시줄이 있으면 그대로 보입니다. 고치기 전 파일은 settings.json.bak-날짜 로 남깁니다.")
        alert.addButton(withTitle: T("연결"))
        alert.addButton(withTitle: T("취소"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let result = ClaudeCodeLink.connect()
        let done = NSAlert()
        if result.hasPrefix("error:") || ClaudeCodeLink.state() != .connected {
            done.messageText = T("연결하지 못했습니다")
            done.informativeText = result.hasPrefix("error:") ? T(String(result.dropFirst(6))) : T("결과: {0}", result)
        } else {
            done.messageText = T("연결했습니다")
            done.informativeText = T("Claude Code 에서 한 번 대화하면 Claude 값이 나타납니다.")
        }
        done.runModal()
        refreshLocal()
    }

    private func menuItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    /// 보기·모양·알림·설정 묶음(오른쪽 클릭·Dock·앱 메뉴가 같이 쓴다)
    private func addGroupMenus(to menu: NSMenu) {
        menu.addItem(viewMenuItem())
        menu.addItem(appearanceMenuItem())
        menu.addItem(alertsMenuItem())
        menu.addItem(settingsMenuItem())
    }

    /// 보기: 어떤 칸을 보일지, 칸 순서, 모두 접기·펼치기
    private func viewMenuItem() -> NSMenuItem {
        let submenu = NSMenu()
        submenu.addItem(menuItem(T("세션"), #selector(toggleSessions)))
        submenu.addItem(menuItem("Claude", #selector(toggleClaude)))
        submenu.addItem(menuItem("ChatGPT", #selector(toggleCodex)))
        submenu.addItem(menuItem(T("모델별 한도 (Fable 등)"), #selector(toggleModelDisplay)))
        submenu.addItem(.separator())
        submenu.addItem(orderMenuItem())
        let expand = menuItem(T("모두 펼치기"), #selector(foldAll(_:)))
        expand.tag = 0
        submenu.addItem(expand)
        let collapse = menuItem(T("모두 접기"), #selector(foldAll(_:)))
        collapse.tag = 1
        submenu.addItem(collapse)
        return groupItem(T("보기"), nil, submenu)
    }

    /// 칸 순서: 지금 순서를 보여 주고, 누른 칸을 한 칸 위로(맨 위 칸은 흐리게 — validateMenuItem)
    private func orderMenuItem() -> NSMenuItem {
        let submenu = NSMenu()
        submenu.addItem(menuHeader(T("지금: {0}", model.order.map(\.title).joined(separator: " → "))))
        for (index, pane) in model.order.enumerated() {
            let item = menuItem(T("{0} 위로", pane.title), #selector(moveOrderUp(_:)))
            item.tag = index
            submenu.addItem(item)
        }
        return groupItem(T("칸 순서"), nil, submenu)
    }

    @objc private func moveOrderUp(_ item: NSMenuItem) {
        let index = item.tag
        guard index > 0, index < model.order.count else { return }
        var order = model.order
        order.swapAt(index - 1, index)
        model.order = order
        UserDefaults.standard.set(order.map(\.rawValue), forKey: Pane.orderKey)
        afterUpdate()  // 칸 높이가 달라도 아래 모서리를 그대로 두고 맞춘다
    }

    @objc private func foldAll(_ item: NSMenuItem) {
        let fold = item.tag == 1
        model.foldSessions = fold
        model.foldClaude = fold
        model.foldCodex = fold
        for key in [Shown.foldSessionsKey, Shown.foldClaudeKey, Shown.foldCodexKey] { UserDefaults.standard.set(fold, forKey: key) }
        model.hovered = nil
        afterUpdate()
    }

    /// 모양: 표시 방식, 그리고 지금 모드에 맞는 것만(메뉴 막대면 크기, 떠 있는 창이면 투명도·창 크기·글자 크기)
    private func appearanceMenuItem() -> NSMenuItem {
        let submenu = NSMenu()
        submenu.addItem(menuHeader(T("표시 방식")))
        for (label, value) in zip([T("떠 있는 창"), T("메뉴 막대 (간단 모드)")], [0, 1]) {
            let item = menuItem(label, #selector(chooseDisplayMode(_:)))
            item.tag = value
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        if Display.mode == 1 {
            submenu.addItem(menuHeader(T("메뉴 막대 크기")))
            for (label, value) in zip([T("작게"), T("크게")], [75, 100]) {
                let item = menuItem(label, #selector(chooseMenuBarSize(_:)))
                item.tag = value
                submenu.addItem(item)
            }
        } else {
            for setting in PetSetting.allCases {
                let choices = NSMenu()
                for (label, value) in zip(setting.labels, setting.values) {
                    let item = menuItem(label, #selector(chooseAppearance(_:)))
                    item.representedObject = setting.rawValue
                    item.tag = value
                    choices.addItem(item)
                }
                let current = zip(setting.labels, setting.values).first { $0.1 == model.appearance[setting] }?.0
                submenu.addItem(groupItem(setting.title, current, choices))
            }
        }
        return groupItem(T("모양"), Display.mode == 1 ? T("메뉴 막대") : T("떠 있는 창"), submenu)
    }

    /// 알림: 한도 알림, 모델별 한도도 알림
    private func alertsMenuItem() -> NSMenuItem {
        let submenu = NSMenu()
        submenu.addItem(menuItem(T("한도 알림"), #selector(toggleAlerts)))
        submenu.addItem(menuItem(T("모델별 한도도 알림"), #selector(toggleModelAlerts)))
        return groupItem(T("알림"), enabled ? T("켬") : T("끔"), submenu)
    }

    /// 설정: 로그인 항목, Claude Code 연결, 언어, 위치 초기화, 업데이트 확인
    private func settingsMenuItem() -> NSMenuItem {
        let submenu = NSMenu()
        submenu.addItem(menuItem(T("로그인할 때 자동으로 열기"), #selector(toggleLoginItem)))
        addConnectItem(to: submenu)
        submenu.addItem(languageMenuItem())
        submenu.addItem(.separator())
        submenu.addItem(menuItem(T("위치 초기화"), #selector(resetPosition)))
        submenu.addItem(updateMenuItem())
        return groupItem(T("설정"), nil, submenu)
    }

    @objc private func chooseDisplayMode(_ item: NSMenuItem) { setDisplayMode(item.tag) }

    @objc private func chooseMenuBarSize(_ item: NSMenuItem) {
        guard [75, 100].contains(item.tag), item.tag != Display.size else { return }
        Display.size = item.tag
        updateGauge()
    }

    @objc private func chooseAppearance(_ item: NSMenuItem) {
        guard let key = item.representedObject as? String, let setting = PetSetting(rawValue: key),
              setting.values.contains(item.tag), model.appearance[setting] != item.tag else { return }
        model.appearance[setting] = item.tag
        UserDefaults.standard.set(item.tag, forKey: key)
        applyAppearance()
        afterUpdate()
    }

    /// 「언어」 — 자동(시스템 언어)과 언어 이름(각 언어로 적은 이름). 체크는 validateMenuItem 이 붙인다.
    private func languageMenuItem() -> NSMenuItem {
        let submenu = NSMenu()
        let auto = menuItem(T("자동 (시스템 언어)"), #selector(chooseLanguage(_:)))
        auto.representedObject = "auto"
        submenu.addItem(auto)
        submenu.addItem(.separator())
        for code in L10n.codes {
            let item = menuItem(L10n.nativeNames[code] ?? code, #selector(chooseLanguage(_:)))
            item.representedObject = code
            submenu.addItem(item)
        }
        let item = NSMenuItem(title: T("언어 (Language)"), action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    @objc private func chooseLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String, code != L10n.choice else { return }
        L10n.choose(code)
        buildMainMenu()
        refreshAll()  // 값에 붙은 안내 글도 새 언어로 다시 만든다
        model.objectWillChange.send()
        afterUpdate()
    }

    @objc private func toggleClaude() { setShown(claude: !model.showClaude, codex: model.showCodex) }
    @objc private func toggleCodex() { setShown(claude: model.showClaude, codex: !model.showCodex) }

    @objc private func toggleSessions() {
        model.showSessions.toggle()
        UserDefaults.standard.set(model.showSessions, forKey: Shown.sessionsKey)
        afterUpdate()
    }

    private func setShown(claude: Bool, codex: Bool) {
        guard claude || codex else { return }  // 둘 다 끄면 빈 창이 되므로 하나는 남긴다
        let codexTurnedOn = codex && !model.showCodex
        model.showClaude = claude
        model.showCodex = codex
        UserDefaults.standard.set(claude, forKey: Shown.claudeKey)
        UserDefaults.standard.set(codex, forKey: Shown.codexKey)
        if historyWriter && !claude { alerts.cancel("claude") }
        if historyWriter && !codex { alerts.cancel("codex") }
        syncUsage()
        if codexTurnedOn { refreshServer() }
        afterUpdate()
    }

    // MARK: 마우스 · 칸 접기

    /// 끌지 않고 눌렀다 뗐을 때: 머리줄이면 접고 펴고, 세션 줄이면 그 대화를 연다
    private func click(_ point: NSPoint) {
        switch hitTarget(at: point, in: model.hits) {
        case .header(let pane)?: toggleFold(pane)
        case .session(let id)?: if let s = model.sessions.first(where: { $0.id == id }) { SessionOpener.open(s) }
        case nil: break
        }
    }

    /// 세션 줄 위에서는 밝은 바탕과 손가락 커서(머리줄도 손가락)
    private func hover(_ point: NSPoint?, hits: [HitTarget: CGRect]? = nil) {
        let target = point.flatMap { hitTarget(at: $0, in: hits ?? model.hits) }
        var id: String?
        if case .session(let s)? = target { id = s }
        (target == nil ? NSCursor.arrow : NSCursor.pointingHand).set()
        if model.hovered != id { model.hovered = id }
    }

    private func toggleFold(_ pane: Pane) {
        switch pane {
        case .sessions:
            model.foldSessions.toggle()
            UserDefaults.standard.set(model.foldSessions, forKey: Shown.foldSessionsKey)
        case .claude:
            model.foldClaude.toggle()
            UserDefaults.standard.set(model.foldClaude, forKey: Shown.foldClaudeKey)
        case .codex:
            model.foldCodex.toggle()
            UserDefaults.standard.set(model.foldCodex, forKey: Shown.foldCodexKey)
        }
        model.hovered = nil
        afterUpdate()
    }

    private var rightTimer: Timer?

    /// 오른쪽 클릭: 두 번째 클릭이 더블클릭 시간 안에 안 오면 한 번(메뉴), 오면 두 번(표시 방식 바꾸기)
    private func rightClick(single: @escaping () -> Void, double: @escaping () -> Void) {
        if let timer = rightTimer {
            timer.invalidate()
            rightTimer = nil
            double()
            return
        }
        rightTimer = Timer.scheduledTimer(withTimeInterval: NSEvent.doubleClickInterval, repeats: false) { [weak self] _ in
            self?.rightTimer = nil
            single()
        }
    }

    // MARK: 메뉴 막대 간단 모드

    private var gauge: MenuBarGauge?
    private var sessionPanel: SessionPanel?
    private var sessionHosting: NSHostingView<SessionPanelView>?
    private var panelMonitors: [Any] = []
    private var ignoreGaugeClick = false

    /// 「표시 방식」: 떠 있는 창 ↔ 메뉴 막대 간단 모드(떠 있는 창은 숨는다)
    private func setDisplayMode(_ mode: Int) {
        guard [0, 1].contains(mode), mode != Display.mode || (mode == 1) != (gauge != nil) else { return }
        Display.mode = mode
        applyDisplayMode()
    }

    private func applyDisplayMode() {
        if Display.mode == 1 {
            if gauge == nil {
                let made = MenuBarGauge()
                made.onLeftClick = { [weak self] in self?.gaugeClicked() }
                made.onRightClick = { [weak self] in
                    self?.rightClick(single: { [weak self] in self?.showGaugeMenu() }, double: { [weak self] in self?.setDisplayMode(0) })
                }
                gauge = made
            }
            updateGauge()
            panel.orderOut(nil)
        } else {
            closeSessionPanel()
            gauge?.remove()
            gauge = nil
            panel.orderFrontRegardless()
            fitPanel()
        }
    }

    /// 지금 값을 게이지에 넘긴다: 「칸 순서」대로 켜 둔 회사마다 색 점 하나와 원들(5시간·주간·모델별)
    private func updateGauge() {
        guard let gauge else { return }
        let now = Date()
        func group(_ name: String, _ snap: ProviderSnapshot, _ color: Color) -> MenuBarGauge.Group {
            var rings = snap.visibleWindows(showModels: model.showModels).map { w in
                MenuBarGauge.Ring(tip: "\(name) · " + T("{0} {1}% 남음 · 초기화 {2}", w.label, w.leftPercent(now: now), w.resetsAt.map(fullTime) ?? "-"),
                                  left: w.leftPercent(now: now))
            }
            if rings.isEmpty { rings = [MenuBarGauge.Ring(tip: "\(name) · \(snap.message ?? T("값이 없습니다"))", left: nil)] }
            return MenuBarGauge.Group(dot: NSColor(color), rings: rings)
        }
        let groups = model.order.compactMap { pane -> MenuBarGauge.Group? in
            switch pane {
            case .claude where model.showClaude: return group("Claude", model.claude, claudeTint)
            case .codex where model.showCodex: return group("ChatGPT", model.codex, codexTint)
            default: return nil
            }
        }
        gauge.update(groups: groups, waiting: model.showSessions ? model.sessions.filter { $0.state == .waiting }.count : 0, size: Display.size)
    }

    private func showGaugeMenu() {
        closeSessionPanel()
        gauge?.showMenu(contextMenu())
    }

    private func gaugeClicked() {
        if ignoreGaugeClick { ignoreGaugeClick = false; return }  // 열려 있던 패널이 이 클릭에 먼저 닫혔다
        toggleSessionPanel()
    }

    private func toggleSessionPanel() {
        if sessionPanel?.isVisible == true { closeSessionPanel() } else { showSessionPanel() }
    }

    private func showSessionPanel() {
        let panel = sessionPanel ?? makeSessionPanel()
        model.hovered = nil
        placeSessionPanel(animated: true)
        panel.makeKeyAndOrderFront(nil)  // 초점을 뺏지 않는 패널: 쓰던 앱은 앞에 그대로, Esc 만 받는다
        // 바깥(다른 앱·이 앱의 다른 창)을 누르면 닫는다. 게이지를 눌러 닫았으면 그 클릭으로 다시 열지 않는다
        panelMonitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.closeSessionPanel()
        } as Any)
        panelMonitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, event.window !== self.sessionPanel else { return event }
            if event.type == .leftMouseDown, event.window != nil, event.window === self.gauge?.window { self.ignoreGaugeClick = true }
            self.closeSessionPanel()
            return event
        } as Any)
    }

    private func closeSessionPanel() {
        for monitor in panelMonitors { NSEvent.removeMonitor(monitor) }
        panelMonitors = []
        guard let panel = sessionPanel, panel.isVisible else { return }
        panel.orderOut(nil)
        model.hovered = nil
    }

    private func makeSessionPanel() -> SessionPanel {
        let hosting = NSHostingView(rootView: SessionPanelView(model: model))
        let root = ContainerView(frame: NSRect(origin: .zero, size: hosting.fittingSize))
        root.material = .hudWindow
        root.blendingMode = .behindWindow
        root.state = .active
        root.maskImage = roundedMask(radius: 12)
        root.input.draggable = false
        root.input.content = hosting
        root.input.onClick = { [weak self] point in
            guard let self else { return }
            if case .session(let id)? = hitTarget(at: point, in: self.model.panelHits),
               let s = self.model.sessions.first(where: { $0.id == id }) {
                self.closeSessionPanel()
                SessionOpener.open(s)
            }
        }
        root.input.onHover = { [weak self] point in self?.hover(point, hits: self?.model.panelHits) }
        root.input.onRightClick = { _ in }
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = root.bounds
        root.addSubview(hosting)
        let made = SessionPanel(contentRect: root.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        made.contentView = root
        made.isOpaque = false
        made.backgroundColor = .clear
        made.hasShadow = true
        made.level = .popUpMenu
        made.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        made.hidesOnDeactivate = false
        made.isReleasedWhenClosed = false
        made.appearance = NSAppearance(named: .darkAqua)
        made.onCancel = { [weak self] in self?.closeSessionPanel() }
        sessionPanel = made
        sessionHosting = hosting
        return made
    }

    /// 게이지 바로 아래, 오른쪽 끝을 게이지 오른쪽 끝에 맞춘다(화면 밖으로 나가지 않게). 처음 열 때는 조금 위에서 내려온다
    private func placeSessionPanel(animated: Bool) {
        guard let panel = sessionPanel, let hosting = sessionHosting else { return }
        let size = hosting.fittingSize
        let anchor = gauge?.screenFrame ?? NSRect(x: (NSScreen.main?.visibleFrame.maxX ?? 400) - 20, y: NSScreen.main?.visibleFrame.maxY ?? 400, width: 1, height: 1)
        let visible = (NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main)?.visibleFrame ?? .zero
        let x = max(visible.minX + 4, min(anchor.maxX - size.width, visible.maxX - size.width - 4))
        let frame = NSRect(x: x, y: anchor.minY - 6 - size.height, width: size.width, height: size.height)
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            if panel.frame != frame { panel.setFrame(frame, display: true) }
            panel.alphaValue = 1
            return
        }
        panel.setFrame(frame.offsetBy(dx: 0, dy: 10), display: false)
        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 1
        }
    }

    // MARK: Dock 앱

    /// 앱이 앞에 있을 때 위쪽 메뉴 막대에 나오는 메뉴(⌘R 새로고침, ⌘Q 종료)
    private func buildMainMenu() {
        let appMenu = NSMenu()
        appMenu.delegate = self
        fillAppMenu(appMenu)
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        let mainMenu = NSMenu()
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu
    }

    private func fillAppMenu(_ appMenu: NSMenu) {
        appMenu.removeAllItems()
        appMenu.addItem(menuItem(T("지금 새로고침"), #selector(refreshAll), key: "r"))
        appMenu.addItem(menuItem(T("사용 추이…"), #selector(openTrend)))
        appMenu.addItem(.separator())
        addGroupMenus(to: appMenu)
        appMenu.addItem(.separator())
        appMenu.addItem(menuItem(T("AI 사용량 종료"), #selector(quit), key: "q"))
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === NSApp.mainMenu?.items.first?.submenu { fillAppMenu(menu) }
    }

    /// Dock 아이콘을 누르면 창을 맨 앞으로(다른 데스크톱에 있다가 돌아왔을 때 등)
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if Display.mode == 1 { toggleSessionPanel() } else { panel.orderFrontRegardless() }  // 메뉴 막대 간단 모드면 세션 패널을
        return true
    }

    /// Dock 아이콘 오른쪽 클릭 메뉴(「종료」는 macOS 가 붙여 준다)
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(menuItem(T("지금 새로고침"), #selector(refreshAll)))
        menu.addItem(menuItem(T("사용 추이…"), #selector(openTrend)))
        menu.addItem(.separator())
        addGroupMenus(to: menu)
        return menu
    }

    /// 시스템 설정 → 일반 → 로그인 항목에 이 앱을 넣고 뺀다
    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = T("로그인 항목을 바꾸지 못했습니다")
            alert.informativeText = T("시스템 설정 → 일반 → 로그인 항목에서 「AI 사용량」을 직접 추가하거나 빼 주세요.\n({0})", error.localizedDescription)
            alert.addButton(withTitle: T("시스템 설정 열기"))
            alert.addButton(withTitle: T("닫기"))
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { SMAppService.openSystemSettingsLoginItems() }
            return
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleAlerts):
            menuItem.state = enabled ? .on : .off
        case #selector(toggleModelAlerts):
            menuItem.state = enabled && modelAlerts ? .on : .off
            return enabled  // 「한도 알림」이 꺼져 있으면 흐리게
        case #selector(toggleModelDisplay):
            menuItem.state = model.showModels ? .on : .off
        case #selector(toggleLoginItem):
            menuItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        case #selector(toggleClaude):
            menuItem.state = model.showClaude ? .on : .off
            return model.showCodex  // 혼자 켜져 있으면 끌 수 없다(흐리게)
        case #selector(toggleCodex):
            menuItem.state = model.showCodex ? .on : .off
            return model.showClaude
        case #selector(toggleSessions):
            menuItem.state = model.showSessions ? .on : .off
        case #selector(chooseDisplayMode(_:)):
            menuItem.state = Display.mode == menuItem.tag ? .on : .off
        case #selector(chooseMenuBarSize(_:)):
            menuItem.state = Display.size == menuItem.tag ? .on : .off
        case #selector(chooseAppearance(_:)):
            guard let key = menuItem.representedObject as? String, let setting = PetSetting(rawValue: key) else { return false }
            menuItem.state = model.appearance[setting] == menuItem.tag ? .on : .off
        case #selector(moveOrderUp(_:)):
            return menuItem.tag > 0  // 맨 위 칸은 더 올릴 수 없다
        case #selector(foldAll(_:)):
            let folds = [model.foldSessions, model.foldClaude, model.foldCodex]
            return menuItem.tag == 1 ? !folds.allSatisfy { $0 } : folds.contains(true)
        case #selector(chooseLanguage(_:)):
            menuItem.state = (menuItem.representedObject as? String) == L10n.choice ? .on : .off
        case #selector(manualCheckForUpdate):
            return !updating  // 받는 중에는 흐리게
        default:
            break
        }
        return true
    }
}

// MARK: - Claude Code 상태 표시줄 (--statusline)

/// Claude Code 가 넘겨준 JSON 에서 한도를 세션별 파일로 남기고, 상태 표시줄 글자를 돌려준다.
/// 윈도우 판 AIUsageStatus --statusline 과 같은 모양. jq 없이 돌아서 다른 맥에 그대로 걸 수 있다.
enum StatusLine {
    static func handle(_ input: Data) -> String {
        guard let root = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else { return "" }
        saveLimits(root)
        saveSeen(root)
        return render(root)
    }

    /// 상태 표시줄이 돌았다는 표시와 한도 값이 왔는지(구독 로그인이 아니면 rate_limits 가 없다)
    static func saveSeen(_ root: [String: Any]) {
        let seen: [String: Any] = ["at": Date().timeIntervalSince1970, "limits": root["rate_limits"] is [String: Any],
                                   "version": root["version"] as? String ?? ""]
        guard let data = try? JSONSerialization.data(withJSONObject: seen) else { return }
        try? FileManager.default.createDirectory(atPath: homeDir + "/.cache/ai-usage", withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: ClaudeCodeLink.seenPath), options: .atomic)
    }

    static func saveLimits(_ root: [String: Any]) {
        guard let id = root["session_id"] as? String, id.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil,
              var limits = root["rate_limits"] as? [String: Any] else { return }
        limits["account"] = ClaudeCodeAccount.identity()  // 어느 계정 값인지(계정을 바꿔도 섞이지 않게)
        guard let data = try? JSONSerialization.data(withJSONObject: limits) else { return }
        let dir = homeDir + "/.cache/ai-usage/claude"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let temp = "\(dir)/.\(id).tmp"
        guard FileManager.default.createFile(atPath: temp, contents: data) else { return }
        if rename(temp, "\(dir)/\(id).json") != 0 { try? FileManager.default.removeItem(atPath: temp) }
    }

    static let reset = "\u{1b}[0m", dim = "\u{1b}[2m", cyan = "\u{1b}[36m", white = "\u{1b}[97m", sky = "\u{1b}[38;5;117m"

    /// 남은 비율에 따라 초록(여유)·노랑(주의)·빨강(부족)
    static func color(_ left: Int) -> String { left >= 50 ? "\u{1b}[32m" : left >= 20 ? "\u{1b}[33m" : "\u{1b}[31m" }

    static func effortColor(_ level: String) -> String {
        ["low": "\u{1b}[90m", "medium": "\u{1b}[34m", "high": "\u{1b}[35m", "xhigh": "\u{1b}[38;5;208m", "max": "\u{1b}[1;31m"][level] ?? ""
    }

    static func k(_ n: Double) -> String { n >= 1_000_000 ? String(format: "%.1fM", n / 1_000_000) : "\(Int(n / 1000))K" }

    static func render(_ root: [String: Any]) -> String {
        let sep = " \(dim)·\(reset) "
        var lines: [String] = []

        // 1줄: 저장소 · 워크트리 · PR (git 저장소 밖이면 생략)
        let workspace = root["workspace"] as? [String: Any]
        var location: [String] = []
        if let repo = (workspace?["repo"] as? [String: Any])?["name"] as? String, !repo.isEmpty { location.append("\(T("저장소")) \(white)\(repo)\(reset)") }
        if let worktree = workspace?["git_worktree"] as? String, !worktree.isEmpty { location.append("\(T("워크트리")) \(sky)\(worktree)\(reset)") }
        if let pr = number((root["pr"] as? [String: Any])?["number"]) { location.append("PR #\(Int(pr))") }
        if !location.isEmpty { lines.append(location.joined(separator: sep)) }

        // 2줄: 모델 · 추론 강도 │ 컨텍스트
        var line = "\(cyan)\((root["model"] as? [String: Any])?["display_name"] as? String ?? "?")\(reset)"
        if let level = (root["effort"] as? [String: Any])?["level"] as? String, !level.isEmpty {
            line += "\(sep)\(T("추론 강도")) \(effortColor(level))\(level)\(reset)"
        }
        if let context = root["context_window"] as? [String: Any], let remaining = number(context["remaining_percentage"]) {
            let left = Int(remaining.rounded(.down))
            line += " \(dim)│\(reset) \(T("컨텍스트")) \(color(left))\(T("{0}% 남음", left))\(reset) "
                + "\(dim)(\(k(number(context["total_input_tokens"]) ?? 0))/\(k(number(context["context_window_size"]) ?? 0)))\(reset)"
        }
        lines.append(line)

        // 3줄: 사용 한도(Claude 구독으로 로그인했을 때만 온다)
        if let limits = root["rate_limits"] as? [String: Any] {
            var parts: [String] = []
            if let five = limits["five_hour"] as? [String: Any], let used = number(five["used_percentage"]) {
                let left = 100 - Int(used.rounded(.down))
                var text = "\(T("5시간 한도")) \(color(left))\(T("{0}% 남음", left))\(reset)"
                if let at = number(five["resets_at"]), at > 0 { text += " \(dim)\(T("({0} 초기화)", clock(Date(timeIntervalSince1970: at))))\(reset)" }
                parts.append(text)
            }
            if let week = limits["seven_day"] as? [String: Any], let used = number(week["used_percentage"]) {
                let left = 100 - Int(used.rounded(.down))
                parts.append("\(T("주간 한도")) \(color(left))\(T("{0}% 남음", left))\(reset)")
            }
            if !parts.isEmpty { lines.append(parts.joined(separator: sep)) }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 자동 업데이트

/// GitHub 저장소 Releases 에 올린 새 판(태그 mac-v<버전>, 설치 묶음 AIUsage-mac-<버전>.zip)을 받아 지금 앱과 바꾼다.
/// 켠 뒤 1분, 그 뒤 6시간마다 확인한다. 끄기: defaults write com.local.ai-usage-pet autoUpdate -bool false
/// 순서: 받기 → SHA-256·번들 id·버전·서명·실행 확인 → 지금 앱을 옆에 숨긴 이름(.<이름>.old)으로 비키고 새 앱을 그 자리에 → 앱이 꺼지면 다시 띄움
enum Updater {
    static let repo = "TeddyBEARs56/ai-usage-widget"
    static let tagPrefix = "mac-v"
    static let assetPrefix = "AIUsage-mac-"
    static let autoKey = "autoUpdate"
    static let reRegisterKey = "updateReRegisterLoginItem"
    static let interval: TimeInterval = 6 * 3600
    static let workDir = homeDir + "/.cache/ai-usage/update"
    static let logPath = homeDir + "/.cache/ai-usage/update.log"

    struct Release {
        let version: String
        let url: URL
        let sha256: String?
    }

    enum Outcome {
        case upToDate(latest: String?)
        case installed(version: String, old: URL)
        case failed(String)
    }

    struct Failure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    static var autoEnabled: Bool { UserDefaults.standard.object(forKey: autoKey) as? Bool ?? true }

    /// 시험할 때는 AIUSAGE_UPDATE_FEED 로 Releases 목록 주소를, AIUSAGE_UPDATE_DELAY 로 첫 확인까지 초를 바꾼다
    static var feed: URL {
        if let text = ProcessInfo.processInfo.environment["AIUSAGE_UPDATE_FEED"], let url = URL(string: text) { return url }
        return URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=30")!
    }
    static var firstDelay: TimeInterval { Double(ProcessInfo.processInfo.environment["AIUSAGE_UPDATE_DELAY"] ?? "") ?? 60 }

    static func parts(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        return parts.map { $0! }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        guard let x = parts(a), let y = parts(b) else { return false }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private static func request(_ url: URL, accept: String, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("AIUsage-updater", forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func fetch(_ url: URL) throws -> Data {
        var result: Result<Data, Error> = .failure(Failure(T("응답 없음")))
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request(url, accept: "application/vnd.github+json", timeout: 30)) { data, response, error in
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                result = .failure(Failure(T("GitHub 응답 {0}", http.statusCode) + (http.statusCode == 404 ? T("(저장소가 비공개거나 없음)") : "")))
            } else {
                result = .success(data ?? Data())
            }
            done.signal()
        }.resume()
        done.wait()
        return try result.get()
    }

    private static func download(_ url: URL, to target: URL) throws {
        var failure: Error?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.downloadTask(with: request(url, accept: "application/octet-stream", timeout: 120)) { location, response, error in
            defer { done.signal() }
            if let error { failure = error; return }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { failure = Failure(T("내려받기 응답 {0}", http.statusCode)); return }
            guard let location else { failure = Failure(T("받은 파일이 없음")); return }
            do {
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: location, to: target)  // 이 블록이 끝나면 임시 파일이 지워진다
            } catch {
                failure = error
            }
        }.resume()
        done.wait()
        if let failure { throw failure }
    }

    /// 올라온 맥 판 가운데 가장 높은 것(초안·미리 보기 판은 뺀다)
    static func latest() throws -> Release? {
        guard let list = try JSONSerialization.jsonObject(with: fetch(feed)) as? [[String: Any]] else {
            throw Failure(T("Releases 목록을 읽지 못함"))
        }
        var best: Release?
        for item in list {
            guard item["draft"] as? Bool != true, item["prerelease"] as? Bool != true,
                  let tag = item["tag_name"] as? String, tag.hasPrefix(tagPrefix) else { continue }
            let version = String(tag.dropFirst(tagPrefix.count))
            guard parts(version) != nil, best.map({ isNewer(version, than: $0.version) }) ?? true,
                  let asset = (item["assets"] as? [[String: Any]])?.first(where: {
                      let name = $0["name"] as? String ?? ""
                      return name.hasPrefix(assetPrefix) && name.hasSuffix(".zip")
                  }),
                  let link = asset["browser_download_url"] as? String, let url = URL(string: link) else { continue }
            let digest = asset["digest"] as? String ?? ""
            best = Release(version: version, url: url, sha256: digest.hasPrefix("sha256:") ? String(digest.dropFirst(7)).lowercased() : nil)
        }
        return best
    }

    /// 이 자리의 앱을 바꿀 수 없으면 그 까닭
    static func cannotReplace(_ app: URL) -> String? {
        guard app.pathExtension == "app" else { return T("앱(.app)으로 실행되지 않았습니다") }
        if app.path.contains("/AppTranslocation/") { return T("격리된 임시 위치에서 실행 중입니다(설치.sh 로 다시 설치해 주세요)") }
        let parent = app.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: parent) else { return T("{0} 에 쓸 수 없습니다", parent) }
        return nil
    }

    /// 확인 → 받기 → 검사 → 바꿔 끼우기. 바꿨으면 옛 앱(숨긴 이름) 경로를 돌려준다. 다시 띄우는 일은 부른 쪽이 한다.
    static func run() -> Outcome {
        let app = Bundle.main.bundleURL
        do {
            guard let release = try latest() else {
                log("확인: 올라온 맥 판 없음(지금 \(current))")
                return .upToDate(latest: nil)
            }
            guard isNewer(release.version, than: current) else {
                log("확인: 최신(지금 \(current), 올라온 최신 \(release.version))")
                return .upToDate(latest: release.version)
            }
            if let reason = cannotReplace(app) { throw Failure(reason) }
            log("새 판 \(release.version) 받기 시작(지금 \(current))")
            let work = URL(fileURLWithPath: workDir)
            try? FileManager.default.removeItem(at: work)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            let zip = work.appendingPathComponent("update.zip")
            try download(release.url, to: zip)
            if let expected = release.sha256 {
                let actual = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
                guard actual == expected else { throw Failure(T("받은 파일이 올라온 것과 다릅니다(SHA-256)")) }
            }
            let unpacked = work.appendingPathComponent("unpacked")
            guard runTool("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]) == 0 else { throw Failure(T("압축을 풀지 못했습니다")) }
            guard let newApp = findApp(in: unpacked) else { throw Failure(T("묶음 안에 앱이 없습니다")) }
            try check(newApp, version: release.version)
            let old = try swap(app: app, with: newApp)
            log("\(release.version) 으로 바꿈")
            return .installed(version: release.version, old: old)
        } catch let failure as Failure {
            log("실패: \(failure.message)")
            return .failed(failure.message)
        } catch {
            log("실패: \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }

    private static func findApp(in dir: URL) -> URL? {
        guard let items = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        for case let url as URL in items {
            if url.pathExtension == "app" { return url }
            if items.level >= 2 { items.skipDescendants() }
        }
        return nil
    }

    /// 같은 앱인지(번들 id), 태그와 같은 버전인지, 서명이 깨지지 않았는지, 이 맥에서 실제로 도는지
    private static func check(_ newApp: URL, version: String) throws {
        guard let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else { throw Failure(T("다른 앱이 들어 있습니다")) }
        guard info["CFBundleShortVersionString"] as? String == version else { throw Failure(T("묶음 안 앱의 버전이 {0} 이 아닙니다", version)) }
        guard runTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path]) == 0 else { throw Failure(T("서명 확인에 실패했습니다")) }
        guard output(newApp.appendingPathComponent("Contents/MacOS/AIUsagePet").path, ["--version"]) == version else {
            throw Failure(T("새 판이 이 맥에서 실행되지 않습니다"))
        }
        runTool("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])
    }

    /// 새 앱을 지금 앱 자리에 넣는다. 지금 앱은 같은 폴더에 숨긴 이름으로 비켜 두고 그 경로를 돌려준다(실패하면 되돌린다).
    private static func swap(app: URL, with newApp: URL) throws -> URL {
        let fm = FileManager.default
        let staged = siblings(of: app).new, old = siblings(of: app).old
        try? fm.removeItem(at: staged)
        try? fm.removeItem(at: old)
        try fm.moveItem(at: newApp, to: staged)  // 다른 디스크면 복사된다 — 그래서 먼저 같은 폴더로 옮겨 둔다
        try fm.moveItem(at: app, to: old)
        do {
            try fm.moveItem(at: staged, to: app)
        } catch {
            try? fm.moveItem(at: old, to: app)
            try? fm.removeItem(at: staged)
            throw error
        }
        return old
    }

    static func siblings(of app: URL) -> (new: URL, old: URL) {
        let parent = app.deletingLastPathComponent()
        return (parent.appendingPathComponent("." + app.lastPathComponent + ".new"),
                parent.appendingPathComponent("." + app.lastPathComponent + ".old"))
    }

    /// pid 프로세스(지금 떠 있는 창)가 끝나면 옛 앱을 지우고 새 앱을 띄운다. 로그인 항목이었으면 새 앱이 다시 등록한다.
    static func relaunch(after pid: pid_t, app: URL, old: URL) {
        if SMAppService.mainApp.status == .enabled {
            UserDefaults.standard.set(true, forKey: reRegisterKey)
            UserDefaults.standard.synchronize()
        }
        let script = """
            while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done
            /bin/rm -rf "$3"
            /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$2" >/dev/null 2>&1
            /usr/bin/open "$2"
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(pid), app.path, old.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    /// 새 판으로 처음 켜졌을 때: 남은 옛 앱을 지우고, 로그인 항목이었으면 다시 등록한다(임시 서명이라 바뀐 앱을 못 알아볼 수 있다)
    static func afterLaunch() {
        try? FileManager.default.removeItem(at: siblings(of: Bundle.main.bundleURL).old)
        guard UserDefaults.standard.bool(forKey: reRegisterKey) else { return }
        UserDefaults.standard.removeObject(forKey: reRegisterKey)
        if SMAppService.mainApp.status != .enabled {
            do {
                try SMAppService.mainApp.register()
                log("로그인 항목 다시 등록")
            } catch {
                log("로그인 항목 다시 등록 실패: \(error.localizedDescription)")
            }
        }
    }

    static func log(_ line: String) {
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: logPath))?[.size] as? Int, size > 100_000 { try? fm.removeItem(atPath: logPath) }
        let data = Data("\(logFormat.string(from: Date())) \(current) \(line)\n".utf8)
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? fm.createDirectory(atPath: (logPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            fm.createFile(atPath: logPath, contents: data)
        }
    }

    private static let logFormat: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return format
    }()

    @discardableResult
    private static func runTool(_ path: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// 실행해서 표준 출력을 돌려준다(10초 넘게 걸리면 끊는다)
    private static func output(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 시작

/// 이미 떠 있으면 false (로그인 자동 실행과 직접 실행이 겹쳐도 하나만 뜨게).
/// 다시 띄울 때는 앞의 것이 꺼지는 중일 수 있어 3초까지 기다린다.
private var historyWriter = false
func takeSingleInstanceLock() -> Bool {
    let dir = homeDir + "/.cache/ai-usage"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    // O_CLOEXEC: 띄우는 프로그램(codex, 다시 띄우기 도우미)이 잠금을 물려받아 쥐고 있지 않게
    let fd = open(dir + "/pet.lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
    if fd < 0 { return true }
    for _ in 0..<30 {
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { historyWriter = true; return true }  // fd 는 닫지 않는다(프로세스가 끝나면 풀린다)
        usleep(100_000)
    }
    close(fd)
    return false
}

@MainActor func printOnce() {
    let codex = CodexReader()
    codex.readLog()
    codex.readServerSync()
    let fromLog = codex.fromLog
    let usageStarted = Date()
    let usageError = ClaudeUsageCommand.fetch(reason: "확인(--print)")
    let usageSeconds = Date().timeIntervalSince(usageStarted)
    let now = Date()
    let claude = ClaudeReader().read(now: now)
    print(describe("Claude", claude, now: now))
    let link: String
    switch ClaudeCodeLink.state() {
    case .noClaudeCode: link = T("Claude Code 없음(~/.claude 폴더 없음)")
    case .notConnected: link = T("안 됨 — 지금 명령: {0}", ClaudeCodeLink.command() ?? T("없음"))
    case .broken: link = T("끊김(가리키는 앱 경로가 없음) — 지금 명령: {0}", ClaudeCodeLink.command() ?? T("없음"))
    case .connected: link = T("됨")
    }
    print("  " + T("출처: {0} · Claude Code 연결: {1}", claude.windows.isEmpty ? "-" : claude.source ?? "-", link))
    print("  " + T("Claude Code /usage: {0}", usageError ?? T("됨 · {0}초 · {1}", String(format: "%.1f", usageSeconds),
                                                                 ClaudeUsageCommand.findClaude() ?? "-")))
    if let data = FileManager.default.contents(atPath: ClaudeCodeLink.seenPath),
       let seen = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let at = number(seen["at"]) {
        print("  " + T("상태 표시줄 마지막 실행 {0} · 한도 값 {1} · Claude Code {2}", fullTime(Date(timeIntervalSince1970: at)), seen["limits"] as? Bool == true ? T("옴") : T("안 옴"), seen["version"] as? String ?? "?"))
    }
    if let desktop = ClaudeDesktopUsage.lastWrite() {
        print("  " + T("데스크톱 앱 기록 {0} · 마지막으로 바뀜 {1}", desktop.path, fullTime(desktop.at)))
    } else {
        print("  " + T("데스크톱 앱 기록: 못 찾음"))
    }
    // Claude 값이 새것이면(예: /usage 로 받음) 데스크톱 기록이 멈춰 있어도 알릴 까닭이 없다
    if claude.observedAt.map({ now.timeIntervalSince($0) >= ClaudeDesktopUsage.staleAfter }) ?? true,
       let hint = ClaudeDesktopUsage.staleHint(now: now) { print("  " + hint) }
    print(describe(T("ChatGPT · 기록"), fromLog ?? ProviderSnapshot(message: T("최근 기록 없음")), now: now))
    print(describe(T("ChatGPT · 서버"), codex.fromServer ?? ProviderSnapshot(message: codex.serverError ?? T("실패")), now: now))
    print(describe(T("ChatGPT · 표시"), codex.current, now: now))
    let sessionsAt = Date()
    print(describeSessions(sortSessions(ClaudeSessionReader().read(now: sessionsAt) + CodexSessionReader().read(now: sessionsAt)), now: sessionsAt))
}

/// --check-update: 올라온 최신 판만 본다(바꾸지 않음)
func checkUpdateOnce() {
    do {
        if let release = try Updater.latest() {
            let newer = Updater.isNewer(release.version, than: Updater.current)
            print(T("지금 {0} · 올라온 최신 {1} — {2}", Updater.current, release.version, newer ? T("새 판 있음") : T("최신")))
            print("  \(release.url.absoluteString)")
            print("  sha256 \(release.sha256 ?? T("(GitHub 이 주지 않음 — 검사 생략)"))")
        } else {
            print(T("지금 {0} · 올라온 맥 판 없음", Updater.current))
        }
    } catch let failure as Updater.Failure {
        print(T("확인 실패: {0}", failure.message))
    } catch {
        print(T("확인 실패: {0}", error.localizedDescription))
    }
    if let reason = Updater.cannotReplace(Bundle.main.bundleURL) { print("  " + T("이 자리에서는 자동으로 바꿀 수 없음: {0}", reason)) }
    print("  " + T("자동 업데이트 {0} · 기록 {1}", Updater.autoEnabled ? T("켬") : T("끔(defaults autoUpdate false)"), Updater.logPath))
}

/// --update: 메뉴의 「업데이트 확인」과 같은 일. 같은 자리의 앱이 떠 있으면 끄고 새 판으로 다시 띄운다.
func updateOnce() {
    switch Updater.run() {
    case .upToDate(let latest):
        print(T("최신 버전입니다(지금 {0}, 올라온 최신 {1})", Updater.current, latest ?? T("없음")))
    case .failed(let message):
        print(T("업데이트하지 못했습니다: {0}", message))
    case .installed(let version, let old):
        let app = Bundle.main.bundleURL
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first { $0.bundleURL?.standardizedFileURL.path == app.standardizedFileURL.path }
        if let running {
            Updater.relaunch(after: running.processIdentifier, app: app, old: old)
            running.terminate()
            print(T("{0} 으로 바꿨습니다 — 떠 있던 창을 새 판으로 다시 띄웁니다", version))
        } else {
            try? FileManager.default.removeItem(at: old)
            print(T("{0} 으로 바꿨습니다", version))
        }
    }
}

private func fillSnapshotSample(_ model: UsageModel) {
    let now = Date(timeIntervalSince1970: 1_793_920_000)
    model.now = now
    model.order = Pane.standard
    model.showClaude = true
    model.showCodex = true
    model.showSessions = true
    let weekly = LimitWindow(id: "weekly", minutes: 10_080, usedPercent: 0, resetsAt: now.addingTimeInterval(3 * 86_400))
    model.claude = ProviderSnapshot(windows: [
        LimitWindow(id: "5h", minutes: 300, usedPercent: 18, resetsAt: now.addingTimeInterval(3600)), weekly
    ], observedAt: now)
    model.codex = ProviderSnapshot(windows: [weekly], observedAt: now, plan: "Pro Lite")
    model.sessions = [
        AgentSession(id: "waiting", tool: .claude, name: "결제 웹훅 재시도 고치기", cwd: "", state: .waiting, since: now.addingTimeInterval(-30)),
        AgentSession(id: "working", tool: .codex, name: "ai-usage-widget", cwd: "", state: .working, since: now.addingTimeInterval(-720)),
        AgentSession(id: "done", tool: .claude, name: "Local LLM", cwd: "", state: .done, since: now.addingTimeInterval(-480))
    ]
}

/// --gauge-snapshot <png> [--size 75|100] [--light]: 메뉴 막대 게이지 그림(보기 시험용, 예시 값)
@MainActor func saveGaugeSnapshot(to path: String, size: Int, dark: Bool) {
    _ = NSApplication.shared
    let model = UsageModel()
    fillSnapshotSample(model)
    let now = model.now
    func group(_ name: String, _ snap: ProviderSnapshot, _ color: Color) -> MenuBarGauge.Group {
        MenuBarGauge.Group(dot: NSColor(color), rings: snap.visibleWindows(showModels: true).map {
            MenuBarGauge.Ring(tip: name, left: $0.leftPercent(now: now))
        })
    }
    let bar: CGFloat = 24
    let layout = MenuBarGauge.layout(groups: [group("Claude", model.claude, claudeTint), group("ChatGPT", model.codex, codexTint)],
                                     waiting: 1, size: size, barHeight: bar)
    let scale: CGFloat = 4, margin: CGFloat = 8
    let width = layout.size.width + margin * 2
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(bar * scale),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
    rep.size = NSSize(width: width, height: bar)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
    NSRect(x: 0, y: 0, width: width, height: bar).fill()
    NSGraphicsContext.current?.cgContext.translateBy(x: margin, y: 0)
    MenuBarGauge.draw(layout, dark: dark)
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
    do { try png.write(to: URL(fileURLWithPath: path)); print(path) } catch { fputs("저장 실패: \(error)\n", stderr); exit(1) }
}

@MainActor func saveSnapshot(to path: String, sample: Bool, appearance: PetAppearance?, fold: Bool = false, panel: Bool = false, hovered: String? = nil) {
    _ = NSApplication.shared
    renderingStill = true
    let model = UsageModel()
    if let appearance { model.appearance = appearance }
    model.foldSessions = fold
    model.foldClaude = fold
    model.foldCodex = fold
    model.hovered = hovered
    if sample {
        fillSnapshotSample(model)
    } else {
        model.claude = ClaudeReader().read(now: model.now)
        let codex = CodexReader()
        codex.readLog()
        codex.readServerSync()
        model.codex = codex.current
        model.sessions = sortSessions(ClaudeSessionReader().read(now: model.now) + CodexSessionReader().read(now: model.now))
    }
    let content: AnyView = panel ? AnyView(SessionPanelView(model: model)) : AnyView(PetView(model: model))
    let view = content
        .background(Color(red: 0.12, green: 0.12, blue: 0.13, opacity: panel ? 1 : model.appearance.opacity))
        .clipShape(RoundedRectangle(cornerRadius: panel ? 12 : model.appearance.length(14)))
        .environment(\.colorScheme, .dark)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else {
        fputs("그림을 만들지 못했습니다\n", stderr)
        exit(1)
    }
    do {
        try png.write(to: URL(fileURLWithPath: path))
        print(path)
    } catch {
        fputs("저장 실패: \(error)\n", stderr)
        exit(1)
    }
}

@main
enum Main {
    @MainActor static func main() {
        signal(SIGPIPE, SIG_IGN)
        let args = CommandLine.arguments
        if args.contains("--trend-json") || args.contains("--test-alerts") || args.contains("--trend-snapshot") || args.contains("--record-once")
            || args.contains("--alerts-once") {
            do {
                if let i = args.firstIndex(of: "--test-alerts") {
                    guard args.indices.contains(i+1) else { throw CocoaError(.coderInvalidValue) }
                    try testAlerts(args[i+1]); return
                }
                var now = millis(Date())
                if let i = args.firstIndex(of: "--now") {
                    guard args.indices.contains(i+1), let d = parseDate(args[i+1]) else { throw CocoaError(.coderInvalidValue) }
                    now = millis(d)
                }
                if args.contains("--record-once") { print(try recordOnce(now: now)); return }
                if args.contains("--alerts-once") { print(try alertsOnce(args, now: now)); return }
                let user = UsageAccount(now: now)
                var scan = SourceScan()
                let result = TrendResult.calculate(UsageHistory().rows + scan.read(user, now: now), user: user, now: now)
                if let i = args.firstIndex(of: "--trend-snapshot") {
                    guard args.indices.contains(i+2), ["week","four-weeks"].contains(args[i+1]) else { throw CocoaError(.coderInvalidValue) }
                    try trendPNG(result, now: now, month: args[i+1] == "four-weeks", path: args[i+2])
                } else {
                    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                    print(String(decoding: try encoder.encode(result), as: UTF8.self))
                }
            } catch { fputs("\(error)\n", stderr); exit(2) }
            return
        }
        if args.contains("--version") {  // 자동 업데이트가 받은 새 판이 이 맥에서 도는지 볼 때도 쓴다
            print(Updater.current)
            return
        }
        if args.contains("--statusline") {
            // 상태 표시줄이 실패해도 Claude Code 는 그대로 돌아야 하므로, 읽지 못하면 아무것도 내지 않는다
            let input = FileHandle.standardInput.readDataToEndOfFile()
            FileHandle.standardOutput.write(Data(StatusLine.handle(input).utf8))
            return
        }
        if args.contains("--print") {
            printOnce()
            return
        }
        if args.contains("--sessions") {  // 세션 목록만(값은 묻지 않는다) — Windows 판 AIUsageStatus --sessions 와 같다
            let now = Date()
            print(describeSessions(sortSessions(ClaudeSessionReader().read(now: now) + CodexSessionReader().read(now: now)), now: now))
            return
        }
        if let i = args.firstIndex(of: "--gauge-snapshot") {
            guard args.indices.contains(i + 1) else { fputs("--gauge-snapshot <png> [--size 75|100] [--light]\n", stderr); exit(2) }
            let size = args.firstIndex(of: "--size").flatMap { args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil } ?? 100
            saveGaugeSnapshot(to: args[i + 1], size: size == 75 ? 75 : 100, dark: !args.contains("--light"))
            return
        }
        if args.contains("--connect") {  // 메뉴의 「Claude Code 에 연결」과 같은 일(터미널에서)
            print(ClaudeCodeLink.connect())
            return
        }
        if let i = args.firstIndex(of: "--snapshot") {
            guard args.indices.contains(i + 1), !args[i + 1].hasPrefix("--") else {
                fputs("--snapshot <png> [--sample] [--appearance 0,100,100]\n", stderr)
                exit(2)
            }
            var appearance: PetAppearance?
            if let j = args.firstIndex(of: "--appearance") {
                let parts = args.dropFirst(j + 1).first?.components(separatedBy: ",") ?? []
                let settings = PetSetting.allCases
                var look = PetAppearance()
                guard parts.count == settings.count else { fputs("Invalid --appearance\n", stderr); exit(2) }
                for (part, setting) in zip(parts, settings) {
                    guard let n = Int(part), setting.values.contains(n) else { fputs("Invalid --appearance\n", stderr); exit(2) }
                    look[setting] = n
                }
                appearance = look
            }
            let hovered = args.firstIndex(of: "--hover").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
            saveSnapshot(to: args[i + 1], sample: args.contains("--sample"), appearance: appearance, fold: args.contains("--fold"),
                         panel: args.contains("--panel"), hovered: hovered)
            return
        }
        if args.contains("--check-update") {
            checkUpdateOnce()
            return
        }
        if args.contains("--update") {
            updateOnce()
            return
        }
        guard takeSingleInstanceLock() else { return }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)  // Dock 에 아이콘이 나오고, Dock 에서 열고 끈다
        withExtendedLifetime(delegate) { app.run() }
    }
}

// MARK: - Source observations and weekly history

private let dayMs: Int64 = 86_400_000
private let weekMs = 7 * dayMs
private let resetTolerance: Int64 = 600_000
private let usageDirectory = URL(fileURLWithPath: homeDir).appendingPathComponent(".cache/ai-usage")
private func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded(.down)) }
private let lastTimestamp: Int64 = 253_402_300_799_999  // Last millisecond representable by both platforms.
private func validMillis(_ value: Double?) -> Int64? {
    guard let value, value >= 1, value <= Double(lastTimestamp) else { return nil }
    return Int64(value)
}
private func instant(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

private struct UsageAccount: Equatable {
    let claude: String?
    let org: String?
    let codex: String?
    let since: Int64
    init(now: Int64) {
        claude = ClaudeCodeAccount.identity()
        org = ClaudeCodeAccount.organization()
        codex = CodexReader.currentAccount()
        let saved = readJSONObject(AccountSwitch.path)?["claude"] as? [String: Any]
        since = saved == nil ? 0 : saved?["id"] as? String == claude
            ? (validMillis(number(saved?["since"]).map { $0 * 1000 }) ?? 0) : now
    }
    static func hash(_ provider: String, _ id: String?) -> String? {
        guard let id, !id.isEmpty else { return nil }
        return SHA256.hash(data: Data((provider + "\0" + id).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    var keys: [String: String] {
        ["claude": Self.hash("claude", claude), "codex": Self.hash("codex", codex)].compactMapValues { $0 }
    }
}

private struct UsageEvent: Codable, Hashable {
    var v = 1
    let provider: String
    let account: String
    let minutes: Int
    let atMs: Int64
    let resetMs: Int64?
    let used: Double
    let source: String
    var quality: String
    var slot: String?
    var valid: Bool {
        v == 1 && ["claude", "codex"].contains(provider) && account.utf8.count == 64 &&
        (0...Int(Int32.max)).contains(minutes) && (minutes > 0 || resetMs != nil) && (0...100).contains(used) &&
        (1...lastTimestamp).contains(atMs) && (1...lastTimestamp).contains(resetMs ?? 1) &&
        ["observed","rough"].contains(quality)
    }
    enum CodingKeys: CodingKey { case v, provider, account, minutes, atMs, resetMs, used, source, quality, slot }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v)
        try c.encode(provider, forKey: .provider); try c.encode(account, forKey: .account)
        try c.encode(minutes, forKey: .minutes); try c.encode(atMs, forKey: .atMs)
        try c.encode(resetMs, forKey: .resetMs); try c.encode(used, forKey: .used)
        try c.encode(source, forKey: .source); try c.encode(quality, forKey: .quality)
        try c.encodeIfPresent(slot, forKey: .slot)
    }
    static func liveRows(claude: ProviderSnapshot, codex: CodexReader) -> [UsageEvent] {
        claude.observations + (codex.fromLog?.observations ?? []) + (codex.fromServer?.observations ?? [])
    }
    var eventKey: UsageEvent { var copy = self; copy.slot = nil; copy.quality = ""; return copy }
    static func ordered(_ a: Self, _ b: Self) -> Bool {
        if a.atMs != b.atMs { return a.atMs < b.atMs }
        if a.used != b.used { return a.used < b.used }
        if a.resetMs != b.resetMs { return (a.resetMs ?? .max) < (b.resetMs ?? .max) }
        if a.quality != b.quality { return a.quality == "observed" }
        return a.source < b.source
    }

    static func windows(_ windows: [LimitWindow], at: Date, provider: String, id: String?, source: String) -> [Self] {
        guard let key = UsageAccount.hash(provider, id) else { return [] }
        return windows.compactMap { w in
            var reset = validMillis(w.resetsAt.map { $0.timeIntervalSince1970 * 1000 })
            // /usage 글에서 읽은 초기화 시각이 창 길이보다 멀면(날짜 없는 시각을 내일로 넘긴 경우 등) 원천 값으로 쓰지 않는다
            if source == ClaudeUsageCommand.historySource, let r = reset, r > millis(at) + Int64(w.minutes) * 60_000 { reset = nil }
            let event = Self(provider: provider, account: key, minutes: w.minutes, atMs: millis(at),
                             resetMs: reset, used: w.usedPercent, source: source,
                             quality: provider == "claude" && reset == nil ? "rough" : "observed", slot: w.id)
            return event.valid ? event : nil
        }
    }
}

private struct SourceScan {
    struct Stamp: Equatable { let size: Int; let modified: Date }
    var stamps: [String: Stamp] = [:]
    var account: UsageAccount?
    mutating func read(_ user: UsageAccount, now: Int64) -> [UsageEvent] {
        if account != user { stamps.removeAll(); account = user }
        let fm = FileManager.default
        var rows: [UsageEvent] = []
        func stamp(_ path: String) -> Stamp? {
            guard let attrs = try? fm.attributesOfItem(atPath: path), let date = attrs[.modificationDate] as? Date,
                  let size = attrs[.size] as? NSNumber else { return nil }
            return Stamp(size: size.intValue, modified: date)
        }
        func scan(_ path: String, _ body: (Stamp) -> Bool) {
            guard let before = stamp(path), before != stamps[path] else { return }
            let start = rows.count
            let complete = body(before)
            if before != stamp(path) { rows.removeSubrange(start...) }
            else if complete { stamps[path] = before }
        }
        if let key = user.keys["claude"] {
            let dir = usageDirectory.appendingPathComponent("claude").path
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".json") && !name.hasPrefix(".") {
                let path = dir + "/" + name
                let command = name == ClaudeUsageCommand.fileName
                scan(path) { file in
                    let at = millis(file.modified)
                    guard at >= now - 8 * dayMs else { return true }
                    guard at <= now, let obj = readJSONObject(path) else { return false }
                    if let owner = obj["account"] as? String { guard owner == user.claude else { return true } }
                    else if command || at < user.since { return true }  // /usage 기록은 계정이 꼭 적혀 있어야 한다
                    if let w = obj["seven_day"] as? [String: Any], let used = number(w["used_percentage"]) {
                        let window = LimitWindow(id: "seven_day", minutes: 10080, usedPercent: used,
                                                 resetsAt: number(w["resets_at"]).map(Date.init(timeIntervalSince1970:)))
                        rows += UsageEvent.windows([window], at: file.modified, provider: "claude", id: user.claude,
                                                   source: command ? ClaudeUsageCommand.historySource : "claude-session")
                    }
                    return true
                }
            }
            for path in ClaudeDesktopUsage.paths() {
                scan(path) { _ in
                    guard let samples = readJSONObject(path)?["samples"] as? [[String: Any]] else { return false }
                    for s in samples {
                        guard let org = user.org, s["org"] as? String == org, let t = validMillis(number(s["t"])),
                              t >= user.since, let used = number((s["u"] as? [String: Any] ?? s)["sd"]) else { continue }
                        rows.append(UsageEvent(provider: "claude", account: key, minutes: 10080, atMs: t,
                                               resetMs: nil, used: used, source: "claude-desktop", quality: "rough", slot: "seven_day"))
                    }
                    return true
                }
            }
        }
        let root = homeDir + "/.codex/sessions"
        if let id = user.codex, !id.isEmpty, let files = fm.enumerator(atPath: root) {
            for case let name as String in files where name.hasSuffix(".jsonl") && (name as NSString).lastPathComponent.hasPrefix("rollout-") {
                let path = root + "/" + name
                scan(path) { _ in
                    guard let file = fopen(path, "r") else { return false }
                    var buf: UnsafeMutablePointer<CChar>?
                    var cap = 0
                    defer { free(buf); fclose(file) }
                    let n = getline(&buf, &cap, file)
                    guard n > 0, let head = buf, head[n-1] == 10,
                          let meta = (try? JSONSerialization.jsonObject(with: Data(bytes: head, count: n))) as? [String: Any],
                          meta["type"] as? String == "session_meta" else { return false }
                    guard (meta["payload"] as? [String: Any])?["creator_account_id"] as? String == id else { return true }
                    while true {
                        let length = getline(&buf, &cap, file)
                        guard length > 0, let line = buf else { return feof(file) != 0 }
                        guard line[length-1] == 10 else { return false }
                        guard strstr(line, "\"rate_limits\"") != nil,
                              let event = (try? JSONSerialization.jsonObject(with: Data(bytes: line, count: length))) as? [String: Any],
                              let at = (event["timestamp"] as? String).flatMap(parseDate),
                              millis(at) >= now - 35 * dayMs, millis(at) <= now,
                              let limits = (event["payload"] as? [String: Any])?["rate_limits"] as? [String: Any],
                              (limits["limit_id"] as? String ?? "codex") == "codex" else { continue }
                        rows += UsageEvent.windows(CodexReader.windows(from: limits).filter { $0.minutes == 10080 },
                                                   at: at, provider: "codex", id: id, source: "codex-rollout")
                    }
                }
            }
        }
        return rows.filter { $0.valid && $0.atMs >= now - 35 * dayMs && $0.atMs <= now }
    }
}

private func nearest(_ value: Int64, in choices: [Int64]) -> Int64? {
    choices.min { (abs($0-value), $0) < (abs($1-value), $1) }
}

// Input is in event order. A correction never moves an established anchor.
private func resetAnchors(_ events: [UsageEvent], seed: Int64? = nil) -> [Int64: Int64] {
    var anchors = seed.map { [$0] } ?? []
    var mapping: [Int64: Int64] = [:]
    for r in events.compactMap(\.resetMs) where mapping[r] == nil {
        if let a = nearest(r, in: anchors), abs(a-r) <= resetTolerance { mapping[r] = a }
        else { mapping[r] = r; anchors.append(r) }
    }
    return mapping
}

// Each positive key is a fixed reset anchor. Unknown generations use non-positive keys.
private struct Generations {
    var groups: [Int64: [UsageEvent]] = [:]
    init(_ input: [UsageEvent]) {
        let events = input.sorted(by: UsageEvent.ordered)
        let mapping = resetAnchors(events)
        let anchors = Set(mapping.values)
        let resets = Array(mapping.keys)
        var unknown: Int64 = 0, previousDesktop: Double?
        for row in events {
            var key = unknown
            if let r = row.resetMs { key = mapping[r]! }
            else if row.provider == "claude", let r = nearest(row.atMs, in: resets) {
                let end = r + (Int64(floor(Double(row.atMs - r) / Double(weekMs))) + 1) * weekMs
                if let r = nearest(end, in: resets), abs(r-end) <= resetTolerance { key = mapping[r]! }
                else { key = end }
            } else if row.provider == "claude", row.source == "claude-desktop" {
                if let last = previousDesktop, last - row.used >= 20 { unknown -= 1 }
                previousDesktop = row.used
                key = unknown
            } else if row.provider == "codex" {
                let possible = anchors.filter { $0-weekMs <= row.atMs && row.atMs < $0 }
                if possible.count == 1, let only = possible.first { key = only }
            }
            groups[key, default: []].append(row)
        }
    }
}

private struct TrendDay: Codable {
    var date: String
    var used: Double?
    var rough = false
    var reset = false
    enum CodingKeys: CodingKey { case date, used, rough, reset }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(date, forKey: .date); try c.encode(used, forKey: .used)
        try c.encode(rough, forKey: .rough); try c.encode(reset, forKey: .reset)
    }
}
private struct TrendPoint: Codable { let atMs: Int64; let used: Double }
private struct TrendWeek: Codable {
    let startMs: Int64, resetMs: Int64
    let used: Double
    let points: [TrendPoint]
    let endMs: Int64?
    let endUsed: Double?
}
private struct TrendResult: Encodable {
    let week: TrendWeek?
    let days: [TrendDay]
    let averageDays: Int
    let average: Double?
    let best: TrendDay?
    enum CodingKeys: CodingKey { case week, days, averageDays, average, best }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(week, forKey: .week); try c.encode(days, forKey: .days)
        try c.encode(averageDays, forKey: .averageDays); try c.encode(average, forKey: .average)
        try c.encode(best, forKey: .best)
    }
    init(_ rows: [UsageEvent], now: Int64) {
        let calendar = Calendar(identifier: .gregorian)
        let dateFmt = DateFormatter()
        dateFmt.locale = Locale(identifier: "en_US_POSIX"); dateFmt.dateFormat = "yyyy-MM-dd"
        func day(_ ms: Int64) -> String { dateFmt.string(from: instant(ms)) }
        let groups = Generations(rows).groups
        let first = rows.map(\.atMs).min().map(day)
        var days = (0..<28).map { i -> TrendDay in
            let d = dateFmt.string(from: calendar.date(byAdding: .day, value: i-27, to: instant(now))!)
            return TrendDay(date: d, used: first.map { d >= $0 } == true ? 0 : nil)
        }
        let indices = Dictionary(uniqueKeysWithValues: days.indices.map { (days[$0].date, $0) })
        var boundaries: [(key: Int64, end: Int64?, first: Int64)] = []
        for (key, events) in groups {
            let reset = events.compactMap(\.resetMs).last
            boundaries.append((key, reset ?? (key > 0 ? key : nil), events[0].atMs))
            var high = 0.0
            // A suffix maximum per local day confirms only strictly earlier rough samples.
            var confirmed: [String: Double] = [:], rough = Set<Int>()
            for batch in Dictionary(grouping: events.indices, by: { events[$0].atMs }).sorted(by: { $0.key > $1.key }) {
                let d = day(batch.key)
                let observed = batch.value.filter { events[$0].quality == "observed" }.map { events[$0].used }
                for i in batch.value where events[i].quality == "rough" && events[i].used > (confirmed[d] ?? -1) && !observed.contains(events[i].used) {
                    rough.insert(i)
                }
                if let maxObserved = observed.max() { confirmed[d] = max(confirmed[d] ?? 0, maxObserved) }
            }
            for (i, row) in events.enumerated() where row.used > high {
                if let idx = indices[day(row.atMs)] {
                    days[idx].used = (days[idx].used ?? 0) + (row.used-high)
                    if rough.contains(i) { days[idx].rough = true }
                }
                high = row.used
            }
        }
        boundaries.sort { ($0.key > 0 ? $0.key-weekMs : $0.first, $0.key) < ($1.key > 0 ? $1.key-weekMs : $1.first, $1.key) }
        for (old, next) in zip(boundaries, boundaries.dropFirst()) {
            guard let end = next.end else { continue }
            if rows.first?.provider == "claude", let prev = old.end, abs(end-prev-weekMs) > resetTolerance { continue }
            if let i = indices[day(min(old.end ?? end, end-weekMs))] { days[i].reset = true }
        }
        self.days = days
        let recent = days.suffix(7).compactMap(\.used)
        averageDays = recent.count
        average = recent.isEmpty ? nil : recent.reduce(0,+) / Double(recent.count)
        best = days.filter { !$0.rough && ($0.used ?? 0) > 0 }.reduce(nil as TrendDay?) { best, d in
            (best?.used ?? 0) >= d.used! ? best : d
        }
        // Only a measured reset can establish the current week.
        if let b = boundaries.last(where: { groups[$0.key]!.contains { $0.resetMs != nil } }),
           let r = b.end, r > now, r-weekMs <= now {
            let s = r-weekMs
            var points: [TrendPoint] = []
            for e in groups[b.key]! where e.atMs >= s {
                if points.isEmpty || e.used > points.last!.used { points.append(TrendPoint(atMs: e.atMs, used: e.used)) }
            }
            if let u = points.last?.used {
                let projected = now > s ? u * Double(weekMs) / Double(now-s) : nil
                let end = (projected ?? 0) > 100 ? s + Int64(Double(now-s)*100/u) : r
                week = TrendWeek(startMs: s, resetMs: r, used: u, points: points,
                                 endMs: projected == nil ? nil : end, endUsed: projected.map { min(100,$0) })
                return
            }
        }
        week = nil
    }
    static func calculate(_ rows: [UsageEvent], user: UsageAccount, now: Int64) -> [String: Self] {
        let keys = user.keys
        return Dictionary(uniqueKeysWithValues: ["claude","codex"].map { p in
            (p, Self(rows.filter { $0.provider == p && $0.account == keys[p] && $0.minutes == 10080 &&
                $0.atMs <= now && $0.atMs >= now - 35 * dayMs }, now: now))
        })
    }
}

private final class UsageHistory {
    static let url = usageDirectory.appendingPathComponent("history.jsonl")
    private(set) var rows: [UsageEvent] = []
    private var keys = Set<UsageEvent>()
    private var lastCleanup: Int64?
    private var readable = true
    private var retryRows: [UsageEvent] = []
    var visibleRows: [UsageEvent] { rows + retryRows }
    init() { load() }
    private func load() {
        do {
            let data = try Data(contentsOf: Self.url)
            rows = data.split(separator: 10).compactMap { try? JSONDecoder().decode(UsageEvent.self, from: $0) }
                .filter { $0.valid && $0.minutes == 10080 }
            keys = Set(rows.map(\.eventKey))
            readable = true
        } catch let e as NSError { readable = e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoSuchFileError }
    }
    @discardableResult func recordLive(_ events: [UsageEvent], user: UsageAccount, now: Int64) -> Bool {
        let keys = user.keys
        return merge(events.filter { keys[$0.provider] == $0.account }, now: now)
    }
    @discardableResult func merge(_ input: [UsageEvent], now: Int64) -> Bool {
        if !readable { load() }
        let pending = retryRows + input
        if readable && persist(pending, now: now) { retryRows.removeAll(); return true }
        var seen = Set<UsageEvent>()
        retryRows = pending.filter { $0.valid && $0.minutes == 10080 && $0.atMs >= now-35*dayMs && seen.insert($0.eventKey).inserted }
        return false
    }
    private func persist(_ input: [UsageEvent], now: Int64) -> Bool {
        let fresh = input.filter { $0.valid && $0.minutes == 10080 && $0.atMs <= now && $0.atMs >= now-35*dayMs && !keys.contains($0.eventKey) }
        let cleanup = lastCleanup.map { now-$0 >= dayMs } ?? true
        if fresh.isEmpty && !cleanup { return true }
        var added: [UsageEvent] = []
        let old = cleanup ? rows.filter { $0.atMs >= now-35*dayMs } : rows
        for (_, incoming) in Dictionary(grouping: fresh, by: { $0.provider + "/" + $0.account }) {
            let head = incoming[0]
            let existing = old.filter { $0.provider == head.provider && $0.account == head.account }
            for events in Generations(existing + incoming).groups.values {
                var previous: UsageEvent?
                var seen = Set<UsageEvent>()
                for e in events where seen.insert(e.eventKey).inserted {
                    if keys.contains(e.eventKey) { previous = e; continue }
                    if let p = previous, p.used == e.used, (e.resetMs == nil || p.resetMs == e.resetMs),
                       !(p.quality == "rough" && e.quality == "observed") { continue }
                    previous = e; added.append(e)
                }
            }
        }
        if added.isEmpty && !cleanup { return true }
        do {
            try FileManager.default.createDirectory(at: usageDirectory, withIntermediateDirectories: true)
            let list = (cleanup ? old + added : added).sorted(by: UsageEvent.ordered)
            var data = Data()
            for e in list { data.append(try JSONEncoder().encode(e)); data.append(10) }
            if cleanup {
                try writePrivate(data, to: Self.url)
            } else {
                let file = try FileHandle(forWritingTo: Self.url)
                defer { try? file.close() }
                _ = try file.seekToEnd(); try file.write(contentsOf: data)
            }
            rows = old + added; keys = Set(rows.map(\.eventKey))
            if cleanup { lastCleanup = now }
            return true
        } catch { lastCleanup = nil; return false }
    }
}

private struct AlertWindow: Codable, Equatable {
    var anchor: Int64?
    var resetMs: Int64?
    var atMs: Int64
    var low = ""
    var lowAtMs: Int64?
    var pending = false
    var reset: String?
}
private struct AlertNotice: Equatable, Encodable {
    let kind: String, provider: String, account: String, minutes: Int
    let title: String, body: String?
    var model: String? = nil
}

/// 알림 상태 열쇠의 창 부분: 전체 한도는 분 길이(「300」「10080」), 모델별 주간은 「10080/model/<이름 base64url>」(Windows 판과 같다)
private struct AlertScope: Hashable {
    let minutes: Int
    let model: String?
    var suffix: String {
        guard let model else { return String(minutes) }
        let encoded = Data(model.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "\(minutes)/model/\(encoded)"
    }
    static func parse(_ suffix: Substring) -> AlertScope? {
        if let m = Int(suffix), m >= 0, String(m) == suffix { return AlertScope(minutes: m, model: nil) }
        let prefix = "10080/model/"
        guard suffix.hasPrefix(prefix), suffix.count > prefix.count else { return nil }
        var text = String(suffix.dropFirst(prefix.count)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        guard let data = Data(base64Encoded: text), let name = String(data: data, encoding: .utf8) else { return nil }
        let scope = AlertScope(minutes: 10080, model: name)
        return scope.suffix == suffix ? scope : nil
    }
    static func ordered(_ a: Self, _ b: Self) -> Bool {
        if a.minutes != b.minutes { return a.minutes < b.minutes }
        switch (a.model, b.model) {
        case (nil, nil): return false
        case (nil, _): return true
        case (_, nil): return false
        case let (x?, y?): return Array(x.utf16).lexicographicallyPrecedes(Array(y.utf16))
        }
    }
}
private struct AlertFile: Codable, Equatable {
    var v = 1
    var windows: [String: AlertWindow] = [:]
}
private final class LimitAlerts {
    private static let resetNoticeGraceMs: Int64 = 60 * 60_000
    static let url = usageDirectory.appendingPathComponent("alerts.json")
    var state = AlertFile()
    private var cancellations = Set<String>()
    private var cancelModels = false
    var healthy = true
    init() {
        do {
            state = try JSONDecoder().decode(AlertFile.self, from: Data(contentsOf: Self.url))
            healthy = state.v == 1
        } catch let e as NSError { healthy = e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoSuchFileError }
    }
    func save(_ value: AlertFile) -> Bool {
        guard healthy else { return false }
        if value == state { return true }
        do {
            try FileManager.default.createDirectory(at: usageDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(value)
            try writePrivate(data, to: Self.url)
            state = value
            return true
        } catch { return false }
    }
    func cancel(_ provider: String? = nil) {
        if let provider { cancellations.insert(provider) } else { cancellations.formUnion(["claude", "codex"]) }
        _ = applyCancellations()
    }
    /// 「한도 알림」을 끄면 전부, 「모델별 한도도 알림」만 끄면 모델별 한도의 초기화 대기를 지운다(꺼진 동안은 판단하지 않는다)
    func applyPreferences(enabled: Bool, models: Bool) {
        if !enabled { cancel() }
        else if !models { cancelModels = true; _ = applyCancellations() }
    }

    private func applyCancellations() -> Bool {
        guard cancelModels || !cancellations.isEmpty else { return true }
        func isModelKey(_ k: String) -> Bool {
            guard k.hasPrefix("claude/"), let slash = k.dropFirst("claude/".count).firstIndex(of: "/") else { return false }
            return AlertScope.parse(k[k.index(after: slash)...])?.model != nil
        }
        var next = state
        for k in next.windows.keys where next.windows[k]?.pending == true &&
            (cancellations.contains(where: { k.hasPrefix($0 + "/") }) || (cancelModels && isModelKey(k))) {
            next.windows[k]?.pending = false
            next.windows[k]?.reset = "cancelled"
        }
        guard save(next) else { return false }
        cancellations.removeAll()
        cancelModels = false
        return true
    }

    /// 실제 창과 같은 판단: 지금 읽은 원천 값으로. 모델별 한도는 「모델별 한도도 알림」이 켜졌을 때만
    func nextLive(claude: ProviderSnapshot, codex: CodexReader, keys: [String: String], now: Int64,
                  enabled: Bool, models: Bool, skipped: Bool = false) -> (notice: AlertNotice, state: AlertFile)? {
        applyPreferences(enabled: enabled, models: models)
        guard enabled else { return nil }
        return next(UsageEvent.liveRows(claude: claude, codex: codex), keys: keys, now: now, skipped: skipped,
                    modelRows: models ? claude.modelObservations : nil)
    }

    // Return a single transition. Adapters request permission / wait for the balloon, then
    // re-evaluate against the current account and clock before reserving this transition.
    func next(_ rows: [UsageEvent], keys: [String: String], now: Int64, skipped: Bool = false,
              modelRows: [String: UsageEvent]? = nil) -> (notice: AlertNotice, state: AlertFile)? {
        guard healthy, applyCancellations() else { return nil }
        var next = state
        for p in keys.keys.sorted() {
            let account = keys[p]!
            let prefix = p + "/" + account + "/"
            let live = rows.filter { $0.provider == p && $0.account == account && $0.valid && $0.atMs <= now }
            var groups: [AlertScope: [UsageEvent]] = [:]
            for e in live { groups[AlertScope(minutes: e.minutes, model: nil), default: []].append(e) }
            if p == "claude", let modelRows {
                for (name, e) in modelRows where e.valid && e.account == account && e.atMs <= now { groups[AlertScope(minutes: e.minutes, model: name)] = [e] }
            }
            for key in next.windows.keys where key.hasPrefix(prefix) {
                guard let saved = AlertScope.parse(key.dropFirst(prefix.count)),
                      saved.model == nil || (p == "claude" && modelRows != nil), groups[saved] == nil else { continue }
                groups[saved] = []
            }
            for scope in groups.keys.sorted(by: AlertScope.ordered) {
                let m = scope.minutes
                let k = prefix + scope.suffix, duration = Int64(m)*60_000
                let title = Pane(rawValue: p)!.title, label = scope.model ?? windowLabel(minutes: m)
                let window = groups[scope] ?? []
                let resets = window.compactMap(\.resetMs)
                let eligible = window.filter { e in
                    if let reset = e.resetMs { return reset > now }
                    guard now-e.atMs <= duration else { return false }
                    let measured = resets.filter { $0-duration <= e.atMs && e.atMs < $0 }
                    return measured.isEmpty || measured.contains { $0 > now }
                }
                var w = next.windows[k]
                let anchors = resetAnchors(eligible.sorted(by: UsageEvent.ordered), seed: w?.anchor)
                let generation = anchors.values.max()
                let currentRows = eligible.filter { e in
                    if let r = e.resetMs { return anchors[r] == generation }
                    return generation.map { e.atMs >= $0-duration-resetTolerance } ?? true
                }
                let row = currentRows.max(by: UsageEvent.ordered)
                let sourceReset = currentRows.filter { $0.resetMs != nil }.max(by: UsageEvent.ordered)?.resetMs
                let newReset = row?.resetMs ?? sourceReset
                // Older state files only have the last observation time. Freeze it before updating atMs.
                if let old = w, !old.low.isEmpty, old.lowAtMs == nil { w?.lowAtMs = old.atMs }
                if let old = w, old.resetMs == nil, let lowAt = old.lowAtMs, let e = row,
                   e.atMs >= old.atMs && e.atMs - lowAt >= duration {
                    w = nil
                }
                if let e = row, let r = newReset, let old = w, old.anchor == generation,
                   e.atMs >= old.atMs { w?.resetMs = r }
                let newer = w.flatMap { old in newReset.map { r in
                    (row?.atMs ?? 0) >= old.atMs &&
                        (old.anchor.map { (generation ?? r) > $0 } ?? (r-duration > (old.lowAtMs ?? old.atMs)))
                } } ?? false
                if var old = w, old.pending && ((old.resetMs ?? .max) <= now || newer) {
                    let start = newer && duration > 0 ? newReset.map { $0-duration } : nil
                    let boundary = min(old.resetMs ?? .max, start ?? .max)
                    let timely = boundary <= now && boundary >= now - Self.resetNoticeGraceMs
                    old.pending = false
                    old.reset = timely && !skipped ? "sent" : "skipped"
                    next.windows[k] = old
                    if timely {
                        return (AlertNotice(kind: "reset", provider: p, account: account, minutes: m,
                                            title: T("{0} {1} 한도가 초기화됐습니다", title, label), body: T("다시 100% 남았습니다."),
                                            model: scope.model), next)
                    }
                    w = old
                }
                guard let e = row else { continue }
                if let old = w {
                    if e.atMs < old.atMs { continue }
                    if let generation, let anchor = old.anchor, generation < anchor { continue }
                    if newer || (newReset == nil && (old.resetMs ?? .max) <= e.atMs) { w = nil }
                    else if (old.resetMs ?? .max) <= now { continue }
                }
                var current = w ?? AlertWindow(atMs: e.atMs)
                if let r = newReset { current.anchor = current.anchor ?? generation ?? r; current.resetMs = r }
                current.atMs = e.atMs
                // The Claude panel combines the maximum seen in the active measured window.
                let measured = currentRows.filter { $0.resetMs != nil }.map(\.used).max() ?? e.used
                let used = p == "claude" && newReset != nil ? max(e.used, measured) : e.used
                let left = 100-Int(floor(used))
                if left <= 10 && current.low.isEmpty {
                    current.lowAtMs = e.atMs
                    current.low = skipped ? "skipped" : "sent"; current.pending = !skipped
                    current.reset = skipped ? "skipped" : "pending"
                    next.windows[k] = current
                    let body = current.resetMs.map { r -> String in
                        let d = instant(r)
                        let when = Calendar.current.isDate(d, inSameDayAs: instant(now)) ? clock(d) : formatter("M/d(E) HH:mm").string(from: d)
                        return T("{0}에 초기화됩니다.", when)
                    }
                    return (AlertNotice(kind: "low", provider: p, account: account, minutes: m,
                                        title: T("{0} {1} 한도 {2}% 남음", title, label, left), body: body, model: scope.model), next)
                }
                next.windows[k] = current
            }
        }
        _ = save(next)
        return nil
    }
}

private func writePrivate(_ data: Data, to url: URL) throws {
    let temp = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
    let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard fd >= 0 else { throw POSIXError(.EIO) }
    defer { try? FileManager.default.removeItem(at: temp) }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    try file.write(contentsOf: data); try file.synchronize(); try file.close()
    guard rename(temp.path, url.path) == 0 else { throw POSIXError(.EIO) }
}

private func fixtureTime(_ value: Any?) -> Int64? {
    if let s = value as? String { return parseDate(s).map(millis) }
    return (value as? NSNumber)?.int64Value
}

private func requireTestHome(writing names: [String]) throws {
    func canonical(_ path: String) -> String {
        // Resolve existing parents even if the file at the end does not exist yet.
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if FileManager.default.fileExists(atPath: url.path) { return url.resolvingSymlinksInPath().path }
        return (canonical(url.deletingLastPathComponent().path) as NSString).appendingPathComponent(url.lastPathComponent)
    }
    guard let home = ProcessInfo.processInfo.environment["AIUSAGE_HOME"], !home.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {
        throw CocoaError(.fileReadInvalidFileName)
    }
    let root = canonical(home), real = canonical(NSHomeDirectory())
    guard root.caseInsensitiveCompare(real) != .orderedSame else { throw CocoaError(.fileReadInvalidFileName) }
    for name in names {
        let destination = canonical(usageDirectory.appendingPathComponent(name).path)
        guard destination.hasPrefix(root + "/"),
              destination.caseInsensitiveCompare(canonical(real + "/.cache/ai-usage/" + name)) != .orderedSame
        else { throw CocoaError(.fileReadInvalidFileName) }
    }
}

private func recordOnce(now: Int64) throws -> Int {
    try requireTestHome(writing: ["pet.lock", "accounts.json", "claude", "history.jsonl"])
    guard takeSingleInstanceLock(), historyWriter else { throw CocoaError(.fileWriteNoPermission) }
    let date = instant(now), codex = CodexReader()
    let claude = ClaudeReader().read(now: date)
    codex.readLog(now: date)
    let history = UsageHistory()
    let retained = history.rows.filter { $0.atMs >= now - 35 * dayMs }.count
    guard history.recordLive(UsageEvent.liveRows(claude: claude, codex: codex), user: UsageAccount(now: now), now: now)
    else { throw CocoaError(.fileWriteUnknown) }
    return history.rows.count - retained
}

/// 실제 창과 같은 판단으로(지금 원천 값을 읽어) 알림 후보를 낸다 — 보내지 않고 가짜 홈의 alerts.json 에만 남긴다(Windows 판과 같은 출력)
/// --limit-alerts 0|1(기본 1) · --model-alerts 0|1(기본 0)
private func alertsOnce(_ args: [String], now: Int64) throws -> String {
    try requireTestHome(writing: ["pet.lock", "accounts.json", "claude", "alerts.json"])
    guard takeSingleInstanceLock(), historyWriter else { throw CocoaError(.fileWriteNoPermission) }
    func option(_ name: String, _ fallback: Bool) throws -> Bool {
        guard let i = args.firstIndex(of: name) else { return fallback }
        guard args.indices.contains(i + 1), ["0", "1"].contains(args[i + 1]) else { throw CocoaError(.coderInvalidValue) }
        return args[i + 1] == "1"
    }
    let enabled = try option("--limit-alerts", true), models = try option("--model-alerts", false)
    let date = instant(now), codex = CodexReader()
    let claude = ClaudeReader().read(now: date)
    codex.readLog(now: date)
    let alerts = LimitAlerts()
    var notices: [[String: Any]] = []
    while let c = alerts.nextLive(claude: claude, codex: codex, keys: UsageAccount(now: now).keys, now: now, enabled: enabled, models: models) {
        guard alerts.save(c.state) else { throw CocoaError(.fileWriteUnknown) }
        let n = c.notice
        notices.append(["kind": n.kind, "provider": n.provider, "minutes": n.minutes, "scope": n.model == nil ? "overall" : "model",
                        "model": n.model as Any? ?? NSNull(), "title": n.title, "body": n.body as Any? ?? NSNull()])
    }
    guard alerts.healthy else { throw CocoaError(.fileWriteUnknown) }
    return String(decoding: try JSONSerialization.data(withJSONObject: notices, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
}

private func testAlerts(_ path: String) throws {
    try requireTestHome(writing: ["alerts.json"])
    guard let steps = readJSONObject(path)?["steps"] as? [[String: Any]] else { throw CocoaError(.fileReadInvalidFileName) }
    let alerts = LimitAlerts()
    var events: [[String: Any]] = [], candidates: [[String: Any]] = []
    var keys: [String: String] = [:], hidden = Set<String>()
    func report(_ n: AlertNotice, _ outcome: String) -> [String: Any] {
        ["kind": n.kind, "title": n.title, "body": n.body as Any, "result": outcome]
    }
    var enabled = true, requests = 0, permission: Bool?
    for s in steps {
        guard let now = fixtureTime(s["now"]) else { throw CocoaError(.coderInvalidValue) }
        let p = s["provider"] as? String ?? "codex"
        if let id = s["account"] as? String { keys[p] = UsageAccount.hash(p,id) }
        else if keys[p] == nil { keys[p] = UsageAccount.hash(p,"test") }
        for (provider, id) in s["accounts"] as? [String: String] ?? [:] { keys[provider] = UsageAccount.hash(provider, id) }
        if let on = s["enabled"] as? Bool { enabled = on; if !on { alerts.cancel() } }
        if let hide = s["hidden"] as? Bool {
            if hide { hidden.insert(p); alerts.cancel(p) } else { hidden.remove(p) }
        }
        var rows: [UsageEvent] = []
        for o in s["observations"] as? [[String: Any]] ?? [s] {
            guard let used = number(o["used"]) else { continue }
            let provider = o["provider"] as? String ?? p
            if keys[provider] == nil, provider != p { keys[provider] = UsageAccount.hash(provider, o["account"] as? String ?? "test") }
            let id = (o["account"] as? String).flatMap { UsageAccount.hash(provider,$0) } ?? keys[provider]
            guard let id else { continue }
            rows.append(UsageEvent(provider: provider, account: id, minutes: o["minutes"] as? Int ?? 10080,
                                   atMs: fixtureTime(o["atMs"]) ?? now, resetMs: fixtureTime(o["resetMs"]),
                                   used: used, source: "codex-server", quality: "observed", slot: o["slot"] as? String))
        }
        guard enabled else { continue }
        let active = keys.filter { !hidden.contains($0.key) }
        let outcome = s["outcome"] as? String ?? "sent"
        guard let first = alerts.next(rows, keys: active, now: now) else { continue }
        if permission == nil { requests += 1; permission = outcome != "denied" }
        if outcome == "hideWhileWaiting" || outcome == "switchWhileWaiting" {
            candidates.append(report(first.notice, outcome))
            if outcome == "hideWhileWaiting" { hidden.insert(p); alerts.cancel(p) }
            else { keys[p] = UsageAccount.hash(p,"switched") }
            continue
        }
        while let candidate = alerts.next(rows, keys: active, now: now, skipped: permission == false) {
            let before = alerts.state
            guard outcome != "saveFailure", alerts.save(candidate.state) else {
                candidates.append(report(candidate.notice, "saveFailure")); break
            }
            let event = report(candidate.notice, permission == false ? "skipped" : outcome)
            candidates.append(event); events.append(event)
            if outcome == "failed" { _ = alerts.save(before); break }
            if outcome == "unknown" { break }
        }
    }
    let data = try JSONSerialization.data(withJSONObject: ["events":events,"candidates":candidates,"permissionRequests":requests], options:.sortedKeys)
    print(String(decoding:data, as:UTF8.self))
}

private final class TrendModel: ObservableObject {
    @Published var results: [String: TrendResult] = [:]
    @Published var month = false
    var now = millis(Date())
}
private func roundedPercent(_ n: Double) -> Int { Int(floor(n + 0.5)) }
private struct TrendScreen: View {
    @ObservedObject var data: TrendModel
    @ObservedObject var model: UsageModel
    private func tab(_ label: String, month: Bool) -> some View {
        Button { data.month = month } label: {
            Text(label).font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 4)
                .background(.white.opacity(data.month == month ? 0.16 : 0), in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(data.month == month ? .isSelected : [])
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 0) {
                tab(T("이번 주"), month: false)
                tab(T("지난 4주"), month: true)
            }.padding(2).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
            ForEach(model.order.filter { ($0 == .claude && model.showClaude) || ($0 == .codex && model.showCodex) }, id: \.rawValue) { pane in
                if let r = data.results[pane.rawValue] {
                    Divider()
                    TrendCard(pane: pane, result: r, now: data.now, month: data.month)
                }
            }
            Spacer(minLength: 0)
        }.padding(18).frame(maxWidth:.infinity, maxHeight:.infinity, alignment:.topLeading)
            .background(Color(red:0.137, green:0.137, blue:0.149)).environment(\.colorScheme, .dark)
    }
}

private struct TrendCard: View {
    let pane: Pane, result: TrendResult, now: Int64, month: Bool
    var tint: Color { pane == .claude ? claudeTint : codexTint }
    func date(_ key: String) -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier:"en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from:key) ?? instant(now)
    }
    var summary: String {
        if month {
            guard let average = result.average else { return "" }
            return T("최근 {0}일 하루 평균 {1}%", result.averageDays, roundedPercent(average))
        }
        guard let w = result.week else { return "" }
        return T("{0}% 씀 · ↺ {1}", roundedPercent(w.used), formatter("M/d(E) HH:mm").string(from: instant(w.resetMs)))
    }
    var footer: String {
        if month {
            guard let b = result.best, let used = b.used else { return "" }
            return T("가장 많이 쓴 날 {0} {1}%", formatter("M/d(E)").string(from: date(b.date)), roundedPercent(used))
        }
        guard let w = result.week else { return T("아직 이번 주 기록이 없습니다") }
        guard let end = w.endMs, let projected = w.endUsed else { return "" }
        if end < w.resetMs {
            return T("이 속도면 {0} {1}시쯤 다 씁니다 — 초기화 {2}시간 전", formatter("M/d(E)").string(from: instant(end)),
                     formatter("H").string(from: instant(end)), roundedPercent(Double(w.resetMs-end)/3600000))
        }
        return T("이 속도면 초기화 때 약 {0}% 씁니다 — 넉넉합니다", roundedPercent(projected))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Circle().fill(tint).frame(width:8,height:8)
                Text(pane.title).fontWeight(.semibold)
                Text(month ? T("하루에 쓴 주간 한도") : T("주간 한도")).foregroundStyle(.secondary)
                Spacer()
                Text(summary).monospacedDigit().foregroundStyle(.secondary)
            }.font(.system(size:13))
            Canvas { ctx, size in draw(ctx, size) }.frame(height:125)
            Text(footer).font(.system(size:12))
                .foregroundStyle(!month && (result.week?.endMs ?? .max) < (result.week?.resetMs ?? 0) ? Color.orange : Color.secondary)
        }
    }
    func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let left = 36.0, right = size.width-8, top = 13.0, bottom = size.height-20
        let grid = Color.white.opacity(0.13)
        func line(_ a: CGPoint, _ b: CGPoint, _ color: Color, _ width: Double = 1, _ dash: [CGFloat] = []) {
            var p = Path(); p.move(to:a); p.addLine(to:b)
            ctx.stroke(p, with:.color(color), style:StrokeStyle(lineWidth:width,dash:dash))
        }
        func label(_ s: String, _ x: Double, _ y: Double, _ anchor: UnitPoint = .center) {
            ctx.draw(Text(verbatim:s).font(.system(size:10)).foregroundColor(.secondary), at:CGPoint(x:x,y:y),anchor:anchor)
        }
        let scale = month ? max(60,ceil((result.days.compactMap(\.used).max() ?? 0)/30)*30) : 100
        func y(_ v: Double) -> Double { bottom - (bottom-top)*v/scale }
        for v in stride(from:0.0, through:scale, by:month ? 30 : 50) {
            line(CGPoint(x:left,y:y(v)),CGPoint(x:right,y:y(v)),grid)
            label("\(Int(v))%",left-5,y(v),.trailing)
        }
        if month {
            let cw = (right-left)/28
            let missing = result.days.prefix { $0.used == nil }.count
            if missing > 0 {
                ctx.fill(Path(CGRect(x:left,y:top,width:Double(missing)*cw,height:bottom-top)),with:.color(.white.opacity(0.04)))
                label(T("기록 없음"),left+Double(missing)*cw/2,y(scale/2))
            }
            for (i,d) in result.days.enumerated() {
                let x = left + Double(i)*cw, day = date(d.date)
                if Calendar.current.component(.weekday, from:day) == 2 { label(formatter("M/d").string(from:day),x+cw/2,bottom+11) }
                if d.reset { line(CGPoint(x:x,y:top),CGPoint(x:x,y:bottom),.secondary,1,[2,3]); label("↺",x+4,top-5) }
                if let u = d.used, u > 0 {
                    ctx.fill(Path(roundedRect: CGRect(x:x+2,y:y(u),width:max(1,cw-4),height:bottom-y(u)),cornerRadius:2),
                             with:.color(tint.opacity(d.rough ? 0.35 : 0.9)))
                    if d.date == result.best?.date { label("\(roundedPercent(u))%",x+cw/2,y(u)-7) }
                }
            }
            return
        }
        guard let w = result.week else { return }
        func pt(_ t: Int64, _ v: Double) -> CGPoint { CGPoint(x:left+(right-left)*Double(t-w.startMs)/Double(weekMs),y:y(v)) }
        let cal = Calendar.current
        var d = cal.startOfDay(for: instant(w.startMs))
        while let next = cal.date(byAdding:.day,value:1,to:d), millis(next) < w.resetMs {
            d = next; let t = millis(d)
            line(pt(t,0),pt(t,100),grid)
            let middle = t + dayMs/2
            if middle < w.resetMs { label(formatter("E").string(from:d),pt(middle,0).x,bottom+11) }
        }
        line(pt(w.startMs,0),pt(w.resetMs,100),.secondary,1,[3,4])
        if let end = w.endMs, let u = w.endUsed {
            let tip = pt(end,u)
            line(pt(now,w.used),tip,tint.opacity(0.5),1.5,[2,3])
            if end < w.resetMs { ctx.fill(Path(ellipseIn:CGRect(x:tip.x-3,y:tip.y-3,width:6,height:6)),with:.color(.orange)) }
        }
        guard let first = w.points.first else { return }
        var path = Path(); path.move(to:pt(first.atMs,first.used))
        var last = first.used
        for p in w.points.dropFirst() { path.addLine(to:pt(p.atMs,last)); path.addLine(to:pt(p.atMs,p.used)); last = p.used }
        let current = pt(now,w.used)
        path.addLine(to:current)
        var area = path; area.addLine(to:pt(now,0)); area.addLine(to:pt(first.atMs,0)); area.closeSubpath()
        ctx.fill(area,with:.color(tint.opacity(0.16))); ctx.stroke(path,with:.color(tint),lineWidth:2)
        ctx.fill(Path(ellipseIn:CGRect(x:current.x-3,y:current.y-3,width:6,height:6)),with:.color(tint))
        label(T("지금"),min(current.x+6,right-24),current.y-7,.leading)
    }
}
@MainActor private func trendPNG(_ result: [String:TrendResult], now: Int64, month: Bool, path: String) throws {
    _ = NSApplication.shared
    let data = TrendModel(); data.results = result; data.now = now; data.month = month
    let content = TrendScreen(data:data,model:UsageModel()).frame(width:630,height:490)
    let renderer = ImageRenderer(content:content); renderer.scale = 2
    guard let cg = renderer.cgImage, let png = NSBitmapImageRep(cgImage:cg).representation(using:.png,properties:[:])
    else { throw CocoaError(.fileWriteUnknown) }
    try png.write(to:URL(fileURLWithPath:path))
}
