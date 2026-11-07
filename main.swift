// usage-tracker: Claude Code plan limits and token totals in the menu bar.
import AppKit

enum Config {
  static let refreshSeconds = 30.0
  static let weekSeconds = 7.0 * 86_400
  static let directory = URL(
    fileURLWithPath: ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
      ?? NSHomeDirectory() + "/.claude")
  static let limitsFile = directory
    .appendingPathComponent("usage-tracker/rate-limits.json")
  static let projects = directory.appendingPathComponent("projects")
}

// MARK: - Plan limits

struct LimitWindow: Codable, Equatable {
  var usedPercentage: Double
  var resetsAt: Double
}

struct Limits: Codable, Equatable {
  var fiveHour: LimitWindow?
  var sevenDay: LimitWindow?
  var savedAt: Double?
}

private struct StatusInput: Decodable {
  var rateLimits: Limits?
}

private enum Coding {
  static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
  }()
  static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    return encoder
  }()
}

/// Picks the current reading for one window.
///
/// Limits are account-wide but every session reports its own last reading, so
/// an idle session that redraws would otherwise move the number backwards.
func mergeWindow(_ stored: LimitWindow?, _ new: LimitWindow?) -> LimitWindow? {
  guard let new else { return stored }
  guard let stored else { return new }
  if new.resetsAt != stored.resetsAt {
    return new.resetsAt > stored.resetsAt ? new : stored
  }
  return new.usedPercentage > stored.usedPercentage ? new : stored
}

func loadLimits(_ file: URL) -> Limits? {
  guard let data = try? Data(contentsOf: file) else { return nil }
  return try? Coding.decoder.decode(Limits.self, from: data)
}

/// Merges any rate limits in status line JSON into the limits file.
///
/// Writes only when a value changes, so `savedAt` means "last changed" and a
/// redraw of old data can't make it look fresh.
///
/// ponytail: two sessions can race on read-merge-write and lose one update.
/// The next status line event repairs it, so no file lock.
func saveLimits(statusJSON: Data, to file: URL, now: Date) {
  guard
    let incoming = try? Coding.decoder
      .decode(StatusInput.self, from: statusJSON).rateLimits,
    incoming.fiveHour != nil || incoming.sevenDay != nil
  else { return }
  let stored = loadLimits(file)
  var merged = Limits(
    fiveHour: mergeWindow(stored?.fiveHour, incoming.fiveHour),
    sevenDay: mergeWindow(stored?.sevenDay, incoming.sevenDay),
    savedAt: stored?.savedAt)
  guard merged != stored else { return }
  merged.savedAt = now.timeIntervalSince1970
  guard let data = try? Coding.encoder.encode(merged) else { return }
  try? FileManager.default.createDirectory(
    at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
  try? data.write(to: file, options: .atomic)
}

/// Copies stdin to stdout, then records rate limits from it. Output comes
/// first so a failed save can't blank the status line downstream.
func passThroughStatusLine() {
  signal(SIGPIPE, SIG_IGN)
  let input = FileHandle.standardInput.readDataToEndOfFile()
  try? FileHandle.standardOutput.write(contentsOf: input)
  try? FileHandle.standardOutput.close()
  saveLimits(statusJSON: input, to: Config.limitsFile, now: Date())
}

// MARK: - Token totals

struct TokenTotals: Equatable {
  var total = 0
  var output = 0
}

struct TokenSnapshot {
  var today: TokenTotals
  var week: TokenTotals
}

/// Running token counts from transcripts, read incrementally by byte offset.
final class TokenLedger {
  private struct Entry {
    var at: Date
    var total: Int
    var output: Int
  }

  private static let newline = UInt8(ascii: "\n")
  private static let usageKey = Data(#""usage""#.utf8)
  private var offsets: [String: Int] = [:]
  private var entries: [String: Entry] = [:]
  private let dates: ISO8601DateFormatter = {
    let dates = ISO8601DateFormatter()
    dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return dates
  }()

  func scan(projects: URL, now: Date) {
    let cutoff = now.addingTimeInterval(-Config.weekSeconds)
    let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
    guard
      let files = FileManager.default.enumerator(
        at: projects, includingPropertiesForKeys: keys)
    else { return }
    for case let file as URL in files where file.pathExtension == "jsonl" {
      guard let values = try? file.resourceValues(forKeys: Set(keys)),
        let modified = values.contentModificationDate, modified >= cutoff,
        let size = values.fileSize, size != offsets[file.path]
      else { continue }
      autoreleasepool { read(file, size: size, cutoff: cutoff) }
    }
    entries = entries.filter { $0.value.at >= cutoff }
  }

  func snapshot(now: Date, calendar: Calendar) -> TokenSnapshot {
    TokenSnapshot(
      today: totals(since: calendar.startOfDay(for: now)),
      week: totals(since: now.addingTimeInterval(-Config.weekSeconds)))
  }

  private func totals(since start: Date) -> TokenTotals {
    entries.values.reduce(into: TokenTotals()) { sum, entry in
      guard entry.at >= start else { return }
      sum.total += entry.total
      sum.output += entry.output
    }
  }

  /// Reads complete new lines. A partial last line waits for the next scan.
  private func read(_ file: URL, size: Int, cutoff: Date) {
    var offset = offsets[file.path] ?? 0
    if size < offset { offset = 0 }
    guard let handle = try? FileHandle(forReadingFrom: file) else { return }
    defer { try? handle.close() }
    guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
      let data = try? handle.readToEnd(),
      let lastNewline = data.lastIndex(of: Self.newline)
    else { return }
    for line in data[...lastNewline].split(separator: Self.newline)
    where line.range(of: Self.usageKey) != nil {
      record(line, cutoff: cutoff)
    }
    offsets[file.path] = offset + lastNewline + 1
  }

  /// Keys by message id because one message spans several transcript lines,
  /// and resumed sessions can repeat messages across files.
  private func record(_ line: Data, cutoff: Date) {
    guard
      let row = try? JSONSerialization.jsonObject(with: line)
        as? [String: Any],
      row["type"] as? String == "assistant",
      let message = row["message"] as? [String: Any],
      let id = message["id"] as? String,
      let usage = message["usage"] as? [String: Any],
      let stamp = row["timestamp"] as? String,
      let at = dates.date(from: stamp), at >= cutoff
    else { return }
    func count(_ key: String) -> Int { usage[key] as? Int ?? 0 }
    let output = count("output_tokens")
    entries[id] = Entry(
      at: min(at, entries[id]?.at ?? at),
      total: count("input_tokens") + output
        + count("cache_creation_input_tokens")
        + count("cache_read_input_tokens"),
      output: output)
  }
}

// MARK: - Display text

/// The percentage to show, or nil without data. A window past its reset shows
/// 0 because nothing newer has been reported since it rolled over.
func shownPercent(_ window: LimitWindow?, now: Date) -> Int? {
  guard let window else { return nil }
  if window.resetsAt <= now.timeIntervalSince1970 { return 0 }
  return Int(window.usedPercentage.rounded())
}

/// The title, with the time left in each window. Time rounds up so a fresh
/// window reads 5h or 7d, and a live one never reads 0.
func menuTitle(_ limits: Limits?, now: Date) -> String {
  func text(_ window: LimitWindow?, unit: Double, suffix: String) -> String {
    guard let window, let percent = shownPercent(window, now: now) else {
      return "–"
    }
    let left = (window.resetsAt - now.timeIntervalSince1970) / unit
    return "\(percent)% \(Int(max(left, 0).rounded(.up)))\(suffix)"
  }
  let hours = text(limits?.fiveHour, unit: 3_600, suffix: "h")
  let days = text(limits?.sevenDay, unit: 86_400, suffix: "d")
  return "S: \(hours) · W: \(days)"
}

/// Hue for a percentage: green at 0, through yellow, to red at 100. Moving
/// through hue keeps the middle bright, where blending RGB turns it brown.
func percentHue(_ percent: Int) -> CGFloat {
  CGFloat(100 - min(max(percent, 0), 100)) / 300
}

/// Darker on a light menu bar, where bright yellow and green would wash out.
private func percentColor(_ percent: Int) -> NSColor {
  NSColor(name: nil) { appearance in
    let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    return NSColor(
      hue: percentHue(percent), saturation: 0.9,
      brightness: isDark ? 1 : 0.65, alpha: 1)
  }
}

/// Styles menu text, coloring each percentage by its value.
func styled(_ text: String, font: NSFont) -> NSAttributedString {
  let result = NSMutableAttributedString(
    string: text,
    attributes: [.foregroundColor: NSColor.labelColor, .font: font])
  for match in text.matches(of: #/(\d+)%/#) {
    guard let percent = Int(match.1) else { continue }
    result.addAttribute(
      .foregroundColor, value: percentColor(percent),
      range: NSRange(match.range, in: text))
  }
  return result
}

func formatTokens(_ count: Int) -> String {
  let value = Double(count)
  switch value {
  case ..<999.5: return "\(count)"
  case ..<999_500: return "\(Int((value / 1e3).rounded()))K"
  case ..<99_950_000: return String(format: "%.1fM", value / 1e6)
  case ..<999_500_000: return "\(Int((value / 1e6).rounded()))M"
  default: return String(format: "%.1fB", value / 1e9)
  }
}

func durationText(_ seconds: TimeInterval) -> String {
  let formatter = DateComponentsFormatter()
  formatter.allowedUnits = [.day, .hour, .minute]
  formatter.unitsStyle = .abbreviated
  formatter.maximumUnitCount = 2
  return formatter.string(from: seconds) ?? ""
}

func updatedRow(_ savedAt: Double?, now: Date) -> String {
  guard let savedAt else {
    return "No limit data yet. It appears after the next Claude Code response."
  }
  let age = now.timeIntervalSince1970 - savedAt
  return age < 60 ? "Updated just now" : "Updated \(durationText(age)) ago"
}

private func clockText(_ date: Date, now: Date) -> String {
  Calendar.current.isDate(date, inSameDayAs: now)
    ? date.formatted(date: .omitted, time: .shortened)
    : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
}

private func limitRow(
  _ name: String, _ window: LimitWindow?, now: Date
) -> String {
  guard let window, let percent = shownPercent(window, now: now) else {
    return "\(name)  –"
  }
  let reset = Date(timeIntervalSince1970: window.resetsAt)
  let clock = clockText(reset, now: now)
  guard reset > now else { return "\(name)  \(percent)%   reset \(clock)" }
  let wait = durationText(reset.timeIntervalSince(now))
  return "\(name)  \(percent)%   resets \(clock) (in \(wait))"
}

private func tokenRow(_ name: String, _ totals: TokenTotals?) -> String {
  guard let totals else { return "\(name)  counting…" }
  let total = formatTokens(totals.total)
  return "\(name)  \(total) tokens (\(formatTokens(totals.output)) output)"
}

func menuSections(
  limits: Limits?, tokens: TokenSnapshot?, now: Date
) -> [[String]] {
  [
    [
      limitRow("5-hour", limits?.fiveHour, now: now),
      limitRow("7-day", limits?.sevenDay, now: now),
      updatedRow(limits?.savedAt, now: now),
    ],
    [tokenRow("Today", tokens?.today), tokenRow("7 days", tokens?.week)],
  ]
}

/// Prints what the menu would show, for checking without the UI.
func printSummary() {
  let now = Date()
  let ledger = TokenLedger()
  ledger.scan(projects: Config.projects, now: now)
  let limits = loadLimits(Config.limitsFile)
  print(menuTitle(limits, now: now))
  let tokens = ledger.snapshot(now: now, calendar: .current)
  for row in menuSections(limits: limits, tokens: tokens, now: now).joined() {
    print(row)
  }
}

// MARK: - Menu bar

final class MenuBarApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private let statusItem = NSStatusBar.system
    .statusItem(withLength: NSStatusItem.variableLength)
  private let menu = NSMenu()
  private let ledger = TokenLedger()
  private let scanQueue = DispatchQueue(
    label: "usage-tracker.scan", qos: .utility)
  private var tokens: TokenSnapshot?
  private var isScanning = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    menu.delegate = self
    statusItem.menu = menu
    refresh()
    let timer = Timer(
      timeInterval: Config.refreshSeconds, repeats: true
    ) { [weak self] _ in self?.refresh() }
    timer.tolerance = 5
    RunLoop.main.add(timer, forMode: .common)
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    refresh()
    menu.removeAllItems()
    let sections = menuSections(
      limits: loadLimits(Config.limitsFile), tokens: tokens, now: Date())
    for section in sections {
      section.forEach { menu.addItem(infoItem($0)) }
      menu.addItem(.separator())
    }
    let quit = NSMenuItem(
      title: "Quit", action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q")
    quit.target = NSApp
    menu.addItem(quit)
  }

  /// A row with no action, styled so disabling it doesn't gray out the text.
  private func infoItem(_ text: String) -> NSMenuItem {
    let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
    item.attributedTitle = styled(text, font: .menuFont(ofSize: 0))
    return item
  }

  private func refresh() {
    updateTitle()
    guard !isScanning else { return }
    isScanning = true
    scanQueue.async { [ledger] in
      let now = Date()
      ledger.scan(projects: Config.projects, now: now)
      let snapshot = ledger.snapshot(now: now, calendar: .current)
      DispatchQueue.main.async {
        self.tokens = snapshot
        self.isScanning = false
      }
    }
  }

  private func updateTitle() {
    let title = menuTitle(loadLimits(Config.limitsFile), now: Date())
    statusItem.button?.attributedTitle = styled(
      title, font: .menuBarFont(ofSize: 0))
  }
}

// MARK: - Entry point

switch CommandLine.arguments.dropFirst().first {
case nil:
  let app = NSApplication.shared
  let delegate = MenuBarApp()
  app.delegate = delegate
  app.setActivationPolicy(.accessory)
  // The app holds its delegate weakly, so keep it alive for the whole run.
  withExtendedLifetime(delegate) { app.run() }
case "--statusline":
  passThroughStatusLine()
case "--print":
  printSummary()
case "--self-check":
  try selfCheck()
default:
  print("usage: usage-tracker [--statusline | --print | --self-check]")
  exit(2)
}
