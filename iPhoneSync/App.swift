import AppKit
import Combine
import Foundation
import OSLog
import ServiceManagement
import SwiftUI

struct Phone: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    var address: String?
}

struct Mapping: Codable, Identifiable, Equatable {
    enum ScheduleMode: Hashable {
        case off, unlockedOnly, allowLocked
    }

    var id = UUID()
    var name = "新建同步"
    var phoneID = ""
    var phoneName = ""
    var directIP: String?
    var libraryPath = ""
    var scheduled = false
    var scheduledWhileLocked: Bool?
    var startMinute = 0
    var endMinute = 0
    var interval = 30
    // Optional on disk so tasks saved before adaptive scheduling still decode.
    var caughtUpIntervalHours: Int?
    var caughtUp: Bool?
    var batch = 10
    var useCustomStart = false
    var customStart = Calendar.current.startOfDay(for: Date())
    var lastAttempt: Date?

    var configured: Bool { !phoneID.isEmpty && !libraryPath.isEmpty }

    var scheduleMode: ScheduleMode {
        get {
            guard scheduled else { return .off }
            return scheduledWhileLocked == true ? .allowLocked : .unlockedOnly
        }
        set {
            scheduled = newValue != .off
            if scheduled { scheduledWhileLocked = newValue == .allowLocked }
        }
    }

    func includes(_ date: Date, calendar: Calendar = .current) -> Bool {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        if startMinute == endMinute { return true }
        if startMinute < endMinute { return (startMinute..<endMinute).contains(minute) }
        return minute >= startMinute || minute < endMinute
    }

    var checkIntervalHours: Int {
        get { caughtUpIntervalHours ?? 1 }
        set { caughtUpIntervalHours = newValue }
    }

    var nextAttempt: Date? {
        let seconds = caughtUp == true ? Double(checkIntervalHours) * 3600 : Double(interval) * 60
        return lastAttempt?.addingTimeInterval(seconds)
    }

    func isDue(_ date: Date, calendar: Calendar = .current) -> Bool {
        scheduled && configured && includes(date, calendar: calendar) &&
            (nextAttempt.map { date >= $0 } ?? true)
    }
}

struct Preferences: Codable {
    var mappings: [Mapping] = [Mapping()]
    var selection: UUID?
}

struct BatchProgress: Decodable {
    enum Phase: String, Decodable { case preview, transfer, `import`, complete, idle }

    let phase: Phase
    let total: Int
    let remaining: Int
    let batch: Int
    let attempted: Int?
    let imported: Int?
    let duplicates: Int?
    let retry: Int?

    var confirmsCaughtUp: Bool {
        remaining == 0 && (phase == .idle || (phase == .complete && retry == 0))
    }
}

private enum Backend {
    struct Output { let status: Int32; let log: String }

    static func run(_ arguments: [String], line: ((String) -> Void)? = nil) throws -> Output {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let bundledPython = Bundle.main.resourceURL?.appendingPathComponent("Python/bin/python3")
        let developmentPython = support.appendingPathComponent("iPhoneAlbumSync/runtime-v1/bin/python3")
        let python = bundledPython.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
            ?? developmentPython
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw NSError(domain: "WirelessPhotoSync", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到同步运行环境。请运行项目里的 build.sh 安装本机依赖。"])
        }
        guard let script = Bundle.main.url(forResource: "sync_backend", withExtension: "py") else {
            throw NSError(domain: "WirelessPhotoSync", code: 2, userInfo: [NSLocalizedDescriptionKey: "App 的同步资源不完整，请重新构建。"])
        }
        let process = Process()
        process.executableURL = python
        process.currentDirectoryURL = script.deletingLastPathComponent()
        process.arguments = ["-E", "-s", "-B", "-u", script.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(home.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        let pipe = Pipe()
        let importReplies = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = importReplies
        _ = fcntl(importReplies.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        defer { try? importReplies.fileHandleForWriting.close() }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + (arguments.first == "devices" ? 30 : 3600), execute: deadline)
        defer { deadline.cancel() }
        var rest = Data()
        var lines: [String] = []
        while true {
            let data = pipe.fileHandleForReading.availableData
            if data.isEmpty { break }
            rest.append(data)
            while let newline = rest.firstIndex(of: 10) {
                let entry = String(decoding: rest[..<newline], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                rest.removeSubrange(...newline)
                if entry.hasPrefix("@photokit ") {
                    let request = Data(entry.dropFirst("@photokit ".count).utf8)
                    try replyToImport(request, through: importReplies.fileHandleForWriting)
                } else if !entry.isEmpty {
                    lines.append(entry)
                    line?(entry)
                }
            }
        }
        if !rest.isEmpty { lines.append(String(decoding: rest, as: UTF8.self)) }
        process.waitUntilExit()
        return Output(status: process.terminationStatus, log: lines.joined(separator: "\n"))
    }

    private static func replyToImport(_ data: Data, through pipe: FileHandle) throws {
        var response: [String: Any]
        if let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            var failure: NSError?
            if let identifiers = ImportWithPhotoKit(request, &failure) {
                response = ["identifiers": identifiers]
            } else {
                response = [
                    "error": failure?.localizedDescription ?? "PhotoKit 未完成导入",
                    "domain": failure?.domain ?? "",
                    "code": failure?.code ?? 0
                ]
            }
        } else {
            response = ["error": "PhotoKit 导入请求无法解析"]
        }
        var reply = try JSONSerialization.data(withJSONObject: response)
        reply.append(10)
        try pipe.write(contentsOf: reply)
    }
}

@MainActor
final class SyncModel: ObservableObject {
    @Published private(set) var preferences: Preferences
    @Published private(set) var phones: [Phone] = []
    @Published private(set) var scanning = false
    @Published private(set) var running: UUID?
    @Published private var activity: [UUID: [String]] = [:]
    @Published private(set) var status: [UUID: String] = [:]
    @Published private(set) var progress: [UUID: BatchProgress] = [:]
    @Published private(set) var loginEnabled = false
    private var timer: Timer?
    private var listener: DeviceListener?
    @Published private var networkIDs = Set<String>()
    @Published private var listenerReady = false
    @Published private var dueIDs = Set<UUID>()
    private var listenerRetry: Date?
    private let schedulerLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "iphonealbumsync", category: "scheduler")
    private let folder: URL

    init() {
        folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iPhoneAlbumSync", isDirectory: true)
        let stored = folder.appendingPathComponent("preferences.json")
        if let data = try? Data(contentsOf: stored), let settings = try? JSONDecoder().decode(Preferences.self, from: data), !settings.mappings.isEmpty {
            preferences = settings
        } else {
            preferences = Preferences()
        }
        if preferences.selection == nil || !preferences.mappings.contains(where: { $0.id == preferences.selection }) {
            preferences.selection = preferences.mappings.first?.id
        }
        if #available(macOS 13.0, *) { loginEnabled = SMAppService.mainApp.status == .enabled }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(resumeSchedule),
            name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resumeSchedule),
            name: NSNotification.Name.NSSystemClockDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resumeSchedule),
            name: NSNotification.Name.NSSystemTimeZoneDidChange, object: nil)
        checkSchedule()
    }

    var selection: UUID? { preferences.selection }
    var selected: Mapping? { preferences.mappings.first { $0.id == selection } }
    var online: Bool {
        guard let selected else { return false }
        if listenerReady && selected.scheduled && selected.includes(Date()) { return networkIDs.contains(selected.phoneID) }
        return phones.contains { $0.id == selected.phoneID }
    }

    func displayStatus(_ mapping: Mapping) -> String {
        if running != mapping.id && dueIDs.contains(mapping.id) {
            if !listenerReady { return "正在等待设备监听就绪" }
            if !networkIDs.contains(mapping.phoneID) { return "等待 iPhone 上线" }
            if running != nil || scanning { return "设备已上线 · 等待同步" }
        }
        return status[mapping.id] ?? (mapping.configured ? "等待同步" : "选择设备和目标图库")
    }

    private func persist(for id: UUID?) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(preferences).write(to: folder.appendingPathComponent("preferences.json"), options: .atomic)
        } catch { append("设置保存失败 · \(error.localizedDescription)", for: id) }
    }

    func select(_ id: UUID?) {
        preferences.selection = id
        persist(for: id)
    }

    func add() {
        let mapping = Mapping()
        preferences.mappings.append(mapping)
        select(mapping.id)
    }

    func remove(_ id: UUID) {
        guard running == nil else { return }
        preferences.mappings.removeAll { $0.id == id }
        activity[id] = nil
        progress[id] = nil
        status[id] = nil
        if preferences.mappings.isEmpty { preferences.mappings = [Mapping()] }
        select(preferences.mappings.first?.id)
        checkSchedule()
    }

    func update(_ id: UUID, _ change: (inout Mapping) -> Void) {
        guard let index = preferences.mappings.firstIndex(where: { $0.id == id }) else { return }
        let original = preferences.mappings[index]
        change(&preferences.mappings[index])
        let updated = preferences.mappings[index]
        if original.phoneID != updated.phoneID || original.libraryPath != updated.libraryPath ||
            original.useCustomStart != updated.useCustomStart ||
            (updated.useCustomStart && original.customStart != updated.customStart) {
            preferences.mappings[index].caughtUp = nil
            preferences.mappings[index].lastAttempt = nil
            progress[id] = nil
            status[id] = nil
        }
        persist(for: id)
        if original != updated { checkSchedule() }
    }

    func activity(for id: UUID) -> [String] { activity[id] ?? [] }

    private func append(_ line: String, for id: UUID?) {
        guard let id, preferences.mappings.contains(where: { $0.id == id }),
              !line.hasPrefix("WARN `--no-project`"), !line.isEmpty else { return }
        let clock = Date.now.formatted(.dateTime.hour().minute().second())
        var lines = activity[id] ?? []
        lines.append("\(clock)  \(line)")
        if lines.count > 160 { lines.removeFirst(lines.count - 160) }
        activity[id] = lines
    }

    func scan(reportTo id: UUID? = nil) {
        guard !scanning, running == nil else { return }
        let owner = id ?? selection
        scanning = true
        Task.detached { [weak self] in
            do {
                let result = try Backend.run(["devices"])
                guard result.status == 0,
                      let last = result.log.split(separator: "\n").last,
                      let list = try? JSONDecoder().decode([Phone].self, from: Data(last.utf8)) else {
                    await self?.scanFinished([], error: result.log.isEmpty ? "设备搜索未返回，请确认 iPhone 和 Mac 在同一局域网后重试。" : result.log, reportTo: owner)
                    return
                }
                await self?.scanFinished(list, error: nil, reportTo: owner)
            } catch { await self?.scanFinished([], error: error.localizedDescription, reportTo: owner) }
        }
    }

    private func scanFinished(_ devices: [Phone], error: String?, reportTo id: UUID?) {
        scanning = false
        phones = devices
        for device in devices {
            if let address = device.address { rememberAddress(address, deviceID: device.id) }
        }
        if let error { append("设备搜索失败 · \(error)", for: id) }
        checkSchedule()
    }

    private func rememberAddress(_ address: String, deviceID: String) {
        guard !address.isEmpty else { return }
        let matches = preferences.mappings.indices.filter {
            preferences.mappings[$0].phoneID == deviceID && preferences.mappings[$0].directIP != address
        }
        guard !matches.isEmpty else { return }
        for index in matches { preferences.mappings[index].directIP = address }
        persist(for: selection)
    }

    func choosePhone(_ id: UUID, phoneID: String) {
        let device = phones.first { $0.id == phoneID }
        let label = device?.name ?? ""
        update(id) { mapping in
            if mapping.phoneID != phoneID {
                mapping.lastAttempt = nil
                mapping.directIP = device?.address
            }
            if mapping.name == "新建同步" || mapping.name == mapping.phoneName { mapping.name = label.isEmpty ? "新建同步" : label }
            mapping.phoneID = phoneID
            mapping.phoneName = label
        }
    }

    func chooseLibrary(_ id: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "选择要接收 iPhone 照片和视频的 Apple 照片图库。"
        panel.prompt = "使用此图库"
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard url.pathExtension.lowercased() == "photoslibrary" else {
                    self?.append("请选择 .photoslibrary 图库包。", for: id)
                    return
                }
                self?.update(id) { mapping in
                    if mapping.libraryPath != url.path { mapping.lastAttempt = nil }
                    mapping.libraryPath = url.path
                }
            }
        }
    }

    func setLogin(_ value: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval { append("请在「系统设置 → 登录项与扩展」允许此 App 启动。", for: selection) }
        } catch { append("登录启动设置失败 · \(error.localizedDescription)", for: selection) }
    }

    @objc private func resumeSchedule() {
        stopListening()
        checkSchedule()
    }

    private func stopListening() {
        listener?.stop()
        listener = nil
        listenerReady = false
        networkIDs = []
        listenerRetry = nil
    }

    private func startListening() {
        let monitor = DeviceListener(changed: { [weak self] ids in
            guard let self else { return }
            listenerReady = true
            networkIDs = ids
            checkSchedule()
        }, failed: { [weak self] reason in
            guard let self else { return }
            stopListening()
            listenerRetry = Date().addingTimeInterval(15)
            for task in preferences.mappings where task.scheduled && task.includes(Date()) {
                append("系统设备监听中断 · " + reason, for: task.id)
            }
            checkSchedule()
        })
        listener = monitor
        listenerRetry = nil
        monitor.start()
    }

    private func checkSchedule() {
        let now = Date()
        let scheduled = preferences.mappings.filter { $0.scheduled && $0.configured }
        let active = scheduled.filter { $0.includes(now) }
        let due = active.filter { $0.isDue(now) }
        let ids = Set(due.map(\.id))
        if dueIDs != ids { dueIDs = ids }
        if active.isEmpty {
            if listener != nil || listenerRetry != nil { stopListening() }
        } else if listener == nil && (listenerRetry ?? .distantPast) <= now {
            startListening()
        }

        // Only local deadlines use a timer. Device presence comes from the listen socket.
        var deadlines: [Date] = []
        let calendar = Calendar.current
        for task in scheduled {
            if task.startMinute != task.endMinute {
                let boundary = task.includes(now) ? task.endMinute : task.startMinute
                if let date = calendar.nextDate(after: now, matching: DateComponents(hour: boundary / 60,
                        minute: boundary % 60, second: 0), matchingPolicy: .nextTime) {
                    deadlines.append(date)
                }
            }
            if task.includes(now), let due = task.nextAttempt, due > now {
                deadlines.append(due)
            }
        }
        if let retry = listenerRetry { deadlines.append(retry) }
        timer?.invalidate()
        timer = nil
        if let date = deadlines.min() {
            let next = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.checkSchedule() }
            }
            timer = next
            RunLoop.main.add(next, forMode: .common)
        }

        guard listenerReady, running == nil, !scanning else { return }
        let available = due.filter { networkIDs.contains($0.phoneID) }
        if let task = available.min(by: { ($0.lastAttempt ?? .distantPast) < ($1.lastAttempt ?? .distantPast) }) {
            run(task, preview: false, automatic: true)
        }
    }

    func run(_ mapping: Mapping, preview: Bool, automatic: Bool = false) {
        guard running == nil, !scanning, mapping.configured else { return }
        running = mapping.id
        progress[mapping.id] = nil
        let allowLocked = mapping.scheduleMode == .allowLocked
        status[mapping.id] = allowLocked ? "正在连接 iPhone" : "正在检查 iPhone 解锁状态"
        if !preview {
            update(mapping.id) {
                $0.lastAttempt = Date()
                $0.caughtUp = nil
            }
        }
        if automatic {
            append("目标 iPhone 已上线 · 开始本轮", for: mapping.id)
            schedulerLog.info("Wireless device available, starting scheduled task \(mapping.id.uuidString, privacy: .public)")
        }
        append("\(automatic ? "定时" : "手动")\(preview ? "预览" : "同步") · \(mapping.name)", for: mapping.id)
        var arguments = ["sync", "--device", mapping.phoneID, "--library", mapping.libraryPath,
                         "--state", folder.appendingPathComponent("progress.sqlite").path, "--batch", String(mapping.batch),
                         "--progress"]
        if let address = mapping.directIP { arguments += ["--direct-ip", address] }
        if mapping.useCustomStart { arguments += ["--start", String(mapping.customStart.timeIntervalSince1970)] }
        if allowLocked { arguments.append("--allow-locked") }
        if preview { arguments.append("--preview") }
        let args = arguments
        Task.detached { [weak self] in
            var latest: BatchProgress?
            do {
                let result = try Backend.run(args) { entry in
                    if entry.hasPrefix("@progress ") {
                        guard let event = try? JSONDecoder().decode(BatchProgress.self, from: Data(entry.dropFirst(10).utf8)) else { return }
                        latest = event
                        DispatchQueue.main.async { [weak self] in self?.show(event, for: mapping.id) }
                    } else if entry.hasPrefix("@device-address ") {
                        let address = String(entry.dropFirst("@device-address ".count))
                        DispatchQueue.main.async { [weak self] in self?.rememberAddress(address, deviceID: mapping.phoneID) }
                    } else {
                        DispatchQueue.main.async { [weak self] in self?.append(entry, for: mapping.id) }
                    }
                }
                await self?.finished(mapping.id, exitStatus: result.status, preview: preview, latest: latest)
            } catch {
                await self?.append(error.localizedDescription, for: mapping.id)
                await self?.finished(mapping.id, exitStatus: 1, preview: preview, latest: latest)
            }
        }
    }

    private func show(_ event: BatchProgress, for id: UUID) {
        guard running == id else { return }
        progress[id] = event
        switch event.phase {
        case .preview: status[id] = "预览完成"
        case .transfer: status[id] = "正在通过 Wi-Fi 读取原片"
        case .import: status[id] = "正在核对并导入图库"
        case .complete: status[id] = (event.retry ?? 0) > 0 ? "本批有项目待重试" : "本批完成"
        case .idle: status[id] = event.remaining > 0 ? "等待重试" : "当前范围已核对完成"
        }
    }

    private func finished(_ id: UUID, exitStatus: Int32, preview: Bool, latest: BatchProgress?) {
        if let latest { show(latest, for: id) }
        if !preview, exitStatus == 0, latest?.confirmsCaughtUp == true {
            update(id) { $0.caughtUp = true }
            if let task = preferences.mappings.first(where: { $0.id == id }), task.scheduled {
                append("目录已追平 · 按每 \(task.checkIntervalHours) 小时检查", for: id)
            }
        }
        running = nil
        switch exitStatus {
        case 0:
            if latest == nil { status[id] = preview ? "预览完成" : "本批完成" }
        case 2:
            status[id] = "iPhone 已锁定 · 已停止拉取"
        case 3:
            status[id] = "无法确认 iPhone 已解锁 · 已停止拉取"
        default:
            status[id] = "未完成 · 查看日志"
        }
        schedulerLog.info("Finished task \(id.uuidString, privacy: .public), exit \(exitStatus), imported \(latest?.imported ?? 0), duplicates \(latest?.duplicates ?? 0), retry \(latest?.retry ?? 0)")
        checkSchedule()
    }
}

private struct LeadingFormRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 12) {
            configuration.label
                .frame(width: 92, alignment: .leading)
            configuration.content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct MainView: View {
    @ObservedObject var model: SyncModel
    @State private var removing: Mapping?

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { model.selection }, set: { model.select($0) })) {
                Section("同步任务") {
                    ForEach(model.preferences.mappings) { mapping in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mapping.name).lineLimit(1)
                                Text(mapping.libraryPath.isEmpty ? "待设置" : URL(fileURLWithPath: mapping.libraryPath).deletingPathExtension().lastPathComponent)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        } icon: {
                            Image(systemName: "iphone")
                        }
                        .tag(mapping.id)
                        .contextMenu { Button("移除同步任务", role: .destructive) { removing = mapping }.disabled(model.running != nil) }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) {
                Button { model.add() } label: { Label("新建同步", systemImage: "plus") }
                    .buttonStyle(.borderless).padding(.horizontal, 14).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            if let config = model.selected { detail(config) } else { ContentUnavailableView("请选择同步任务", systemImage: "iphone") }
        }
        .confirmationDialog("移除同步任务？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { mapping in
            Button("移除任务", role: .destructive) { model.remove(mapping.id); removing = nil }
        } message: { _ in Text("已导入的照片和视频会保留在图库中。") }
        .task {
            if !model.preferences.mappings.contains(where: { $0.scheduled && $0.configured && $0.includes(Date()) }) || model.selected?.phoneID.isEmpty == true {
                model.scan()
            }
        }
    }

    private func field<T>(_ config: Mapping, _ path: WritableKeyPath<Mapping, T>) -> Binding<T> {
        Binding(get: { model.preferences.mappings.first { $0.id == config.id }?[keyPath: path] ?? config[keyPath: path] },
                set: { value in model.update(config.id) { $0[keyPath: path] = value } })
    }

    private func clock(_ config: Mapping, _ path: WritableKeyPath<Mapping, Int>) -> Binding<Date> {
        Binding(get: {
            let value = field(config, path).wrappedValue
            return Calendar.current.date(bySettingHour: value / 60, minute: value % 60, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            field(config, path).wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        })
    }

    private func detail(_ config: Mapping) -> some View {
        let busy = model.running != nil || model.scanning
        let activity = model.activity(for: config.id)
        return VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(config.name).font(.system(size: 28, weight: .semibold))
                    Text(model.displayStatus(config))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if model.running == config.id { ProgressView().controlSize(.small) }
                Button("预览本批") { model.run(config, preview: true) }.disabled(!config.configured || busy)
                Button("同步一批") { model.run(config, preview: false) }
                    .buttonStyle(.borderedProminent).disabled(!config.configured || busy)
            }
            .padding(.horizontal, 25).padding(.vertical, 20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    if let progress = model.progress[config.id] { progressSection(progress) }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            LabeledContent("名称") {
                                TextField("同步任务名称", text: field(config, \.name)).frame(width: 230)
                            }
                            LabeledContent("iPhone") {
                                HStack(spacing: 8) {
                                    Picker("iPhone", selection: Binding(get: { config.phoneID }, set: { model.choosePhone(config.id, phoneID: $0) })) {
                                        Text(model.scanning ? "正在搜索…" : model.phones.isEmpty ? "未发现在线设备" : "请选择设备").tag("")
                                        if !config.phoneID.isEmpty && !model.phones.contains(where: { $0.id == config.phoneID }) {
                                            Text((config.phoneName.isEmpty ? "iPhone" : config.phoneName) + (model.online ? "" : " · 未发现")).tag(config.phoneID)
                                        }
                                        ForEach(model.phones) { phone in Text(phone.name).tag(phone.id) }
                                    }
                                    .labelsHidden()
                                    .fixedSize(horizontal: true, vertical: false)
                                    .accessibilityIdentifier("device-picker")
                                    Button { model.scan() } label: { Image(systemName: "arrow.clockwise") }
                                        .accessibilityLabel("刷新设备").help("搜索同一局域网中已配对的 iPhone").disabled(busy)
                                    HStack(spacing: 5) {
                                        Circle()
                                            .fill(model.online ? Color.green : Color.secondary.opacity(0.45))
                                            .frame(width: 7, height: 7)
                                            .accessibilityHidden(true)
                                        Text(config.phoneID.isEmpty ? "未选择设备" : model.online ? "在线" : "离线")
                                    }
                                    .fixedSize()
                                }.accessibilityElement(children: .contain)
                            }
                            LabeledContent("目标图库") {
                                HStack(spacing: 9) {
                                    Text(config.libraryPath.isEmpty ? "尚未选择" : config.libraryPath)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .help(config.libraryPath)
                                    Button("选择图库…") { model.chooseLibrary(config.id) }
                                        .fixedSize()
                                        .accessibilityIdentifier("choose-library")
                                }.accessibilityElement(children: .contain)
                            }
                            LabeledContent("备用 IP") {
                                Text(config.directIP ?? "Bonjour 连接后自动记录")
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .textSelection(.enabled)
                                    .help("前两种连接方式失败时，尝试上次验证过的 IP。")
                            }
                        }
                        .labeledContentStyle(LeadingFormRowStyle())
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } label: { Label("设备与图库", systemImage: "folder") }
                    .disabled(model.running != nil)

                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            LabeledContent("自动同步") {
                                Picker("自动同步", selection: field(config, \.scheduleMode)) {
                                    Text("关闭").tag(Mapping.ScheduleMode.off)
                                    Text("仅解锁时").tag(Mapping.ScheduleMode.unlockedOnly)
                                    Text("锁屏也同步").tag(Mapping.ScheduleMode.allowLocked)
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                                .fixedSize(horizontal: true, vertical: false)
                                .help("在指定时段监听设备上线。到期且设备在线时同步，每周期最多一批。选中「锁屏也同步」后，手动同步和预览也允许读取锁屏 iPhone。")
                                .disabled(!config.configured)
                            }
                            LabeledContent("每日时间段") {
                                HStack(spacing: 8) {
                                    DatePicker("开始", selection: clock(config, \.startMinute), displayedComponents: .hourAndMinute).labelsHidden().accessibilityLabel("开始时间")
                                    Text("至").foregroundStyle(.secondary)
                                    DatePicker("结束", selection: clock(config, \.endMinute), displayedComponents: .hourAndMinute).labelsHidden().accessibilityLabel("结束时间")
                                    if config.startMinute == config.endMinute {
                                        Text("全天").font(.caption).foregroundStyle(.secondary)
                                    }
                                }.help("开始和结束相同时表示全天，也可设置跨午夜的时间段")
                            }
                            LabeledContent("同步频率") {
                                Picker("同步频率", selection: field(config, \.interval)) {
                                    ForEach([5, 10, 15, 20, 30, 60, 120, 240], id: \.self) { Text("每 \($0) 分钟").tag($0) }
                                }.labelsHidden().frame(width: 135, alignment: .leading)
                            }
                            LabeledContent("追平后检查间隔") {
                                Picker("追平后检查间隔", selection: field(config, \.checkIntervalHours)) {
                                    ForEach([1, 3, 6, 12], id: \.self) { Text("每 \($0) 小时").tag($0) }
                                }.labelsHidden().frame(width: 135, alignment: .leading)
                            }
                            LabeledContent("每批项目") {
                                Picker("每批项目", selection: field(config, \.batch)) {
                                    ForEach([10, 20, 50, 100, 150], id: \.self) { Text("\($0) 项").tag($0) }
                                }.labelsHidden().frame(width: 135, alignment: .leading)
                            }
                            LabeledContent("首次同步起点") {
                                Picker("首次同步起点", selection: field(config, \.useCustomStart)) {
                                    Text("从图库最新项目开始").tag(false)
                                    Text("指定日期").tag(true)
                                }.labelsHidden().frame(width: 172, alignment: .leading)
                            }
                            if config.useCustomStart {
                                LabeledContent("起始日期") {
                                    DatePicker("起始日期", selection: field(config, \.customStart), displayedComponents: [.date, .hourAndMinute]).labelsHidden()
                                }
                            }
                            Toggle("登录时启动 App", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
                                .labeledContentStyle(.automatic)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .labeledContentStyle(LeadingFormRowStyle())
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } label: { Label("时间表", systemImage: "clock") }
                    .disabled(model.running != nil)

                    VStack(alignment: .leading, spacing: 8) {
                        Label("同步日志", systemImage: "text.alignleft").font(.headline)
                        if activity.isEmpty {
                            Text("预览或同步后，进度会显示在这里。").foregroundStyle(.secondary).font(.callout).padding(.vertical, 12)
                        } else {
                            ScrollViewReader { reader in
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 5) {
                                        ForEach(Array(activity.enumerated()), id: \.offset) { _, line in
                                            Text(line).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        Color.clear.frame(height: 1).id("latest")
                                    }.padding(10)
                                }.frame(height: 123)
                                .defaultScrollAnchor(.bottom)
                                .onChange(of: activity) { reader.scrollTo("latest", anchor: .bottom) }
                                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 7))
                            }
                            .id(config.id)
                            .font(.system(.caption, design: .monospaced))
                        }
                    }
                }.padding(24)
            }
        }
    }

    private func progressSection(_ progress: BatchProgress) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: progress.total > 0 ? Double(progress.total - progress.remaining) / Double(progress.total) : 1) {
                    HStack {
                        Text("已核对 \(progress.total - progress.remaining) / \(progress.total) 项")
                        Spacer()
                        Text("待核对 \(progress.remaining) 项").foregroundStyle(.secondary)
                    }
                }
                if progress.phase == .preview {
                    Text("下批可核对 \(progress.batch) 项 · 预览只读取目录")
                } else if let attempted = progress.attempted, progress.phase == .transfer {
                    ProgressView(value: Double(attempted), total: Double(progress.batch)) {
                        Text("本批读取 \(attempted) / \(progress.batch) 项")
                    }
                } else if progress.phase == .complete {
                    Text("本批新增 \(progress.imported ?? 0) · 重复 \(progress.duplicates ?? 0) · 待重试 \(progress.retry ?? 0)")
                }
            }.monospacedDigit().padding(9)
        } label: { Label("同步进度", systemImage: "arrow.triangle.2.circlepath") }
    }
}

struct StatusMenu: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: SyncModel
    var body: some View {
        Button("打开主窗口") {
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        if let selected = model.selected, selected.configured {
            Button("同步一批 · \(selected.name)") { model.run(selected, preview: false) }
                .disabled(model.running != nil || model.scanning)
        }
        Divider()
        Button("退出 iPhone 相册同步") { NSApp.terminate(nil) }.keyboardShortcut("q")
            .disabled(model.running != nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var isSyncing: () -> Bool = { false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        sender.setActivationPolicy(.accessory)
        return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isSyncing() ? .terminateCancel : .terminateNow
    }
}

@main @MainActor
struct iPhoneSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = SyncModel()
    var body: some Scene {
        Window("iPhone 相册同步", id: "main") {
            MainView(model: model).frame(minWidth: 720, idealWidth: 925, minHeight: 535, idealHeight: 745)
                .onAppear { NSApp.setActivationPolicy(.regular) }
                .task { [delegate, model] in delegate.isSyncing = { [weak model = model] in model?.running != nil } }
        }.defaultSize(width: 925, height: 745)
        MenuBarExtra("iPhone 相册同步", systemImage: model.running == nil ? "iphone" : "arrow.triangle.2.circlepath") {
            StatusMenu(model: model)
        }
    }
}
