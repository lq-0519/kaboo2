import Darwin
import Foundation

/// 图表需要的一天用量。日期使用本地日历，空用量表示缺少可比较的额度记录。
struct DailyQuotaUsageDay: Equatable {
  /// 当地日期的起点，供图表生成日期标签。
  let date: Date

  /// 当天已观察到的消耗，单位为一轮 7 天额度的百分比。
  let usedPercent: Double?

  /// 记录覆盖不完整，已统计的消耗可能低于实际消耗。
  let isPartial: Bool
}

/// 从现有额度快照累计每日用量。主线程更新内存状态，后台队列串行保存紧凑账本。
final class DailyQuotaUsageHistory {
  /// 弹窗展示含今天在内的七个自然日，磁盘多保留一段时间以便后续查看。
  private static let displayDays = 7
  private static let retainedDays = 90

  /// 限制长时间使用不同账号后的账本大小，只保留最近查询的账号。
  private static let retainedAccounts = 8

  /// 同一个已知周期允许服务在一分钟内校准重置时间。
  private static let resetTolerance = QuotaResetDetector.timestampTolerance

  /// 根据服务给出的 7 天周期结束时间反推新周期开始时间。
  private static let windowDuration: TimeInterval = 7 * 24 * 60 * 60

  /// 将同一段使用期间的多次变化合并写入，使用已有成功刷新触发保存。
  private static let writeInterval: DispatchTimeInterval = .seconds(300)

  /// 按本地自然日保存已观测用量以及该日是否可能漏记。
  private struct DayTotal: Codable, Equatable {
    /// 当天已确定归属的用量。尚无可比较记录时保留为空。
    var usedPercent: Double?

    /// 当天一旦出现无法归属的变化，后续观测无法消除该缺口。
    var isPartial = false
  }

  /// 跨重启比较额度窗口所需的最后一次成功观测及当前周期的已统计上界。
  private struct Observation: Codable, Equatable {
    /// 成功收到额度响应的绝对时间，用于识别日期和周期的边界。
    var fetchedAt: Date

    /// 服务返回的下次重置绝对时间，用于判断两次快照是否在同一周期。
    var resetsAt: Date

    /// 同周期已见过的最大用量，防止小幅下调后回升时重复累计。
    var highWater: Double

    /// 最新快照的用量，用于识别修正与跨午夜时是否发生变化。
    var usedPercent: Double

    /// 已知的套餐标识，用量口径发生变化时重新建立基线。
    var planType: String?

    /// 观测时使用的时区标识，检测旅行或手工切换时区导致的日期变化。
    var timeZoneID: String

    /// 接收快照时的本地日期，编码为 YYYYMMDD 以便排序及有限保留。
    var dayKey: Int

    /// 服务重置时间出现未经证实的变化时，下一次观测用于稳定基线。
    var hasUncertainReset = false
  }

  /// 单个登录身份的最近用量和快照基线。凭据和会话内容无需存储。
  private struct AccountHistory: Codable, Equatable {
    /// 有统计或覆盖状态的自然日，缺少观测的日期不占存储空间。
    var days: [Int: DayTotal] = [:]

    /// 同账号最近一次成功观测，用于处理后续增量和重置周期。
    var observation: Observation?
  }

  /// 一次原子保存所有日用量和对应基线，使意外退出后的累计可以继续。
  private struct Ledger: Codable, Equatable {
    /// 当前账本结构版本，用于避免覆盖无法识别的历史格式。
    var version = 1

    /// 按调用方提供的账号摘要存储各自独立的历史。
    var accounts: [String: AccountHistory] = [:]
  }

  /// 本机应用支持目录下的独立额度历史文件。
  private let stateURL: URL

  /// 后台串行写入队列，防止较早的快照覆盖已经保存的较新快照。
  private let writeQueue = DispatchQueue(label: "com.codexquota.daily-usage", qos: .utility)

  /// 仅持有独占锁的实例写入账本，避免并行运行时覆盖彼此的累计。
  private var lockDescriptor: Int32 = -1

  /// 账本无法读取或独占时停止写入，在内存中仍可继续统计。
  private var canWrite = false

  /// 主线程维护的最新内存账本，弹窗查询直接从这里取数。
  private var ledger = Ledger()

  /// 最近成功写入的账本，初始化后只在写入队列访问。
  private var writtenLedger: Ledger?

  /// 日用量或周期基线发生变化时置位，单纯刷新观测时间不会触发写入。
  private var needsWrite = false

  /// 使用单调时钟限制写入频率，系统时钟调整后仍能继续保存。
  private var nextWriteTime = DispatchTime.now()

  /// 应用启动时只读取一次历史，保留无法解码的旧文件供后续恢复。
  init() {
    let fileManager = FileManager.default
    let directory = fileManager.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/CodexQuota", isDirectory: true)
    stateURL = directory.appendingPathComponent("daily-quota-usage.json")

    do {
      try fileManager.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
      )
      let lockPath = directory.appendingPathComponent("daily-quota-usage.lock").path
      lockDescriptor = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
      canWrite = lockDescriptor >= 0 && flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0
      if fileManager.fileExists(atPath: stateURL.path) {
        let existing = try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: stateURL))
        guard existing.version == ledger.version else {
          canWrite = false
          NSLog("额度历史文件版本不受支持，已保留原文件。")
          return
        }
        ledger = existing
        writtenLedger = existing
      }
    } catch {
      canWrite = false
      NSLog("额度历史文件无法读取，已暂停写入。")
    }
  }

  /// 对退出后再次启动的实例释放保存权。
  deinit {
    if lockDescriptor >= 0 { close(lockDescriptor) }
  }

  /// 在现有额度请求成功时比较两次观测，只累计能归属到本地日期的 7 天额度消耗。
  func observe(window: QuotaWindow, planType: String?, accountKey: String, fetchedAt: Date) {
    guard window.kind == .sevenDay, !accountKey.isEmpty, (0...100).contains(window.usedPercent),
      window.resetsAt.timeIntervalSince1970.isFinite,
      fetchedAt.timeIntervalSince1970.isFinite
    else { return }

    let calendar = Self.localCalendar()
    let dayKey = Self.dayKey(fetchedAt, calendar: calendar)
    var account = ledger.accounts[accountKey] ?? AccountHistory()
    let previous = account.observation
    var current = Observation(
      fetchedAt: fetchedAt, resetsAt: window.resetsAt, highWater: window.usedPercent,
      usedPercent: window.usedPercent, planType: planType ?? previous?.planType,
      timeZoneID: calendar.timeZone.identifier, dayKey: dayKey
    )
    // 以账号和套餐为比较边界，首次取到的窗口累积值无法归属到今天。
    let canCompare = previous.map {
      $0.fetchedAt < fetchedAt && $0.timeZoneID == current.timeZoneID
        && ($0.planType == nil || $0.planType == current.planType)
    } ?? false

    if let previous, canCompare {
      let resetShift = window.resetsAt.timeIntervalSince(previous.resetsAt)
      // 明显回退的重置时间可能来自旧快照，跳过它以保留可信的周期锚点和观测时间。
      guard resetShift >= -Self.resetTolerance else {
        scheduleWriteIfNeeded()
        return
      }
      if resetShift <= Self.resetTolerance {
        current.highWater = max(previous.highWater, window.usedPercent)
        // 保持已接受的周期时间作为比较锚点，避免逐次小幅校准掩盖真实周期变化。
        current.resetsAt = previous.resetsAt
        let delta = current.highWater - previous.highWater
        let sameDay = previous.dayKey == dayKey
        let isStable = delta == 0 && window.usedPercent == previous.usedPercent
        if previous.hasUncertainReset || window.usedPercent < previous.highWater {
          markGap(from: previous.dayKey, through: dayKey, for: &account)
        } else if sameDay || isStable {
          record(dayKey, increment: delta, partial: false, for: &account)
        } else {
          markGap(from: previous.dayKey, through: dayKey, for: &account)
        }
      } else {
        let newStart = window.resetsAt.addingTimeInterval(-Self.windowDuration)
        let followsObservation = newStart.timeIntervalSince(previous.fetchedAt) >= -Self.resetTolerance
        let followsExpiry = previous.resetsAt <= fetchedAt
          && newStart.timeIntervalSince(previous.resetsAt) >= -Self.resetTolerance
        let droppedAfterNewStart = followsObservation && window.usedPercent < previous.usedPercent
        let didReset = newStart.timeIntervalSince(fetchedAt) <= Self.resetTolerance
          && (followsExpiry || droppedAfterNewStart)
        markGap(from: previous.dayKey, through: dayKey, for: &account)
        if didReset {
          // 只有新周期确实从今天开始时，才从零累计新用量。旧周期尾段仍可能缺失。
          if newStart <= fetchedAt, window.resetsAt > fetchedAt, !previous.hasUncertainReset,
            Self.dayKey(newStart, calendar: calendar) == dayKey
          {
            record(dayKey, increment: window.usedPercent, partial: true, for: &account)
          }
        } else {
          // 日期修正后用新时间比较后续观测，保留旧用量上界，避免把修正前的用量再算一遍。
          current.highWater = max(previous.highWater, current.highWater)
          current.hasUncertainReset = true
        }
      }
    } else if previous?.fetchedAt != fetchedAt {
      markGap(from: previous?.dayKey ?? dayKey, through: dayKey, for: &account)
      if let previous, previous.planType == current.planType,
        abs(window.resetsAt.timeIntervalSince(previous.resetsAt)) <= Self.resetTolerance
      {
        // 时区或本地时钟变化时跳过该段增量，也保留旧上界以免再次统计。
        current.highWater = max(previous.highWater, current.highWater)
      }
    } else {
      return
    }

    if previous?.dayKey != dayKey {
      let firstRetainedDay = calendar.date(byAdding: .day, value: 1 - Self.retainedDays, to: fetchedAt)
      if let firstRetainedDay {
        let cutoff = Self.dayKey(firstRetainedDay, calendar: calendar)
        account.days = account.days.filter { $0.key >= cutoff }
      }
      needsWrite = true
    }
    if previous?.resetsAt != current.resetsAt || previous?.planType != current.planType
      || previous?.timeZoneID != current.timeZoneID
      || previous?.hasUncertainReset != current.hasUncertainReset
    {
      needsWrite = true
    }
    account.observation = current
    ledger.accounts[accountKey] = account
    if previous == nil, ledger.accounts.count > Self.retainedAccounts {
      let oldestOthers = ledger.accounts.filter { $0.key != accountKey }.sorted {
        ($0.value.observation?.fetchedAt ?? .distantPast)
          < ($1.value.observation?.fetchedAt ?? .distantPast)
      }
      for (key, _) in oldestOthers.prefix(ledger.accounts.count - Self.retainedAccounts) {
        ledger.accounts.removeValue(forKey: key)
      }
    }
    scheduleWriteIfNeeded()
  }

  /// 按时间顺序提供弹窗的最近七个自然日，缺失日期与确认观测到的零用量分开表示。
  func recentDays(accountKey: String?, now: Date = Date()) -> [DailyQuotaUsageDay] {
    let calendar = Self.localCalendar()
    let today = calendar.startOfDay(for: now)
    let account = accountKey.flatMap { ledger.accounts[$0] }
    return (0..<Self.displayDays).reversed().compactMap { offset in
      guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
      let key = Self.dayKey(date, calendar: calendar)
      let total = account?.days[key]
      return DailyQuotaUsageDay(
        date: date, usedPercent: total?.usedPercent, isPartial: total?.isPartial ?? false
      )
    }
  }

  /// 正常退出前等待已排队的写入完成，并补写尚在内存中的最新日用量和观测时间。
  func flush() {
    guard canWrite, !ledger.accounts.isEmpty else { return }
    let snapshot = ledger
    writeQueue.sync { _ = write(snapshot) }
  }

  /// 标记变化无法定位的两个观测日期，中间没有快照的自然日保持无数据。
  private func markGap(from previousDay: Int, through currentDay: Int, for account: inout AccountHistory) {
    record(previousDay, increment: nil, partial: true, for: &account)
    if previousDay != currentDay {
      record(currentDay, increment: nil, partial: true, for: &account)
    }
  }

  /// 更新一日的累计值与覆盖状态。相同的快照只更新观测时间，避免唤醒磁盘写入队列。
  private func record(
    _ dayKey: Int, increment: Double?, partial: Bool, for account: inout AccountHistory
  ) {
    let before = account.days[dayKey]
    var total = before ?? DayTotal()
    if let increment {
      let sum = (total.usedPercent ?? 0) + increment
      if sum.isFinite { total.usedPercent = sum }
    }
    total.isPartial = total.isPartial || partial
    if before != total {
      account.days[dayKey] = total
      needsWrite = true
    }
  }

  /// 复用额度刷新机会合并保存，不创建新的定时器，失败后保留数据以便后续重试。
  private func scheduleWriteIfNeeded() {
    let now = DispatchTime.now()
    guard canWrite, needsWrite, now >= nextWriteTime else { return }
    nextWriteTime = now + Self.writeInterval
    needsWrite = false
    let snapshot = ledger
    writeQueue.async { [weak self] in
      guard let self, !self.write(snapshot) else { return }
      DispatchQueue.main.async { [weak self] in self?.needsWrite = true }
    }
  }

  /// 在后台队列写入原子快照，始终把日用量和对应基线作为一个文件保存。
  private func write(_ snapshot: Ledger) -> Bool {
    guard writtenLedger != snapshot else { return true }
    do {
      let data = try JSONEncoder().encode(snapshot)
      try data.write(to: stateURL, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
      writtenLedger = snapshot
      return true
    } catch {
      NSLog("额度历史保存失败，稍后将重试。")
      return false
    }
  }

  /// 使用本机当前时区划分公历日期，避免夏令时当天按固定 24 小时计算。
  private static func localCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    return calendar
  }

  /// 将快照对应的本地日期编码成稳定的日历键，记录后不会重新解释历史日期。
  private static func dayKey(_ date: Date, calendar: Calendar) -> Int {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return (parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
  }
}
