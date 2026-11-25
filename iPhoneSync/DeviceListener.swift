import Foundation
import Network

/// Subscribes to the macOS usbmuxd plist stream on the main queue.
/// Listen replays currently attached devices, then reports subsequent changes.
final class DeviceListener {
    private let connection = NWConnection(to: .unix(path: "/var/run/usbmuxd"), using: .tcp)
    private let changed: (Set<String>) -> Void
    private let failed: (String) -> Void
    private var devices: [Int: String] = [:]
    private var stopped = false

    init(changed: @escaping (Set<String>) -> Void, failed: @escaping (String) -> Void) {
        self.changed = changed
        self.failed = failed
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !stopped else { return }
            switch state {
            case .ready: subscribe()
            case .failed(let error), .waiting(let error): fail(error.localizedDescription)
            default: break
            }
        }
        connection.start(queue: .main)
    }

    func stop() {
        stopped = true
        connection.cancel()
    }

    private func fail(_ message: String) {
        guard !stopped else { return }
        stop()
        failed(message)
    }

    private func subscribe() {
        do {
            let body = try PropertyListSerialization.data(fromPropertyList: [
                "MessageType": "Listen", "ProgName": "iPhoneAlbumSync", "kLibUSBMuxVersion": 3
            ], format: .xml, options: 0)
            // usbmuxd header: length including header, plist protocol, plist message, request tag.
            let header: [UInt32] = [UInt32(body.count + 16), 1, 8, 1]
            let packet = header.map(\.littleEndian).withUnsafeBytes { Data($0) } + body
            connection.send(content: packet, completion: .contentProcessed { [weak self] error in
                if let error { self?.fail(error.localizedDescription) }
                else { self?.readHeader() }
            })
        } catch { fail(error.localizedDescription) }
    }

    private func read(_ count: Int, then handle: @escaping (Data) -> Void) {
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { [weak self] data, _, _, error in
            guard let self, !stopped else { return }
            guard let data, data.count == count else {
                fail(error?.localizedDescription ?? "设备监听连接已关闭")
                return
            }
            handle(data)
        }
    }

    private func readHeader() {
        read(16) { [weak self] data in
            guard let self else { return }
            let size = data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
            guard size > 16, size <= 1024 * 1024 else { fail("设备监听消息长度异常"); return }
            read(size - 16) { [weak self] body in self?.receive(body) }
        }
    }

    private func receive(_ body: Data) {
        guard let packet = (try? PropertyListSerialization.propertyList(from: body, format: nil)) as? [String: Any],
              let type = packet["MessageType"] as? String else { fail("设备监听消息无法解析"); return }
        switch type {
        case "Result":
            guard packet["Number"] as? Int == 0 else { fail("系统拒绝设备监听"); return }
            changed([])
        case "Attached":
            if let id = packet["DeviceID"] as? Int, let props = packet["Properties"] as? [String: Any],
               props["ConnectionType"] as? String == "Network", let serial = props["SerialNumber"] as? String {
                devices[id] = serial
                changed(Set(devices.values))
            }
        case "Detached":
            if let id = packet["DeviceID"] as? Int, devices.removeValue(forKey: id) != nil {
                changed(Set(devices.values))
            }
        default: break
        }
        if !stopped { readHeader() }
    }
}
