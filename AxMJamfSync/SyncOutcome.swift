// SyncOutcome.swift
// S7: the single four-state result of a sync run. A run is only ever reported as
// `.success` when every stage completed and persisted; anything less is `.partial`
// (some real work landed, but the run is not a complete/fresh sync), `.failed`
// (nothing usable, or a hard stop), or `.cancelled` (user pressed Stop).
//
// The reporting path must never collapse `.partial` / `.failed` into `.success` —
// see ARCHITECTURE.md "Sync outcome is four-state, never collapsed to success (S7)".

import SwiftUI

enum SyncOutcome: String, Sendable, Codable {
  case success
  case partial
  case failed
  case cancelled

  /// Severity ladder used by `downgraded(to:)`. `cancelled` is never reached this
  /// way — it is set explicitly in the CancellationError path and wins outright.
  private var severity: Int {
    switch self {
    case .success:   return 0
    case .partial:   return 1
    case .failed:    return 2
    case .cancelled: return 3
    }
  }

  /// Monotonic merge: an outcome can only get worse as a run accumulates problems,
  /// never better. `mark(.success)` after a `.partial` is a no-op.
  func downgraded(to other: SyncOutcome) -> SyncOutcome {
    other.severity > severity ? other : self
  }
}

// MARK: - Presentation (one classification helper per breakdown — ARCHITECTURE.md)
// Every surface that renders an outcome (Sync tab summary, sidebar row, scheduler
// notification) goes through these — so a partial run can never look like a clean
// one in one place and not another.
extension SyncOutcome {
  var label: String {
    switch self {
    case .success:   return "Sync complete"
    case .partial:   return "Completed with issues"
    case .failed:    return "Sync failed"
    case .cancelled: return "Sync stopped"
    }
  }

  var symbol: String {
    switch self {
    case .success:   return "checkmark.circle.fill"
    case .partial:   return "exclamationmark.triangle.fill"
    case .failed:    return "xmark.circle.fill"
    case .cancelled: return "stop.circle.fill"
    }
  }

  var tint: Color {
    switch self {
    case .success:   return .green
    case .partial:   return .orange
    case .failed:    return .red
    case .cancelled: return .secondary
    }
  }

  var environmentStatus: EnvironmentSyncStatus {
    switch self {
    case .success:   return .success
    case .partial:   return .partial
    case .failed:    return .error
    case .cancelled: return .cancelled
    }
  }
}

// MARK: - Scheduled multi-environment run summary

/// Aggregate outcome of one scheduled run (which fans out over every environment
/// via the serial queue). Drives the single "Scheduled Sync Complete" notification
/// so it reflects what actually happened, not merely that the queue drained.
struct ScheduledRunSummary {
  var succeeded: Int = 0
  var partial:   Int = 0
  var failed:    Int = 0
  var cancelled: Int = 0

  var total: Int { succeeded + partial + failed + cancelled }
  var allClean: Bool { total > 0 && succeeded == total }

  init(outcomes: [SyncOutcome]) {
    for o in outcomes {
      switch o {
      case .success:   succeeded += 1
      case .partial:   partial   += 1
      case .failed:    failed    += 1
      case .cancelled: cancelled += 1
      }
    }
  }

  /// Notification body. A fully clean run reads exactly as it did before this
  /// change; a mixed run spells out the breakdown.
  var notificationText: String {
    if allClean {
      return total == 1 ? "Finished syncing 1 environment."
                        : "Finished syncing \(total) environments."
    }
    var parts: [String] = ["\(succeeded) of \(total) synced successfully"]
    if failed    > 0 { parts.append("\(failed) failed") }
    if partial   > 0 { parts.append("\(partial) with issues") }
    if cancelled > 0 { parts.append("\(cancelled) stopped") }
    return parts.joined(separator: "; ") + "."
  }
}
