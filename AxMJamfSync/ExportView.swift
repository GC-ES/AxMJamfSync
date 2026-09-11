// ExportView.swift
// Export tab — CSV export of filtered or all devices.
// Column selection AND order persisted to UserDefaults via
// AppStore.saveExportColumns() (wired to fire on every change — see 6.3).
// Filename: AxM-Jamf-Sync_{environment}_{preset}_{date}.csv. Success banner
// offers Show in Finder for the file just saved.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Export preset

private struct ExportPreset: Identifiable {
    let id:      String
    let title:   String
    let icon:    String
    let color:   Color
    var count:   Int
    let devices: (AppStore) -> [Device]
}

@MainActor
private func buildPresets(store: AppStore) -> [ExportPreset] {
    // P11: Use precomputed counts from DashboardStats (single O(n) pass in recomputeStats)
    // instead of running 7 separate .filter() passes over 50k devices on every rebuild.
    // The `devices` closures still filter on demand at export time — only the badge counts
    // are read from the cached stats struct.
    let s = store.stats
    return [
        ExportPreset(id: "all",
            title: "All Devices", icon: "square.stack.3d.up.fill", color: .blue,
            count: s.total,
            devices: { $0.devices }),
        ExportPreset(id: "active",
            title: "Active Only", icon: "checkmark.circle.fill", color: .green,
            count: s.exportActiveCount,
            devices: { $0.devices.filter { $0.axmDeviceStatus?.uppercased() == "ACTIVE" } }),
        ExportPreset(id: "released",
            title: "Released Only", icon: "minus.circle.fill", color: .orange,
            count: s.exportReleasedCount,
            devices: { $0.devices.filter { $0.axmDeviceStatus?.uppercased() == "RELEASED" } }),
        ExportPreset(id: "no_coverage",
            title: "No Coverage Info Found", icon: "shield.slash.fill", color: .red,
            count: s.exportNoCovCount,
            devices: { $0.devices.filter { $0.coverageStatus == .noCoverage } }),
        ExportPreset(id: "cov_found",
            title: "Coverage Info Found", icon: "checkmark.shield.fill", color: .teal,
            count: s.exportCovFoundCount,
            devices: { $0.devices.filter { [.active, .inactive, .expired, .cancelled].contains($0.coverageStatus) } }),
        ExportPreset(id: "cov_active",
            title: "Coverage Active", icon: "shield.lefthalf.filled", color: .blue,
            count: s.exportCovActiveCount,
            devices: { $0.devices.filter { $0.coverageStatus == .active } }),
        ExportPreset(id: "cov_inactive",
            title: "Out of Warranty", icon: "shield.slash", color: .secondary,
            count: s.exportCovInactiveCount,
            devices: { $0.devices.filter { [.inactive, .expired, .cancelled].contains($0.coverageStatus) } }),
        // 6.2: the exports admins actually reach for to email someone — reuse
        // the same expiringWindowLabel/wbStatus classification the Dashboard's
        // own "Expiring Soon" cards and Jamf Update breakdown use, so a preset's
        // count can never disagree with the equivalent Dashboard number.
        ExportPreset(id: "expiring_30",
            title: "Expiring in 30 Days", icon: "exclamationmark.shield.fill", color: .red,
            count: s.axmExpiring30,
            devices: { $0.devices.filter { AppStore.expiringWindowLabel(for: $0) == "0–30" } }),
        ExportPreset(id: "expiring_60",
            title: "Expiring in 31–60 Days", icon: "clock.badge.exclamationmark.fill", color: .orange,
            count: s.axmExpiring60,
            devices: { $0.devices.filter { AppStore.expiringWindowLabel(for: $0) == "31–60" } }),
        ExportPreset(id: "expiring_90",
            title: "Expiring in 61–90 Days", icon: "clock.fill", color: .yellow,
            count: s.axmExpiring90,
            devices: { $0.devices.filter { AppStore.expiringWindowLabel(for: $0) == "61–90" } }),
        ExportPreset(id: "wb_failed",
            title: "Write-back Failed", icon: "xmark.circle.fill", color: .red,
            count: s.wbFailed,
            devices: { $0.devices.filter { $0.wbStatus == .failed } }),
        ExportPreset(id: "filtered",
            title: "Current Filter", icon: "line.3.horizontal.decrease.circle.fill", color: .purple,
            count: store.filteredDevices.count,
            devices: { $0.filteredDevices }),
    ]
}

// MARK: - ExportView

struct ExportView: View {
    @EnvironmentObject private var store:    AppStore
    @EnvironmentObject private var envStore: EnvironmentStore
    @State private var selectedPresetId: String        = "all"
    @State private var csvDocument:      CSVDocument?  = nil
    @State private var showFilePicker    = false
    @State private var showPreview       = false
    @State private var exportResult:     ExportResult? = nil

    enum ExportResult {
        // 6.1: success carries the saved file's URL so the banner can offer
        // Show in Finder — landing a CSV with no way back to it was a dead end.
        case success(String, URL), failure(String)
    }

    private var presets: [ExportPreset] { buildPresets(store: store) }
    private var selectedPreset: ExportPreset { presets.first { $0.id == selectedPresetId } ?? presets[0] }
    private var exportCount: Int { selectedPreset.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                // ── Header ───────────────────────────────────────────
                Text("Choose what to export, select columns, then save as CSV.")
                    .font(.callout).foregroundStyle(.secondary)
                .padding(.horizontal, 24).padding(.top, 16)

                HStack(alignment: .top, spacing: 16) {

                    // ── Left: What to export + Column selector ────────
                    VStack(spacing: 16) {

                        // What to export card (image 4 style)
                        GroupBox {
                            let cols = [GridItem(.flexible()), GridItem(.flexible())]
                            LazyVGrid(columns: cols, spacing: 10) {
                                ForEach(presets) { preset in
                                    ExportPresetTile(
                                        preset: preset,
                                        isSelected: selectedPresetId == preset.id
                                    ) {
                                        selectedPresetId = preset.id
                                    }
                                }
                            }
                            .padding(.top, 4)
                        } label: {
                            Label("What to export", systemImage: "square.stack.3d.up.fill")
                                .font(.headline)
                        }

                        // Column selector
                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Button("Select All") {
                                        for i in store.exportColumns.indices { store.exportColumns[i].enabled = true }
                                    }.buttonStyle(.bordered)
                                    Button("Select None") {
                                        for i in store.exportColumns.indices { store.exportColumns[i].enabled = false }
                                    }.buttonStyle(.bordered)
                                    Spacer()
                                    Text("\(store.exportColumns.filter(\.enabled).count)/\(store.exportColumns.count) columns")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Divider()
                                // 6.3: a List (not ScrollView+VStack) so .onMove gives
                                // drag-to-reorder — CSV column order matters and this
                                // is the only way to control it short of re-exporting
                                // and reordering in a spreadsheet afterward.
                                List {
                                    ForEach($store.exportColumns) { $col in
                                        ExportColumnRow(column: $col)
                                    }
                                    .onMove { indices, newOffset in
                                        store.exportColumns.move(fromOffsets: indices, toOffset: newOffset)
                                    }
                                }
                                .listStyle(.plain)
                                .frame(height: 280)
                            }
                        } label: {
                            Label("Columns to Include", systemImage: "tablecells")
                                .font(.headline)
                        }
                        // 6.3: persists both the enabled flags and their order — this
                        // was previously never wired up at all (AppStore.saveExportColumns()
                        // existed but no view ever called it, so column selection didn't
                        // survive a relaunch even before reordering existed).
                        .onChange(of: store.exportColumns) { _, _ in store.saveExportColumns() }
                    }
                    .frame(maxWidth: .infinity)

                    // ── Right: Preview + Export ───────────────────────
                    VStack(spacing: 16) {

                        // Preview card
                        GroupBox {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text("\(exportCount) rows")
                                        .font(.caption).fontWeight(.semibold)
                                        .padding(.horizontal, 8).padding(.vertical, 3)
                                        .background(Color.accentColor.opacity(0.15))
                                        .foregroundStyle(Color.accentColor)
                                        .clipShape(Capsule())
                                    Spacer()
                                }
                                Button {
                                    showPreview = true
                                } label: {
                                    Label("Preview First 5 Rows", systemImage: "tablecells")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered).controlSize(.regular)
                                .disabled(store.exportColumns.filter(\.enabled).isEmpty || store.devices.isEmpty)
                            }
                        } label: {
                            Label("Preview", systemImage: "eye").font(.headline)
                        }
                        .sheet(isPresented: $showPreview) {
                            PreviewRowsSheet(devices: selectedPreset.devices(store))
                                .environmentObject(store)
                        }

                        // Export summary + button
                        GroupBox {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(selectedPreset.title).font(.headline)
                                        Text("^[\(exportCount) device](inflect: true)  ·  ^[\(store.exportColumns.filter(\.enabled).count) column](inflect: true)")
                                            .font(.callout).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(selectedPreset.color.opacity(0.12))
                                            .frame(width: 44, height: 44)
                                        Image(systemName: selectedPreset.icon)
                                            .font(.title3)
                                            .foregroundStyle(selectedPreset.color)
                                    }
                                }

                                if let result = exportResult {
                                    ExportResultBanner(result: result) { exportResult = nil }
                                }

                                // Export CSV button
                                Button {
                                    let devices = selectedPreset.devices(store)
                                    let data = store.buildCSVData(from: devices)
                                    csvDocument   = CSVDocument(csvData: data)
                                    showFilePicker = true
                                } label: {
                                    Label("Export CSV", systemImage: "square.and.arrow.up")
                                        .font(.headline)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 6)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                                .disabled(store.exportColumns.filter(\.enabled).isEmpty || exportCount == 0)
                                .fileExporter(
                                    isPresented: $showFilePicker,
                                    document: csvDocument ?? CSVDocument(csvData: Data()),
                                    contentType: .commaSeparatedText,
                                    defaultFilename: defaultFilename()
                                ) { result in
                                    switch result {
                                    case .success(let url): exportResult = .success("Saved to \(url.lastPathComponent)", url)
                                    case .failure(let err): exportResult = .failure(err.localizedDescription)
                                    }
                                    csvDocument = nil
                                }
                            }
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up").font(.headline)
                        }

                        Spacer()
                    }
                    .frame(maxWidth: 340)
                }
                .padding(.horizontal, 24)

                Spacer(minLength: 24)
            }
        }
        .background(.background)
    }

    // 6.4: named after the environment, not just the preset — an MSP exporting
    // from three tenants back-to-back previously got three files all named
    // "device_report_all_2026-09-11" and had to rename them by hand to tell
    // them apart.
    private func defaultFilename() -> String {
        let date = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let envName = envStore.activeEnvironment?.name ?? "AxMJamfSync"
        // Strip characters that are invalid (or awkward) in a filename —
        // "/" and ":" can't appear at all on macOS, "\" just invites confusion.
        let safeEnvName = envName.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined()
        return "AxM-Jamf-Sync_\(safeEnvName)_\(selectedPreset.id)_\(date)"
    }
}

// MARK: - Export preset tile

private struct ExportPresetTile: View {
    let preset:     ExportPreset
    let isSelected: Bool
    let action:     () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(preset.color.opacity(isSelected ? 0.2 : 0.1))
                        .frame(width: 36, height: 36)
                    Image(systemName: preset.icon)
                        .font(.callout)
                        .foregroundStyle(preset.color)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.title)
                        .font(.callout).fontWeight(.medium)
                        .foregroundStyle(isSelected ? preset.color : .primary)
                    Text("^[\(preset.count) device](inflect: true)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(preset.color)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? preset.color.opacity(0.08) : Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? preset.color.opacity(0.5) : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Export column row
struct ExportColumnRow: View {
    @Binding var column: ExportColumn
    var body: some View {
        HStack {
            // 6.3: visual affordance for drag-to-reorder — macOS Lists with
            // .onMove are already draggable without it, but an unlabeled row
            // gives no hint that order is meaningful (and now persisted).
            Image(systemName: "line.3.horizontal")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Toggle(isOn: $column.enabled) {
                Text(column.label).font(.callout)
            }
            Spacer()
        }
        .padding(.vertical, 3).padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture { column.enabled.toggle() }
    }
}

// MARK: - Result banner
struct ExportResultBanner: View {
    let result:    ExportView.ExportResult
    let onDismiss: () -> Void

    var isSuccess: Bool { if case .success = result { return true }; return false }
    var message: String {
        switch result { case .success(let m, _): return m; case .failure(let m): return m }
    }
    var savedURL: URL? {
        if case .success(_, let url) = result { return url }
        return nil
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(isSuccess ? .green : .red)
            Text(message).font(.callout).foregroundStyle(isSuccess ? .green : .red)
            Spacer()
            if let savedURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([savedURL])
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            Button { onDismiss() } label: {
                Image(systemName: "xmark").font(.caption).foregroundStyle(.secondary)
            }.buttonStyle(.plain).help("Dismiss this message")
        }
        .padding(12)
        .background((isSuccess ? Color.green : Color.red).opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder((isSuccess ? Color.green : Color.red).opacity(0.3), lineWidth: 1))
    }
}

// MARK: - FileDocument
struct CSVDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.commaSeparatedText]
    private let csvData: Data
    init(csvData: Data) { self.csvData = csvData }
    init(configuration: ReadConfiguration) throws {
        self.csvData = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: csvData)
    }
}

// MARK: - Preview sheet
struct PreviewRowsSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let devices: [Device]

    private var enabledCols: [ExportColumn] { store.exportColumns.filter(\.enabled) }
    private var previewDevices: [Device] { Array(devices.prefix(5)) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Preview — First 5 Rows").font(.headline)
                Text("\(enabledCols.count) columns").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
            }.padding(16)
            Divider()
            if previewDevices.isEmpty {
                Text("No devices loaded.").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 0) {
                            ForEach(enabledCols) { col in
                                Text(col.label)
                                    .font(.system(size: 11, weight: .semibold))
                                    .padding(.horizontal, 8).padding(.vertical, 6)
                                    .frame(minWidth: 100, alignment: .leading)
                                    .background(.background.secondary)
                                Divider()
                            }
                        }
                        Divider()
                        ForEach(previewDevices) { device in
                            HStack(spacing: 0) {
                                ForEach(enabledCols) { col in
                                    let val = device.value(for: col.id) ?? ""
                                    Text(val.isEmpty ? "—" : val)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(val.isEmpty ? .secondary : .primary)
                                        .padding(.horizontal, 8).padding(.vertical, 5)
                                        .frame(minWidth: 100, alignment: .leading)
                                        .textSelection(.enabled)
                                    Divider()
                                }
                            }
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(minWidth: 700, minHeight: 320)
        .background(.background)
    }
}
