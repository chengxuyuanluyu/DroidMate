import SwiftUI
import UniformTypeIdentifiers

/// Device app manager: search, launch, force-stop, install APK, uninstall.
struct AppManagerView: View {
    let serial: String

    @State private var apps: [AdbAppManager.AppInfo] = []
    @State private var query = ""
    @State private var scope: AdbAppManager.Scope = .thirdParty
    @State private var isLoading = false
    @State private var busyPackage: String?
    @State private var installProgress: String?
    @State private var statusMessage: String?
    @State private var uninstallTarget: AdbAppManager.AppInfo?
    @State private var clearDataTarget: AdbAppManager.AppInfo?
    @State private var showUninstallConfirm = false
    @State private var showClearConfirm = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    private var filteredApps: [AdbAppManager.AppInfo] {
        guard !query.isEmpty else { return apps }
        let q = query.lowercased()
        return apps.filter {
            $0.label.lowercased().contains(q) || $0.package.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchAndFilters
            Divider()
            content
            if let installProgress {
                Divider()
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(installProgress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            } else if let statusMessage {
                Divider()
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
        }
        .frame(minWidth: 560, minHeight: 440)
        .task { await loadApps() }
        .confirmationDialog(
            "Uninstall \"\(uninstallTarget?.label ?? "")\"?",
            isPresented: $showUninstallConfirm,
            titleVisibility: .visible
        ) {
            Button("Uninstall", role: .destructive) {
                if let app = uninstallTarget {
                    Task { await uninstall(app) }
                }
                uninstallTarget = nil
            }
            Button("Cancel", role: .cancel) { uninstallTarget = nil }
        } message: {
            Text("The app will be removed from your device.")
        }
        .confirmationDialog(
            "Clear data for \"\(clearDataTarget?.label ?? "")\"?",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear Data", role: .destructive) {
                if let app = clearDataTarget {
                    Task { await clearData(app) }
                }
                clearDataTarget = nil
            }
            Button("Cancel", role: .cancel) { clearDataTarget = nil }
        } message: {
            Text("App storage and cache will be wiped. The app stays installed.")
        }
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 12) {
            Text("Apps")
                .font(.headline)
            Spacer()
            Text("\(filteredApps.count)\(query.isEmpty ? "" : " / \(apps.count)")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button {
                pickAndInstallApk()
            } label: {
                Label("Install APK", systemImage: "plus.app")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(installProgress != nil)
            Button {
                Task { await loadApps() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isLoading)
            .help("Refresh list")
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    private var searchAndFilters: some View {
        VStack(spacing: 8) {
            HStack(spacing: 2) {
                Image(systemName: "magnifyingglass")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                TextField("Search by name or package", text: $query)
                    .textFieldStyle(.plain)
                    .controlSize(.small)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )

            Picker("Scope", selection: $scope) {
                Text("Third-party").tag(AdbAppManager.Scope.thirdParty)
                Text("All packages").tag(AdbAppManager.Scope.all)
            }
            .pickerStyle(.segmented)
            .onChange(of: scope) { _, _ in
                Task { await loadApps() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && apps.isEmpty {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredApps.isEmpty && !query.isEmpty {
            ContentUnavailableView(
                "No results",
                systemImage: "magnifyingglass",
                description: Text("No apps match \"\(query)\"")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if apps.isEmpty {
            ContentUnavailableView(
                "No apps",
                systemImage: "app.dashed",
                description: Text("No packages in this filter, or the device is offline.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(filteredApps) { app in
                appRow(app)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
            }
            .listStyle(.plain)
        }
    }

    private func appRow(_ app: AdbAppManager.AppInfo) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "app.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.label)
                    .font(.body)
                Text(app.package)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if busyPackage == app.package {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    Task { await launch(app) }
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderless)
                .help("Open \(app.label)")

                Button {
                    Task { await forceStop(app) }
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.borderless)
                .help("Force stop")

                Button(role: .destructive) {
                    uninstallTarget = app
                    showUninstallConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Uninstall")
            }
        }
        .contextMenu {
            Button("Open") { Task { await launch(app) } }
            Button("Force Stop") { Task { await forceStop(app) } }
            Divider()
            Button("Copy Package Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(app.package, forType: .string)
                statusMessage = String(localized: "Copied \(app.package)")
            }
            Button("Clear Data…", role: .destructive) {
                clearDataTarget = app
                showClearConfirm = true
            }
            Button("Uninstall…", role: .destructive) {
                uninstallTarget = app
                showUninstallConfirm = true
            }
        }
    }

    // MARK: - Actions

    private func loadApps() async {
        isLoading = true
        statusMessage = nil
        let s = serial
        let sc = scope
        // Fast path: packages + cached labels.
        apps = await Task.detached(priority: .userInitiated) {
            AdbAppManager.shared.listPackages(serial: s, scope: sc, resolveLabels: false)
        }.value
        apps.sort { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        isLoading = false

        // Slow path: dumpsys application labels (cached to disk after first hit).
        let packages = apps.map(\.package)
        let enriched = await Task.detached(priority: .utility) {
            AdbAppManager.shared.enrichLabels(serial: s, packages: packages)
            return AdbAppManager.shared.listPackages(serial: s, scope: sc, resolveLabels: false)
        }.value
        // Keep list stable if user switched scope mid-flight.
        guard scope == sc else { return }
        apps = enriched.sorted {
            $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }

    private func launch(_ app: AdbAppManager.AppInfo) async {
        await runBusy(app.package) {
            try AdbAppManager.shared.launchPackage(serial: serial, package: app.package)
        }
        statusMessage = String(localized: "Launched \(app.label)")
    }

    private func forceStop(_ app: AdbAppManager.AppInfo) async {
        await runBusy(app.package) {
            try AdbAppManager.shared.forceStopPackage(serial: serial, package: app.package)
        }
        statusMessage = String(localized: "Stopped \(app.label)")
    }

    private func uninstall(_ app: AdbAppManager.AppInfo) async {
        await runBusy(app.package) {
            try AdbAppManager.shared.uninstallPackage(serial: serial, package: app.package)
        }
        statusMessage = String(localized: "Uninstalled \(app.label)")
        await loadApps()
    }

    private func clearData(_ app: AdbAppManager.AppInfo) async {
        await runBusy(app.package) {
            try AdbAppManager.shared.clearPackageData(serial: serial, package: app.package)
        }
        statusMessage = String(localized: "Cleared data for \(app.label)")
    }

    private func runBusy(_ package: String, _ body: @escaping @Sendable () throws -> Void) async {
        busyPackage = package
        errorMessage = nil
        do {
            try await Task.detached(priority: .userInitiated) {
                try body()
            }.value
        } catch {
            errorMessage = error.localizedDescription
        }
        busyPackage = nil
    }

    private func pickAndInstallApk() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose an APK to install on the device")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await installApk(url: url) }
    }

    private func installApk(url: URL) async {
        installProgress = String(localized: "Installing \(url.lastPathComponent)…")
        errorMessage = nil
        statusMessage = nil
        let s = serial
        let path = url.path
        do {
            let out = try await Task.detached(priority: .userInitiated) {
                try AdbAppManager.shared.installApk(serial: s, localPath: path)
            }.value
            let summary = out.trimmingCharacters(in: .whitespacesAndNewlines)
            statusMessage = summary.isEmpty
                ? String(localized: "Installed \(url.lastPathComponent)")
                : summary
            await loadApps()
        } catch {
            errorMessage = error.localizedDescription
        }
        installProgress = nil
    }
}
