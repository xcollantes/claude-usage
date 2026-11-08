// Assertion checks for usage-tracker, run with --self-check.
import AppKit

final class Checks {
  private(set) var failed = 0

  func expect(_ passed: Bool, _ what: String, line: Int = #line) {
    guard !passed else { return }
    failed += 1
    print("FAIL main.swift:\(line): \(what)")
  }
}

func checkMerge(_ c: Checks) {
  let stored = LimitWindow(usedPercentage: 40, resetsAt: 1_000)
  let higher = LimitWindow(usedPercentage: 55, resetsAt: 1_000)
  let lower = LimitWindow(usedPercentage: 12, resetsAt: 1_000)
  let later = LimitWindow(usedPercentage: 3, resetsAt: 2_000)
  let earlier = LimitWindow(usedPercentage: 99, resetsAt: 500)
  c.expect(mergeWindow(stored, nil) == stored, "absent keeps stored")
  c.expect(mergeWindow(nil, stored) == stored, "first reading is stored")
  c.expect(mergeWindow(stored, later) == later, "later reset replaces")
  c.expect(mergeWindow(stored, earlier) == stored, "earlier reset ignored")
  c.expect(mergeWindow(stored, higher) == higher, "same reset keeps higher")
  c.expect(mergeWindow(stored, lower) == stored, "same reset ignores lower")
}

func checkSaving(_ c: Checks, dir: URL) {
  let file = dir.appendingPathComponent("limits/rate-limits.json")
  func save(_ json: String, at seconds: Double) {
    saveLimits(
      statusJSON: Data(json.utf8), to: file,
      now: Date(timeIntervalSince1970: seconds))
  }
  let fiveHour = #""five_hour":{"used_percentage":23.5,"resets_at":9000}"#
  let sevenDay = #""seven_day":{"used_percentage":41,"resets_at":99000}"#

  save("not json", at: 1)
  save(#"{"model":{"id":"x"}}"#, at: 1)
  save(#"{"rate_limits":{}}"#, at: 1)
  c.expect(loadLimits(file) == nil, "no limits means no file")

  save("{\"rate_limits\":{\(fiveHour)},\"extra\":1}", at: 100)
  c.expect(loadLimits(file)?.fiveHour?.usedPercentage == 23.5, "saves window")
  c.expect(loadLimits(file)?.sevenDay == nil, "absent window stays absent")
  c.expect(loadLimits(file)?.savedAt == 100, "stamps the save")

  save("{\"rate_limits\":{\(sevenDay)}}", at: 200)
  c.expect(loadLimits(file)?.fiveHour != nil, "keeps the other window")
  c.expect(loadLimits(file)?.sevenDay?.resetsAt == 99000, "adds new window")
  c.expect(loadLimits(file)?.savedAt == 200, "a change moves the stamp")

  save("{\"rate_limits\":{\(fiveHour)}}", at: 300)
  c.expect(loadLimits(file)?.savedAt == 200, "a repeat keeps the stamp")
}

func checkLedger(_ c: Checks, dir: URL) throws {
  let dates = ISO8601DateFormatter()
  let now = dates.date(from: "2026-11-07T07:53:00Z")!
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
  let projects = dir.appendingPathComponent("projects")
  let session = projects.appendingPathComponent("p/s.jsonl")
  let subagent = projects.appendingPathComponent("p/s/subagents/a.jsonl")
  try FileManager.default.createDirectory(
    at: subagent.deletingLastPathComponent(),
    withIntermediateDirectories: true)

  func line(_ id: String, _ at: String, output: Int) -> String {
    """
    {"type":"assistant","timestamp":"\(at).000Z","message":{"id":"\(id)",\
    "usage":{"input_tokens":1,"cache_creation_input_tokens":10,\
    "cache_read_input_tokens":100,"output_tokens":\(output)}}}
    """
  }
  let afterMidnight = "2026-11-06T08:30:00"  // 00:30 PST
  let beforeMidnight = "2026-11-06T07:30:00"  // 23:30 PST the day before
  let rows = [
    line("a", afterMidnight, output: 1),
    line("a", afterMidnight, output: 5),  // Same message: last write wins.
    line("b", beforeMidnight, output: 1000),
    line("stale", "2026-10-30T00:00:00", output: 7),  // Over 7 days old.
    #"{"type":"user","message":{"id":"u","usage":{"output_tokens":9}}}"#,
    #"{"type":"assistant","usage": not json"#,
  ]
  let partial = line("c", afterMidnight, output: 20)
  let split = partial.index(partial.startIndex, offsetBy: 40)
  try (rows.joined(separator: "\n") + "\n" + partial[..<split])
    .write(to: session, atomically: true, encoding: .utf8)

  let ledger = TokenLedger()
  func snapshot() -> TokenSnapshot {
    ledger.scan(projects: projects, now: now)
    return ledger.snapshot(now: now, calendar: calendar)
  }
  var seen = snapshot()
  c.expect(
    seen.today == TokenTotals(total: 116, output: 5),
    "local midnight splits today, dedupes, skips other lines: \(seen.today)")
  c.expect(
    seen.week == TokenTotals(total: 1227, output: 1005),
    "week adds the earlier message: \(seen.week)")

  let handle = try FileHandle(forWritingTo: session)
  try handle.seekToEnd()
  try handle.write(contentsOf: Data((partial[split...] + "\n").utf8))
  try handle.close()
  seen = snapshot()
  c.expect(seen.today.output == 25, "completes a partial line once")
  seen = snapshot()
  c.expect(seen.today.output == 25, "rescan does not double count")

  try (line("d", afterMidnight, output: 100) + "\n")
    .write(to: subagent, atomically: true, encoding: .utf8)
  c.expect(snapshot().today.output == 125, "counts subagent transcripts")

  try (line("e", afterMidnight, output: 1000) + "\n")
    .write(to: session, atomically: true, encoding: .utf8)
  c.expect(snapshot().today.output == 1125, "rereads a file that shrank")

  try (line("f", afterMidnight, output: 5000) + "\n")
    .write(to: subagent, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes(
    [.modificationDate: now.addingTimeInterval(-8 * 86_400)],
    ofItemAtPath: subagent.path)
  c.expect(snapshot().today.output == 1125, "skips files untouched for 7 days")
}

func checkText(_ c: Checks) {
  let now = Date(timeIntervalSince1970: 1_000)
  func window(_ percent: Double, resets: Double = 2_000) -> LimitWindow {
    LimitWindow(usedPercentage: percent, resetsAt: resets)
  }
  let expired = window(88, resets: 1_000)

  c.expect(menuTitle(nil, now: now) == "S: – · W: –", "no data")
  c.expect(
    menuTitle(Limits(fiveHour: window(23.4), sevenDay: expired), now: now)
      == "S: 23% 1h · W: 0% 0d",
    "rounds live windows and zeroes expired ones")
  c.expect(
    menuTitle(
      Limits(
        fiveHour: window(0, resets: 1_000 + 5 * 3_600),
        sevenDay: window(0, resets: 1_000 + 7 * 86_400)), now: now)
      == "S: 0% 5h · W: 0% 7d",
    "a fresh window shows its full length")
  c.expect(
    menuTitle(
      Limits(
        fiveHour: window(8, resets: 1_000 + 4 * 3_600 + 26 * 60),
        sevenDay: window(30, resets: 1_000 + 3 * 86_400 + 21 * 3_600)),
      now: now)
      == "S: 8% 5h · W: 30% 4d",
    "time left rounds up")
  let live = Limits(fiveHour: window(23.4), sevenDay: window(41))
  let layouts: [(TitleLayout, String)] = [
    (.short, "S: 23% 1h · W: 41% 1d"),
    (.long, "Session: 23% 1h · Weekly: 41% 1d"),
    (.percents, "S: 23% · W: 41%"),
    (.bare, "23% · 41%"),
  ]
  for (layout, text) in layouts {
    let shown = menuTitle(live, now: now, layout: layout)
    c.expect(shown == text, "\(layout) layout: \(shown)")
  }
  c.expect(
    menuTitle(nil, now: now, layout: .long) == "Session: – · Weekly: –",
    "long layout without data")
  let samples = Set(
    TitleLayout.allCases.map {
      menuTitle(sampleLimits(now: now), now: now, layout: $0)
    })
  c.expect(samples.count == TitleLayout.allCases.count, "previews differ")

  c.expect(percentHue(0) == 1.0 / 3, "0% is green")
  c.expect(percentHue(50) == 1.0 / 6, "50% is yellow")
  c.expect(percentHue(100) == 0, "100% is red")
  c.expect(percentHue(140) == 0, "over 100% stays red")

  let title = "S: 50% 5h · W: –"
  let shown = styled(title, font: .menuBarFont(ofSize: 0))
  func color(_ text: String) -> NSColor? {
    let start = NSRange(title.range(of: text)!, in: title).location
    return shown.attribute(.foregroundColor, at: start, effectiveRange: nil)
      as? NSColor
  }
  c.expect(shown.string == title, "styling keeps the text")
  c.expect(color("S:") == .labelColor, "labels keep the normal color")
  c.expect(color("5h") == .labelColor, "time left keeps the normal color")
  c.expect(color("–") == .labelColor, "a missing value stays normal")
  c.expect(color("50%") != .labelColor, "the percent number is colored")
  c.expect(color("%") != .labelColor, "the percent sign is colored")
  let hue = color("50%")?.usingColorSpace(.sRGB)?.hueComponent ?? -1
  c.expect(abs(hue - 1.0 / 6) < 0.01, "color follows the value: \(hue)")

  let tokenCases = [
    (999, "999"), (312_000, "312K"), (999_600, "1.0M"),
    (48_200_000, "48.2M"), (612_000_000, "612M"), (1_234_567_890, "1.2B"),
  ]
  for (count, text) in tokenCases {
    c.expect(formatTokens(count) == text, "\(count) -> \(formatTokens(count))")
  }
  c.expect(durationText(7_500) == "2h 5m", "duration: \(durationText(7_500))")
  c.expect(updatedRow(nil, now: now).hasPrefix("No limit data"), "no stamp")
  c.expect(updatedRow(990, now: now) == "Updated just now", "under a minute")
  c.expect(updatedRow(820, now: now) == "Updated 3m ago", "minutes ago")
}

func selfCheck() throws {
  let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent("usage-tracker-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: dir) }
  let c = Checks()
  checkMerge(c)
  checkSaving(c, dir: dir)
  try checkLedger(c, dir: dir)
  checkText(c)
  print(c.failed == 0 ? "self-check passed" : "\(c.failed) checks failed")
  exit(c.failed == 0 ? 0 : 1)
}
