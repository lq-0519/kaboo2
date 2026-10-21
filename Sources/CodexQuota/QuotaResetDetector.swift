import Foundation

/// Shares the confirmed-cycle rule between notifications and automatic greetings.
enum QuotaResetDetector {
  /// Allows the same small timestamp corrections already accepted by reset notifications.
  static let timestampTolerance: TimeInterval = 60

  /// Recognizes a new backend cycle, using time or a ten-point recovery as supporting evidence.
  static func didReset(
    previousReset: Date,
    previousRemaining: Double,
    current: QuotaWindow,
    fetchedAt: Date
  ) -> Bool {
    current.resetsAt.timeIntervalSince(previousReset) > timestampTolerance
      && (previousReset.timeIntervalSince(fetchedAt) <= timestampTolerance
        || current.remainingPercent - previousRemaining >= 10)
  }

  /// Creates the existing opaque account namespace without persisting account identifiers.
  static func accountKey(_ accountID: String) -> String {
    var digest: UInt64 = 14_695_981_039_346_656_037
    for byte in accountID.trimmingCharacters(in: .whitespacesAndNewlines).utf8 {
      digest ^= UInt64(byte)
      digest &*= 1_099_511_628_211
    }
    return String(format: "%016llx", digest)
  }
}
