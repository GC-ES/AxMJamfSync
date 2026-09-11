// JamfDashboardView.swift
// Dashboard "Jamf Pro" focus — scoped entirely to Jamf-sourced attributes, for devices
// Jamf actually has a record of (deviceSource != .axmOnly). A device retired in real
// life but not yet released from AxM has no Jamf record, so it simply won't appear here.

import SwiftUI

struct JamfDashboardContent: View {
  @EnvironmentObject private var store: AppStore
  var navigateToDevices: () -> Void = {}

  private var s: DashboardStats { store.stats }              // unfiltered — sync status, hasAxmConfigured
  private var fs: DashboardStats { store.jamfDashboardStats } // facet-filtered — every breakdown card reads this

  // Same signal DashboardView uses to decide whether the Apple focus mode is even
  // offered — a system counts as "in play" if it's configured, or if there's
  // already cached data from a previous sync.
  private var hasAxmConfigured: Bool {
    (!store.axmCredentials.clientId.isEmpty && !store.axmCredentials.keyId.isEmpty) || s.axmTotal > 0
  }

  private var deviceTypeSegments: [DonutSegment] {
    [
      DonutSegment(label: "Computers", value: fs.jamfComputerCount, color: .blue),
      DonutSegment(label: "Mobile", value: fs.jamfMobileCount, color: .purple),
    ]
  }
  private var fileVaultSegments: [DonutSegment] {
    [
      DonutSegment(label: "Encrypted", value: fs.jamfFileVaultEncrypted, color: .green),
      DonutSegment(label: "Not Encrypted", value: fs.jamfFileVaultNotEncrypted, color: .red),
      DonutSegment(label: "Unknown", value: fs.jamfFileVaultUnknown, color: .secondary),
    ]
  }
  private var checkinSegments: [DonutSegment] {
    [
      DonutSegment(label: "Today", value: fs.jamfCheckinToday, color: .green),
      DonutSegment(label: "This Week", value: fs.jamfCheckinThisWeek, color: .blue),
      DonutSegment(label: "This Month", value: fs.jamfCheckinThisMonth, color: .secondary),
      DonutSegment(label: "Stale (30+ days)", value: fs.jamfCheckinStale, color: .orange),
      DonutSegment(label: "Never", value: fs.jamfCheckinNever, color: .red),
    ]
  }

  // Every tap here must land on exactly the population the tapped number was
  // counted from — which is the facet-filtered set (fs), not the whole fleet.
  // So any facet not explicitly overridden by the tapped dimension itself carries
  // forward into the drill-down. Without this, a card's count (computed from `fs`)
  // and the Devices list you land on (filtered by only the tapped condition) could
  // disagree whenever a dashboard facet was active.
  private func drillDown(deviceType: DeviceKind? = nil, jamfManaged: Bool? = nil,
                          osVersion: String? = nil, fileVault: String? = nil,
                          checkin: String? = nil, expiringWindow: String? = nil) {
    store.drillDown(source: expiringWindow != nil ? .both : nil,
                     deviceType: deviceType ?? store.jamfDashboardDeviceTypeFacet,
                     jamfManaged: jamfManaged ?? store.jamfDashboardManagedFacet,
                     osVersion: osVersion,
                     fileVault: fileVault ?? store.jamfDashboardFileVaultFacet,
                     checkin: checkin ?? store.jamfDashboardCheckinFacet,
                     expiringWindow: expiringWindow)
    navigateToDevices()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {

      // MARK: Facet filter bar — dashboard-only lens, independent of the Devices
      // tab's own filters. Every card below reads from `fs` (jamfDashboardStats),
      // which is recomputed against whichever facets are active here.
      JamfDashboardFacetBar()
        .padding(.horizontal, 24)

      // MARK: Totals row
      HStack(spacing: 12) {
        StatCard(title: "Total Devices (Jamf)", value: "\(fs.jamfTotal)", icon: "server.rack", color: .primary,
                 tooltip: InfoContent(
                   icon: "server.rack", title: "Total in Jamf Pro",
                   summary: "All computer and mobile device records currently in your Jamf Pro inventory.",
                   bullets: ["Fetched from Jamf during each sync.", "This total ignores whether a device is also present in AxM."]))
        DashboardDrillDown(action: { drillDown(jamfManaged: true) }) {
          StatCard(title: "Managed", value: "\(fs.jamfManaged)", icon: "checkmark.shield", color: .green,
                   tooltip: InfoContent(
                     icon: "checkmark.shield", title: "Managed by Jamf",
                     summary: "Devices actively managed by Jamf Pro — Jamf can push policies, apps, and settings to these.",
                     bullets: ["These are the devices this app can write warranty dates back to.", "Unmanaged devices cannot receive Jamf configuration profiles or policies."]))
        }
        DashboardDrillDown(action: { drillDown(jamfManaged: false) }) {
          StatCard(title: "Unmanaged", value: "\(fs.jamfUnmanaged)", icon: "exclamationmark.shield", color: .orange,
                   tooltip: InfoContent(
                     icon: "exclamationmark.shield", title: "Unmanaged in Jamf",
                     summary: "Devices present in Jamf but not currently under active management.",
                     bullets: ["May have had their MDM profile removed, or were enrolled manually without full MDM.",
                               "Warranty dates can still be written back to Jamf inventory records for these devices."]))
        }
      }
      .padding(.horizontal, 24)

      // MARK: Coverage Expiring — sourced from AxM's warranty data, scoped to devices
      // Jamf also has a record of (deviceSource == .both). Shown only when AxM is
      // configured — in a Jamf-only environment there's no AppleCare data to show,
      // so the card doesn't render rather than showing an empty or misleading substitute.
      if hasAxmConfigured {
        CardSection(title: "Coverage Expiring", icon: "clock.badge.exclamationmark") {
          HStack(spacing: 12) {
            DashboardDrillDown(action: { drillDown(expiringWindow: "0–30") }) {
              CoverageStatCard(title: "Next 30 Days", value: fs.axmExpiring30InJamf, total: fs.jamfTotal,
                               icon: "exclamationmark.shield.fill", color: .red)
            }
            DashboardDrillDown(action: { drillDown(expiringWindow: "31–60") }) {
              CoverageStatCard(title: "31–60 Days", value: fs.axmExpiring60InJamf, total: fs.jamfTotal,
                               icon: "clock.badge.exclamationmark.fill", color: .orange)
            }
            DashboardDrillDown(action: { drillDown(expiringWindow: "61–90") }) {
              CoverageStatCard(title: "61–90 Days", value: fs.axmExpiring90InJamf, total: fs.jamfTotal,
                               icon: "clock.fill", color: .yellow,
                               tooltip: InfoContent(
                                 icon: "clock.fill", title: "Coverage Expiring in 61–90 Days",
                                 summary: "AppleCare or warranty coverage from AxM on these devices ends within the next 61 to 90 days.",
                                 bullets: ["Scoped to devices Jamf also has a record of.",
                                           "An AxM-only device (no matching Jamf record) is never counted here."]))
            }
          }
        }
        .padding(.horizontal, 24)
      }

      // MARK: Device type mix
      CardSection(title: "Device Type", icon: "laptopcomputer") {
        HStack(spacing: 64) {
          DonutChartView(segments: deviceTypeSegments, centerTitle: "\(fs.jamfComputerCount + fs.jamfMobileCount)", centerSubtitle: "devices")
            .frame(width: 160, height: 160)
          VStack(alignment: .leading, spacing: 16) {
            ForEach(deviceTypeSegments) { seg in
              DashboardDrillDown(action: { drillDown(deviceType: seg.label == "Computers" ? .mac : .mobile) }) {
                CoverageLegendRow(label: seg.label, value: seg.value, color: seg.color)
              }
            }
          }
          Spacer()
        }
        .padding(.vertical, 8)
      }
      .padding(.horizontal, 24)

      // MARK: OS Version — split by device type, only shown for types actually present
      HStack(alignment: .top, spacing: 16) {
        if fs.jamfComputerCount > 0 {
          CardSection(title: "macOS Version", icon: "cpu") {
            BreakdownBarChart(breakdown: fs.jamfMacOsVersionBreakdown, color: .blue, sortMode: .byVersionDescending,
                               onTapRow: { ver in drillDown(deviceType: .mac, osVersion: ver) })
          }
        }
        if fs.jamfMobileCount > 0 {
          CardSection(title: "Mobile OS Version", icon: "cpu") {
            BreakdownBarChart(breakdown: fs.jamfMobileOsVersionBreakdown, color: .purple, sortMode: .byVersionDescending,
                               onTapRow: { ver in drillDown(deviceType: .mobile, osVersion: ver) })
          }
        }
      }
      .padding(.horizontal, 24)

      // MARK: FileVault encryption — computers only
      if fs.jamfComputerCount > 0 {
        CardSection(title: "FileVault Encryption", icon: "lock.shield.fill") {
          HStack(spacing: 64) {
            DonutChartView(segments: fileVaultSegments, centerTitle: "\(fs.jamfComputerCount)", centerSubtitle: "Macs")
              .frame(width: 160, height: 160)
            VStack(alignment: .leading, spacing: 16) {
              ForEach(fileVaultSegments) { seg in
                DashboardDrillDown(action: { drillDown(deviceType: .mac, fileVault: seg.label) }) {
                  CoverageLegendRow(label: seg.label, value: seg.value, color: seg.color)
                }
              }
            }
            Spacer()
          }
          .padding(.vertical, 8)
        }
        .padding(.horizontal, 24)
      }

      // MARK: Check-in freshness
      CardSection(title: "Check-in Freshness", icon: "antenna.radiowaves.left.and.right") {
        HStack(spacing: 64) {
          DonutChartView(segments: checkinSegments, centerTitle: "\(fs.jamfComputerCount + fs.jamfMobileCount)", centerSubtitle: "devices")
            .frame(width: 160, height: 160)
          VStack(alignment: .leading, spacing: 16) {
            ForEach(checkinSegments) { seg in
              DashboardDrillDown(action: { drillDown(checkin: seg.label) }) {
                CoverageLegendRow(label: seg.label, value: seg.value, color: seg.color)
              }
            }
          }
          Spacer()
        }
        .padding(.vertical, 8)
      }
      .padding(.horizontal, 24)

      // MARK: Sync status
      CardSection(title: "Jamf Pro", icon: "server.rack") {
        SyncTimestampRow(label: "Last sync", timestamp: s.lastJamfSync)
        if s.runJamfFetched > 0 {
          DashStatRow(label: "Fetched this run", value: s.runJamfFetched, color: .blue)
        }
      }
      .padding(.horizontal, 24)

      // MARK: Coverage distribution — same fields as the Coverage Expiring tiles
      // above, restricted to deviceSource == .both, visualised as a ring to match
      // the Default and Apple dashboards' own Coverage Distribution cards. Shown
      // only when AxM is configured, same reasoning as Coverage Expiring above.
      // Placed last — a summary visual, not the first thing worth acting on.
      if hasAxmConfigured {
        CardSection(title: "Coverage Distribution", icon: "chart.pie.fill") {
          HStack(spacing: 64) {
            CoverageRingView(active: fs.jamfCoverageActive, inactive: fs.jamfCoverageInactive,
                              noPlan: fs.jamfCoverageNoPlan, neverFetched: fs.jamfCoverageNeverFetched)
              .frame(width: 220, height: 220)
            VStack(alignment: .leading, spacing: 16) {
              CoverageLegendRow(label: "In Warranty",      value: fs.jamfCoverageActive,       color: .green)
              CoverageLegendRow(label: "Out of Warranty",  value: fs.jamfCoverageInactive,     color: .red)
              CoverageLegendRow(label: "No Coverage Info", value: fs.jamfCoverageNoPlan,       color: .orange)
              CoverageLegendRow(label: "Never Fetched",    value: fs.jamfCoverageNeverFetched, color: .secondary)
            }
            Spacer()
          }
          .padding(.vertical, 8)
        }
        .padding(.horizontal, 24)
      }
    }
  }
}

// MARK: - Facet filter bar
// Managed/Device Type as segmented controls (binary/ternary — a good fit for that
// control), FileVault/Check-in as icon-chip menus (more values than a segmented
// control comfortably fits). Plus an active-filter chip row below, matching the
// chip style already used for Dashboard drill-down filters in DevicesView.swift.
// Purely a Jamf-dashboard lens — setting these never touches the Devices tab's own
// filteredDevices.
private struct JamfDashboardFacetBar: View {
  @EnvironmentObject private var store: AppStore

  private var matchCount: Int { store.jamfDashboardStats.jamfTotal }

  var body: some View {
    VStack(spacing: 8) {
      HStack(spacing: 10) {
        Spacer()
        Picker("", selection: store.facetBinding(\.jamfDashboardManagedFacet)) {
          Text("All").tag(Bool?.none)
          Text("Managed").tag(Bool?.some(true))
          Text("Unmanaged").tag(Bool?.some(false))
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 220)

        Picker("", selection: store.facetBinding(\.jamfDashboardDeviceTypeFacet)) {
          Text("All").tag(DeviceKind?.none)
          Text("Computers").tag(DeviceKind?.some(.mac))
          Text("Mobile").tag(DeviceKind?.some(.mobile))
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 220)

        FacetChipMenu(icon: "lock.fill", title: "FileVault",
                      options: [("All", nil), ("Encrypted", "Encrypted"),
                                ("Not Encrypted", "Not Encrypted"), ("Unknown", "Unknown")],
                      selection: store.facetBinding(\.jamfDashboardFileVaultFacet))

        FacetChipMenu(icon: "antenna.radiowaves.left.and.right", title: "Check-in",
                      options: [("All", nil), ("Today", "Today"), ("This Week", "This Week"),
                                ("This Month", "This Month"), ("Stale (30+ days)", "Stale (30+ days)"),
                                ("Never", "Never")],
                      selection: store.facetBinding(\.jamfDashboardCheckinFacet))

        Spacer()
      }

      if store.jamfDashboardFacetCount > 0 {
        HStack(spacing: 8) {
          Spacer()
          if let m = store.jamfDashboardManagedFacet {
            FacetActiveChip(label: m ? "Managed" : "Unmanaged") { store.jamfDashboardManagedFacet = nil }
          }
          if let dt = store.jamfDashboardDeviceTypeFacet {
            FacetActiveChip(label: dt == .mac ? "Computers" : "Mobile") { store.jamfDashboardDeviceTypeFacet = nil }
          }
          if let fv = store.jamfDashboardFileVaultFacet {
            FacetActiveChip(label: fv) { store.jamfDashboardFileVaultFacet = nil }
          }
          if let ck = store.jamfDashboardCheckinFacet {
            FacetActiveChip(label: ck) { store.jamfDashboardCheckinFacet = nil }
          }
          Text("^[\(matchCount) device](inflect: true) match")
            .font(.caption)
            .foregroundStyle(.secondary)
          Button("Clear All") { store.clearJamfDashboardFacets() }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(Color.accentColor)
          Spacer()
        }
      }
    }
  }

}
