import Cocoa
import Carbon
import Darwin
import ServiceManagement
import SystemConfiguration

// MARK: - Localization (Auto-follows macOS system language: zh / en)

private enum L10n {
    static let isZH: Bool = {
        Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") ?? false
    }()

    static var noRecentRelay: String { isZH ? "暂无记录" : "None yet" }
    static var statusNeedAX: String {
        isZH ? "状态: ⚠ 需开启/刷新「辅助功能」权限" : "Status: ⚠ Accessibility Permission Required"
    }
    static var statusReceiverReady: String {
        isZH ? "状态: 接收端就绪 ✓（等待语音秒贴）" : "Status: Receiver Ready ✓ (Waiting for voice paste)"
    }
    static var statusSenderSearching: String {
        isZH ? "状态: 发射端等待中…（正在搜寻局域网接收端）" : "Status: Sender Waiting… (Searching LAN for receiver)"
    }
    static var roleSectionHeader: String {
        isZH ? "选择本机角色 / 目标设备:" : "Role / Target Mac:"
    }
    static var actAsReceiver: String {
        isZH ? "本机作为接收端（接收其他 Mac 语音并粘贴）" : "Act as Receiver (paste relayed text locally)"
    }
    static var noPeersFound: String {
        isZH ? "（暂未发现局域网内其他运行 TypelessRelay 的 Mac）" : "(No other Mac running TypelessRelay found on LAN)"
    }
    static var startAtLogin: String { isZH ? "开机自启" : "Start at Login" }
    static var refreshPeers: String { isZH ? "立即刷新局域网设备" : "Refresh LAN Devices" }
    static var openAXGranted: String {
        isZH ? "打开「辅助功能」权限设置（已授权 ✓）" : "Open Accessibility Settings (Granted ✓)"
    }
    static var openAXNeeded: String {
        isZH ? "⚠ 点击授权「辅助功能」权限…" : "⚠ Grant Accessibility Permission…"
    }
    static var quitApp: String { isZH ? "退出 TypelessRelay" : "Quit TypelessRelay" }

    static func statusSenderReady(name: String, ip: String, online: Bool) -> String {
        if isZH {
            let tag = online ? "在线" : "缓存直连"
            return "状态: 发射端就绪 ✓ → \(name) (\(ip) · \(tag))"
        } else {
            let tag = online ? "Online" : "Cached"
            return "Status: Sender Ready ✓ → \(name) (\(ip) · \(tag))"
        }
    }

    static func recentRelay(_ summary: String) -> String {
        isZH ? "最近接力: \(summary)" : "Last Relay: \(summary)"
    }

    static func sendToCached(name: String, ip: String) -> String {
        isZH ? "发射到 → \(name)  [已记忆 · \(ip)]" : "Send to → \(name)  [Saved · \(ip)]"
    }

    static func roleHint(isReceiver: Bool) -> String {
        if isZH { return isReceiver ? "接收端" : "发射端" }
        return isReceiver ? "Receiver" : "Sender"
    }

    static func sendToPeer(name: String, isReceiver: Bool, ip: String) -> String {
        let hint = roleHint(isReceiver: isReceiver)
        return isZH ? "发射到 → \(name)  [\(hint) · \(ip)]" : "Send to → \(name)  [\(hint) · \(ip)]"
    }

    static func sentSummary(name: String, preview: String) -> String {
        isZH ? "↗ 已发往 \(name): 「\(preview)」" : "↗ Sent to \(name): \"\(preview)\""
    }

    static func sendFailedSummary(name: String) -> String {
        isZH ? "✗ 发送到 \(name) 失败" : "✗ Failed to send to \(name)"
    }

    static func receivedSummary(name: String, preview: String) -> String {
        isZH ? "↙ 来自 \(name): 「\(preview)」" : "↙ From \(name): \"\(preview)\""
    }
}

// MARK: - Constants & Models

private enum Constants {
    static let bundleID = "xyz.spaceshuttle.typelessrelay"
    static let udpDiscoveryPort: UInt16 = 52972
    static let tcpBasePort: UInt16 = 52971
    static let stealthUserData: Int64 = 0x5459_5052 // "TYPR" magic tag
    static let transientPasteboardType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let typelessBundlePrefix = "now.typeless.desktop"

    /// Remote desktop / screen-mirroring viewers where Typeless synthetic Cmd+V drops its Command flag
    static let remoteViewerBundleIDs: Set<String> = [
        "com.apple.ScreenSharing",
        "com.astro-hq.LunaDisplayMac",
        "com.netease.uuremote",
        "com.apple.RemoteDesktop"
    ]

    static let prefDeviceID = "deviceID"
    static let prefRoleMode = "roleMode"          // "sender" | "receiver"
    static let prefTargetPeerID = "targetPeerID"
    static let prefTargetPeerName = "targetPeerName"
    static let prefTargetPeerIP = "targetPeerIP"
    static let prefTargetPeerPort = "targetPeerPort"
}

enum RoleMode: String {
    case receiver = "receiver"
    case sender = "sender"
}

struct PeerInfo {
    let id: String
    var name: String
    var ip: String
    var alternateIPs: [String]
    var tcpPort: UInt16
    var role: String
    var lastSeen: Date
}

private struct DiscoveryPacket: Codable {
    let op: String        // "ping" | "pong" | "bye"
    let id: String
    let name: String
    let tcpPort: UInt16
    let role: String
}

private struct RelayPayload: Codable {
    let type: String      // "paste" | "become_receiver"
    let fromName: String
    let text: String
    let html: String?
}

// MARK: - Lightweight Diagnostic Ring Logger (/tmp/typelessrelay.log)

private enum RelayLog {
    private static let path = "/tmp/typelessrelay.log"
    private static let queue = DispatchQueue(label: "xyz.spaceshuttle.typelessrelay.log", qos: .utility)
    private static let fmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func info(_ msg: String) {
        let ts = fmt.string(from: Date())
        let line = "[\(ts)] \(msg)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            let fm = FileManager.default
            if let attr = try? fm.attributesOfItem(atPath: path),
               let size = attr[.size] as? UInt64, size > 65536 {
                try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
                return
            }
            if !fm.fileExists(atPath: path) {
                try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            } else if let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
                defer { try? fh.close() }
                _ = try? fh.seekToEnd()
                try? fh.write(contentsOf: data)
            }
        }
    }
}

// MARK: - System & Keyboard Helpers

private func localComputerName() -> String {
    if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty {
        return name
    }
    return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
}

/// Resolve the virtual keycode for character 'v' in the active ASCII-capable layout (fallback: kVK_ANSI_V = 9)
private func currentVKeyCode() -> CGKeyCode {
    guard let src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
          let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else {
        return CGKeyCode(kVK_ANSI_V)
    }
    let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
    return data.withUnsafeBytes { rawBuf -> CGKeyCode in
        guard let layoutPtr = rawBuf.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
            return CGKeyCode(kVK_ANSI_V)
        }
        let kbdType = UInt32(LMGetKbdType())
        for code in UInt16(0)..<UInt16(128) {
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var actualLen: Int = 0
            let status = UCKeyTranslate(
                layoutPtr,
                code,
                UInt16(kUCKeyActionDown),
                0,
                kbdType,
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &actualLen,
                &chars
            )
            if status == noErr && actualLen == 1 && chars[0] == UniChar(0x76) {
                return CGKeyCode(code)
            }
        }
        return CGKeyCode(kVK_ANSI_V)
    }
}

// MARK: - Crisp Monochrome Menu-Bar Template Icon Renderer

private enum MenuBarIcon {
    enum VisualState {
        case senderConnected
        case senderSearching
        case receiverReady
        case warningPermission
    }

    static func make(state: VisualState) -> NSImage {
        let size = NSSize(width: 20, height: 18)
        let img = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setAllowsAntialiasing(true)
            ctx.setShouldAntialias(true)

            let fg = NSColor.black.cgColor
            ctx.setFillColor(fg)
            ctx.setStrokeColor(fg)

            let bars: [(x: CGFloat, h: CGFloat)] = [
                (1.5, 6.0),
                (5.0, 12.0),
                (8.5, 8.5)
            ]
            let barW: CGFloat = 2.0
            let midY: CGFloat = 9.0
            for b in bars {
                let rect = CGRect(x: b.x, y: midY - b.h / 2.0, width: barW, height: b.h)
                let p = CGPath(roundedRect: rect, cornerWidth: 1.0, cornerHeight: 1.0, transform: nil)
                ctx.addPath(p)
                ctx.fillPath()
            }

            switch state {
            case .senderConnected:
                ctx.setLineWidth(1.75)
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                ctx.move(to: CGPoint(x: 12.2, y: 6.2))
                ctx.addLine(to: CGPoint(x: 17.8, y: 11.8))
                ctx.move(to: CGPoint(x: 13.8, y: 11.8))
                ctx.addLine(to: CGPoint(x: 17.8, y: 11.8))
                ctx.addLine(to: CGPoint(x: 17.8, y: 7.8))
                ctx.strokePath()

            case .senderSearching:
                ctx.saveGState()
                ctx.setAlpha(0.45)
                ctx.setLineWidth(1.6)
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                ctx.move(to: CGPoint(x: 12.2, y: 6.2))
                ctx.addLine(to: CGPoint(x: 17.5, y: 11.5))
                ctx.strokePath()
                ctx.restoreGState()
                ctx.fillEllipse(in: CGRect(x: 15.2, y: 4.2, width: 3.0, height: 3.0))

            case .receiverReady:
                ctx.setLineWidth(1.75)
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                ctx.move(to: CGPoint(x: 17.8, y: 12.2))
                ctx.addLine(to: CGPoint(x: 12.6, y: 7.0))
                ctx.move(to: CGPoint(x: 12.6, y: 10.6))
                ctx.addLine(to: CGPoint(x: 12.6, y: 7.0))
                ctx.addLine(to: CGPoint(x: 16.2, y: 7.0))
                ctx.move(to: CGPoint(x: 12.3, y: 4.5))
                ctx.addLine(to: CGPoint(x: 18.0, y: 4.5))
                ctx.strokePath()

            case .warningPermission:
                let bar = CGRect(x: 14.3, y: 7.5, width: 2.2, height: 6.5)
                ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 1.1, cornerHeight: 1.1, transform: nil))
                ctx.fillPath()
                ctx.fillEllipse(in: CGRect(x: 14.2, y: 4.0, width: 2.4, height: 2.4))
            }

            return true
        }
        img.isTemplate = true
        return img
    }
}

// MARK: - LAN Discovery + Fast Multi-IP TCP Relay Engine

final class RelayNetworkEngine {
    let deviceID: String
    let deviceName: String
    private(set) var boundTCPPort: UInt16 = 0

    var roleProvider: (() -> RoleMode)?
    var seedPeerIPProvider: (() -> String?)?
    var onPeersUpdated: (([PeerInfo]) -> Void)?
    var onPayloadReceived: ((String, String, String?, String) -> Void)?

    private var tcpServerFD: Int32 = -1
    private var udpFD: Int32 = -1
    private let netQueue = DispatchQueue(label: "xyz.spaceshuttle.typelessrelay.net", qos: .userInteractive)
    private let peersLock = NSLock()
    private var peers: [String: PeerInfo] = [:]
    private var beaconTimer: DispatchSourceTimer?

    init(deviceID: String, deviceName: String) {
        self.deviceID = deviceID
        self.deviceName = deviceName
    }

    func start() {
        startTCPServer()
        startUDPDiscovery()
        startBeaconTimer()
        broadcastBeacon(op: "ping")
        netQueue.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.broadcastBeacon(op: "ping") }
        netQueue.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.broadcastBeacon(op: "ping") }
    }

    func stop() {
        broadcastBeacon(op: "bye")
        beaconTimer?.cancel()
        beaconTimer = nil
        if tcpServerFD >= 0 { close(tcpServerFD); tcpServerFD = -1 }
        if udpFD >= 0 { close(udpFD); udpFD = -1 }
    }

    func refreshNow() {
        pruneStalePeers()
        broadcastBeacon(op: "ping")
    }

    // MARK: TCP Server

    private func startTCPServer() {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

        var bound = false
        for candidate in Constants.tcpBasePort...(Constants.tcpBasePort + 15) {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = candidate.bigEndian
            addr.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)

            let bindRes = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bindRes == 0 {
                boundTCPPort = candidate
                bound = true
                break
            }
        }

        guard bound, listen(fd, 16) == 0 else {
            close(fd)
            RelayLog.info("ERROR: Failed to bind TCP server")
            return
        }
        tcpServerFD = fd
        RelayLog.info("TCP server listening on port \(boundTCPPort)")

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            while let self = self, self.tcpServerFD >= 0 {
                var clientAddr = sockaddr_in()
                var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        accept(fd, $0, &addrLen)
                    }
                }
                if clientFD < 0 { break }
                self.handleTCPClient(clientFD)
            }
        }
    }

    private func handleTCPClient(_ fd: Int32) {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            defer { close(fd) }
            var tv = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

            var data = Data()
            var buf = [UInt8](repeating: 0, count: 16384)
            while true {
                let n = recv(fd, &buf, buf.count, 0)
                if n > 0 {
                    data.append(buf, count: n)
                    if data.count > 4 * 1024 * 1024 { return }
                } else {
                    break
                }
            }

            guard let self = self,
                  !data.isEmpty,
                  let payload = try? JSONDecoder().decode(RelayPayload.self, from: data) else {
                return
            }

            let ack = Data("{\"ok\":true}".utf8)
            _ = ack.withUnsafeBytes { send(fd, $0.baseAddress, ack.count, 0) }

            if payload.type == "become_receiver" || (payload.type == "paste" && !payload.text.isEmpty) {
                RelayLog.info("TCP received type=\(payload.type) from=\(payload.fromName) chars=\(payload.text.count)")
                DispatchQueue.main.async {
                    self.onPayloadReceived?(payload.type, payload.text, payload.html, payload.fromName)
                }
            }
        }
    }

    // MARK: TCP Client (Tries primary IP + any alternate LAN IPs)

    func sendControl(type: String, to peer: PeerInfo) {
        sendRawPayload(RelayPayload(type: type, fromName: deviceName, text: "", html: nil), to: peer) { _ in }
    }

    func sendPaste(text: String, html: String?, to peer: PeerInfo, completion: @escaping (Bool) -> Void) {
        let payload = RelayPayload(type: "paste", fromName: deviceName, text: text, html: html)
        sendRawPayload(payload, to: peer, completion: completion)
    }

    private func sendRawPayload(_ payload: RelayPayload, to peer: PeerInfo, completion: @escaping (Bool) -> Void) {
        guard let body = try? JSONEncoder().encode(payload) else {
            completion(false)
            return
        }

        var candidateIPs: [String] = [peer.ip]
        for alt in peer.alternateIPs where !candidateIPs.contains(alt) {
            candidateIPs.append(alt)
        }

        DispatchQueue.global(qos: .userInteractive).async {
            for ip in candidateIPs where !ip.isEmpty {
                if Self.sendTCPOnce(body: body, ip: ip, port: peer.tcpPort) {
                    DispatchQueue.main.async { completion(true) }
                    return
                }
            }
            DispatchQueue.main.async { completion(false) }
        }
    }

    private static func sendTCPOnce(body: Data, ip: String, port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 1, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return false }

        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard connected else { return false }

        let sent = body.withUnsafeBytes { rawBuf -> Bool in
            guard let base = rawBuf.baseAddress else { return false }
            var offset = 0
            while offset < body.count {
                let n = send(fd, base.advanced(by: offset), body.count - offset, 0)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        shutdown(fd, SHUT_WR)
        return sent
    }

    // MARK: UDP Peer Discovery (Per-Interface Broadcast + Unicast Keepalive)

    private func startUDPDiscovery() {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Constants.udpDiscoveryPort.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)

        let bindRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRes == 0 else {
            close(fd)
            RelayLog.info("ERROR: Failed to bind UDP port \(Constants.udpDiscoveryPort)")
            return
        }
        udpFD = fd

        DispatchQueue.global(qos: .utility).async { [weak self] in
            var buf = [UInt8](repeating: 0, count: 2048)
            while let self = self, self.udpFD >= 0 {
                var srcAddr = sockaddr_in()
                var srcLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &srcAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, &buf, buf.count, 0, $0, &srcLen)
                    }
                }
                if n <= 0 { break }
                let packetData = Data(bytes: buf, count: n)
                var ipChars = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var sinAddr = srcAddr.sin_addr
                guard inet_ntop(AF_INET, &sinAddr, &ipChars, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
                let senderIP = String(cString: ipChars)
                // Ignore fake-IP / proxy TUN virtual range (198.18.0.0/15)
                if senderIP.hasPrefix("198.18.") || senderIP.hasPrefix("198.19.") { continue }
                self.handleUDPPacket(packetData, fromIP: senderIP)
            }
        }
    }

    private func handleUDPPacket(_ data: Data, fromIP: String) {
        guard let pkt = try? JSONDecoder().decode(DiscoveryPacket.self, from: data),
              pkt.id != deviceID else { return }

        var changed = false
        peersLock.lock()
        if pkt.op == "bye" {
            if peers.removeValue(forKey: pkt.id) != nil { changed = true }
        } else if pkt.tcpPort > 0 {
            let old = peers[pkt.id]
            var ipSet: Set<String> = [fromIP]
            if let prev = old {
                ipSet.insert(prev.ip)
                for a in prev.alternateIPs { ipSet.insert(a) }
            }
            // Deterministic IP ordering across multi-NIC setups (e.g. Ethernet + Wi-Fi) to avoid primary-IP flapping
            let sortedIPs = ipSet.sorted {
                if $0.count != $1.count { return $0.count < $1.count }
                return $0 < $1
            }
            let primaryIP = sortedIPs.first ?? fromIP
            let alts = Array(sortedIPs.dropFirst())
            let updated = PeerInfo(
                id: pkt.id,
                name: pkt.name,
                ip: primaryIP,
                alternateIPs: alts,
                tcpPort: pkt.tcpPort,
                role: pkt.role,
                lastSeen: Date()
            )
            peers[pkt.id] = updated
            if old == nil || old?.name != updated.name || old?.ip != updated.ip || old?.alternateIPs != updated.alternateIPs || old?.tcpPort != updated.tcpPort || old?.role != updated.role {
                changed = true
                RelayLog.info("Peer updated: \(updated.name) @ \(updated.ip) (alts=\(updated.alternateIPs)):\(updated.tcpPort) role=\(updated.role)")
            }
        }
        let snapshot = peers.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        peersLock.unlock()

        if pkt.op == "ping" {
            sendUnicastPong(toIP: fromIP)
        }
        if changed {
            DispatchQueue.main.async { [weak self] in
                self?.onPeersUpdated?(snapshot)
            }
        }
    }

    private func makeBeaconData(op: String) -> Data? {
        let role = roleProvider?().rawValue ?? RoleMode.receiver.rawValue
        let pkt = DiscoveryPacket(op: op, id: deviceID, name: deviceName, tcpPort: boundTCPPort, role: role)
        return try? JSONEncoder().encode(pkt)
    }

    private func sendUnicastPong(toIP ip: String) {
        guard udpFD >= 0, let data = makeBeaconData(op: "pong") else { return }
        sendUDP(data, toIP: ip, port: Constants.udpDiscoveryPort, interfaceIndex: 0)
    }

    func broadcastBeacon(op: String) {
        netQueue.async { [weak self] in
            guard let self = self, self.udpFD >= 0, let data = self.makeBeaconData(op: op) else { return }

            // 1. Bind IP_BOUND_IF per physical interface (en0/en1...) so proxy TUN default routes never swallow LAN broadcasts
            for (ifIndex, bcastIP) in Self.localPhysicalBroadcastTargets() {
                self.sendUDP(data, toIP: bcastIP, port: Constants.udpDiscoveryPort, interfaceIndex: ifIndex)
            }

            // 2. Also send direct unicast heartbeats to known peers in case Wi-Fi drops subnet broadcasts
            var unicastTargets: Set<String> = []
            self.peersLock.lock()
            for p in self.peers.values {
                unicastTargets.insert(p.ip)
                for alt in p.alternateIPs { unicastTargets.insert(alt) }
            }
            self.peersLock.unlock()
            if let seedIP = self.seedPeerIPProvider?(), !seedIP.isEmpty {
                unicastTargets.insert(seedIP)
            }
            for ip in unicastTargets {
                self.sendUDP(data, toIP: ip, port: Constants.udpDiscoveryPort, interfaceIndex: 0)
            }
        }
    }

    private func sendUDP(_ data: Data, toIP ip: String, port: UInt16, interfaceIndex: UInt32) {
        let fd: Int32
        let shouldClose: Bool
        if interfaceIndex > 0 {
            fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { return }
            shouldClose = true
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
            var idx = interfaceIndex
            setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &idx, socklen_t(MemoryLayout<UInt32>.size))
        } else {
            guard udpFD >= 0 else { return }
            fd = udpFD
            shouldClose = false
        }
        defer { if shouldClose { close(fd) } }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return }
        data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            _ = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, base, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func startBeaconTimer() {
        let t = DispatchSource.makeTimerSource(queue: netQueue)
        t.schedule(deadline: .now() + 3.0, repeating: 3.0)
        t.setEventHandler { [weak self] in
            self?.pruneStalePeers()
            self?.broadcastBeacon(op: "ping")
        }
        t.resume()
        beaconTimer = t
    }

    private func pruneStalePeers() {
        let now = Date()
        var changed = false
        peersLock.lock()
        for (id, p) in peers where now.timeIntervalSince(p.lastSeen) > 45.0 {
            peers.removeValue(forKey: id)
            changed = true
            RelayLog.info("Peer timed out (>45s): \(p.name)")
        }
        let snapshot = peers.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        peersLock.unlock()
        if changed {
            DispatchQueue.main.async { [weak self] in
                self?.onPeersUpdated?(snapshot)
            }
        }
    }

    private static func localPhysicalBroadcastTargets() -> [(UInt32, String)] {
        var result: [(UInt32, String)] = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return result }
        defer { freeifaddrs(first) }

        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cur?.pointee {
            defer { cur = ifa.ifa_next }
            let flags = Int32(ifa.ifa_flags)
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  let namePtr = ifa.ifa_name,
                  let addr = ifa.ifa_addr,
                  addr.pointee.sa_family == sa_family_t(AF_INET),
                  let mask = ifa.ifa_netmask else { continue }

            let ifName = String(cString: namePtr)
            if ifName.hasPrefix("utun") || ifName.hasPrefix("lo") { continue }
            let ifIndex = if_nametoindex(namePtr)

            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let bcast = ip | ~netmask
            var bcastAddr = in_addr(s_addr: bcast)
            var chars = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            if inet_ntop(AF_INET, &bcastAddr, &chars, socklen_t(INET_ADDRSTRLEN)) != nil {
                let s = String(cString: chars)
                if !s.hasPrefix("198.18.") && !s.hasPrefix("198.19.") && !s.hasPrefix("169.254.") {
                    result.append((ifIndex, s))
                }
            }
        }
        return result
    }
}

// MARK: - Pasteboard Archiver & Clean 4-Step Local Paster (Receiver Side)

private struct ArchivedItem {
    let payloads: [(NSPasteboard.PasteboardType, Data)]
}

enum LocalPasteExecutor {
    private static func archivePasteboard(_ pb: NSPasteboard) -> [ArchivedItem] {
        guard let items = pb.pasteboardItems else { return [] }
        var archived: [ArchivedItem] = []
        for item in items {
            if item.types.contains(Constants.transientPasteboardType) { continue }
            var pairs: [(NSPasteboard.PasteboardType, Data)] = []
            for t in item.types {
                if let d = item.data(forType: t) {
                    pairs.append((t, d))
                }
            }
            if !pairs.isEmpty {
                archived.append(ArchivedItem(payloads: pairs))
            }
        }
        return archived
    }

    private static func restorePasteboard(_ pb: NSPasteboard, from archived: [ArchivedItem]) {
        pb.clearContents()
        guard !archived.isEmpty else { return }
        var restored: [NSPasteboardItem] = []
        for entry in archived {
            let item = NSPasteboardItem()
            for (t, d) in entry.payloads {
                item.setData(d, forType: t)
            }
            restored.append(item)
        }
        pb.writeObjects(restored)
    }

    static func paste(text: String, html: String?) {
        let pb = NSPasteboard.general
        let saved = archivePasteboard(pb)

        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if let html = html, !html.isEmpty {
            item.setString(html, forType: .html)
        }
        item.setData(Data(), forType: Constants.transientPasteboardType)
        pb.writeObjects([item])
        let expectedChangeCount = pb.changeCount

        let vKey = currentVKeyCode()
        // Wait 15ms for pasteboardd IPC commit, then send full 4-step Cmd-down -> V-down -> V-up -> Cmd-up
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) {
            let src = CGEventSource(stateID: .combinedSessionState)
            let cmdKey: CGKeyCode = 55
            if let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: cmdKey, keyDown: true) {
                cmdDown.flags = .maskCommand
                cmdDown.post(tap: .cghidEventTap)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.008) {
                if let vDown = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true),
                   let vUp = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false) {
                    vDown.flags = .maskCommand
                    vUp.flags = .maskCommand
                    vDown.post(tap: .cghidEventTap)
                    vUp.post(tap: .cghidEventTap)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.008) {
                    if let cmdUp = CGEvent(keyboardEventSource: src, virtualKey: cmdKey, keyDown: false) {
                        cmdUp.flags = []
                        cmdUp.post(tap: .cghidEventTap)
                    }
                    RelayLog.info("Local paste executed (chars=\(text.count), vKey=\(vKey))")
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) {
                if pb.changeCount == expectedChangeCount {
                    restorePasteboard(pb, from: saved)
                }
            }
        }
    }
}

// MARK: - AppDelegate (UI + HID-Tail CGEventTap Interceptor)

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var net: RelayNetworkEngine!
    private var eventTap: CFMachPort?
    private var activeTapLocationName: String = "none"
    private var isMenuOpen: Bool = false

    private var roleMode: RoleMode = .receiver
    private var targetPeerID: String?
    private var targetPeerName: String?
    private var targetPeerIP: String?
    private var targetPeerPort: UInt16 = Constants.tcpBasePort
    private var discoveredPeers: [PeerInfo] = []

    private var swallowedKeyCode: Int64 = -1
    private var swallowTimestamp: CFAbsoluteTime = 0
    private var lastInterceptTime: CFAbsoluteTime = 0
    private var lastRelaySummary: String = L10n.noRecentRelay
    private var typelessPIDs: Set<pid_t> = []
    private var lastNonTypelessBundleID: String = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        let myPID = ProcessInfo.processInfo.processIdentifier
        let myBundleID = Bundle.main.bundleIdentifier ?? Constants.bundleID

        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == myBundleID && app.processIdentifier != myPID {
            if args.contains("--replace") {
                app.terminate()
                usleep(200_000)
            } else {
                NSApp.terminate(nil)
                return
            }
        }

        let defaults = UserDefaults.standard
        let devID: String
        if let saved = defaults.string(forKey: Constants.prefDeviceID), !saved.isEmpty {
            devID = saved
        } else {
            devID = UUID().uuidString
            defaults.set(devID, forKey: Constants.prefDeviceID)
        }

        refreshRunningAppState()

        let compName = localComputerName()
        if let savedRole = defaults.string(forKey: Constants.prefRoleMode),
           let parsed = RoleMode(rawValue: savedRole) {
            roleMode = parsed
        } else {
            // Generic first-launch heuristic: if Typeless is actively running here, default to Sender; otherwise Receiver
            roleMode = !typelessPIDs.isEmpty ? .sender : .receiver
            defaults.set(roleMode.rawValue, forKey: Constants.prefRoleMode)
        }
        targetPeerID = defaults.string(forKey: Constants.prefTargetPeerID)
        targetPeerName = defaults.string(forKey: Constants.prefTargetPeerName)
        targetPeerIP = defaults.string(forKey: Constants.prefTargetPeerIP)
        let savedPort = defaults.integer(forKey: Constants.prefTargetPeerPort)
        if savedPort > 0 && savedPort <= 65535 {
            targetPeerPort = UInt16(savedPort)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let axTrusted = AXIsProcessTrusted()
        RelayLog.info("Launching TypelessRelay v1.2 on \(compName) role=\(roleMode.rawValue) axTrusted=\(axTrusted)")
        if !axTrusted {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }

        observeWorkspaceApps()

        net = RelayNetworkEngine(deviceID: devID, deviceName: compName)
        net.roleProvider = { [weak self] in self?.roleMode ?? .receiver }
        net.seedPeerIPProvider = { [weak self] in self?.targetPeerIP }
        net.onPeersUpdated = { [weak self] peers in
            guard let self = self else { return }
            self.discoveredPeers = peers
            self.autoBindTargetPeerIfNeeded()
            self.rebuildMenuAndIcon()
        }
        net.onPayloadReceived = { [weak self] msgType, text, html, fromName in
            guard let self = self else { return }
            if self.roleMode != .receiver {
                self.roleMode = .receiver
                UserDefaults.standard.set(RoleMode.receiver.rawValue, forKey: Constants.prefRoleMode)
                self.net.broadcastBeacon(op: "ping")
            }
            if msgType == "paste" && !text.isEmpty {
                LocalPasteExecutor.paste(text: text, html: html)
                let preview = Self.shortPreview(text)
                self.lastRelaySummary = L10n.receivedSummary(name: fromName, preview: preview)
            }
            self.rebuildMenuAndIcon()
        }
        net.start()

        setupEventTapIfNeeded()
        rebuildMenuAndIcon()

        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.refreshRunningAppState()
            self.setupEventTapIfNeeded()
            if !self.isMenuOpen {
                self.rebuildMenuAndIcon()
            }
        }

        // Periodically keep Typeless remote-viewer whitelist self-healed on the sender Mac
        ensureTypelessWhitelistIfSender()
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.ensureTypelessWhitelistIfSender()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        net?.stop()
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    // MARK: Typeless Interactive-Card Whitelist Self-Healer (Sender Side)

    private func ensureTypelessWhitelistIfSender() {
        guard roleMode == .sender else { return }
        let path = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Typeless/app-storage.json")
        let fm = FileManager.default
        guard fm.fileExists(atPath: path),
              let raw = try? Data(contentsOf: URL(fileURLWithPath: path)),
              var root = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else { return }

        var acc = (root["accessibilityConfig"] as? [String: Any]) ?? [:]
        var data = (acc["data"] as? [String: Any]) ?? [:]
        var whitelist = (data["app_whitelist"] as? [String: Any]) ?? [:]
        var macosWL = (whitelist["macos"] as? [String: Any]) ?? [:]
        var exact = (macosWL["exact"] as? [String]) ?? []

        let defaultMacOSWhitelist = [
            "com.todesktop.230313mzl4w4u92",
            "com.tinyspeck.slackmacgap",
            "com.apple.mail",
            "com.figma.Desktop",
            "com.openai.atlas",
            "com.conductor.app",
            "com.github.wez.wezterm",
            "org.mozilla.thunderbird",
            "jp.naver.line.mac"
        ]

        var modified = false
        for bid in defaultMacOSWhitelist + Array(Constants.remoteViewerBundleIDs) where !exact.contains(bid) {
            exact.append(bid)
            modified = true
        }
        if (data["version"] as? String) != "99.0.0" {
            data["version"] = "99.0.0"
            modified = true
        }
        if !((acc["syncTime"] as? String)?.hasPrefix("2099-") ?? false) {
            acc["syncTime"] = "2099-12-31T23:59:59.000Z"
            modified = true
        }
        guard modified else { return }

        let bakPath = path + ".bak"
        if !fm.fileExists(atPath: bakPath) {
            try? fm.copyItem(atPath: path, toPath: bakPath)
        }

        macosWL["exact"] = exact
        if macosWL["regex"] == nil { macosWL["regex"] = [String]() }
        whitelist["macos"] = macosWL
        if whitelist["windows"] == nil { whitelist["windows"] = ["exact": [String](), "regex": [String]()] }
        data["app_whitelist"] = whitelist

        if data["app_blacklist"] == nil {
            data["app_blacklist"] = [
                "macos": ["exact": ["com.sublimetext.4", "com.tencent.xinWeChat", "com.alibaba.DingTalkMac", "com.microsoft.Excel", "com.kingsoft.wpsoffice.mac", "dev.zed.Zed", "com.meta.endo"], "regex": [String]()],
                "windows": ["exact": [String](), "regex": [String]()]
            ]
        }
        if data["url_blacklist"] == nil {
            data["url_blacklist"] = ["exact": [String](), "prefix": ["https://docs.google.com/document/d", "https://docs.qq.com/doc/", "https://docs.qq.com/sheet/"], "domain": [String](), "regex": [String]()]
        }
        if data["url_whitelist"] == nil {
            data["url_whitelist"] = ["exact": [String](), "prefix": ["https://www.figma.com/design/"], "domain": [String](), "regex": [String]()]
        }

        acc["data"] = data
        root["accessibilityConfig"] = acc

        if let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted]),
           (try? out.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil {
            RelayLog.info("Self-healed Typeless remote-viewer whitelist in app-storage.json")
        }
    }

    // MARK: Workspace & Typeless PID Tracking

    private func refreshRunningAppState() {
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           !front.isEmpty,
           !front.hasPrefix(Constants.typelessBundlePrefix) {
            lastNonTypelessBundleID = front
        }

        var pids: Set<pid_t> = []
        for app in NSWorkspace.shared.runningApplications {
            let bid = app.bundleIdentifier ?? ""
            let lname = app.localizedName ?? ""
            if bid.hasPrefix(Constants.typelessBundlePrefix) || lname.hasPrefix("Typeless") {
                pids.insert(app.processIdentifier)
            }
        }
        typelessPIDs = pids
    }

    private func isTypelessProcess(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if typelessPIDs.contains(pid) { return true }
        if let app = NSRunningApplication(processIdentifier: pid) {
            let bid = app.bundleIdentifier ?? ""
            let lname = app.localizedName ?? ""
            if bid.hasPrefix(Constants.typelessBundlePrefix) || lname.hasPrefix("Typeless") {
                typelessPIDs.insert(pid)
                return true
            }
        }
        return false
    }

    private func currentEffectiveFrontmostBundleID() -> String {
        let live = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        if !live.isEmpty && !live.hasPrefix(Constants.typelessBundlePrefix) {
            lastNonTypelessBundleID = live
            return live
        }
        return lastNonTypelessBundleID
    }

    private func observeWorkspaceApps() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self = self else { return }
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               let bid = app.bundleIdentifier,
               !bid.isEmpty,
               !bid.hasPrefix(Constants.typelessBundlePrefix) {
                self.lastNonTypelessBundleID = bid
            } else {
                self.refreshRunningAppState()
            }
        }
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshRunningAppState()
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshRunningAppState()
        }
    }

    // MARK: Resilient Peer Selection

    private var activeTargetPeer: PeerInfo? {
        if let tid = targetPeerID, let match = discoveredPeers.first(where: { $0.id == tid }) {
            return match
        }
        if let tname = targetPeerName, let match = discoveredPeers.first(where: { $0.name == tname }) {
            return match
        }
        if let first = discoveredPeers.first {
            return first
        }
        if let savedIP = targetPeerIP, !savedIP.isEmpty {
            return PeerInfo(
                id: targetPeerID ?? "cached",
                name: targetPeerName ?? savedIP,
                ip: savedIP,
                alternateIPs: [],
                tcpPort: targetPeerPort,
                role: RoleMode.receiver.rawValue,
                lastSeen: Date.distantPast
            )
        }
        return nil
    }

    private func persistTargetPeer(_ peer: PeerInfo) {
        targetPeerID = peer.id
        targetPeerName = peer.name
        targetPeerIP = peer.ip
        targetPeerPort = peer.tcpPort
        let defaults = UserDefaults.standard
        defaults.set(peer.id, forKey: Constants.prefTargetPeerID)
        defaults.set(peer.name, forKey: Constants.prefTargetPeerName)
        defaults.set(peer.ip, forKey: Constants.prefTargetPeerIP)
        defaults.set(Int(peer.tcpPort), forKey: Constants.prefTargetPeerPort)
    }

    private func autoBindTargetPeerIfNeeded() {
        if let tid = targetPeerID, let match = discoveredPeers.first(where: { $0.id == tid }) {
            persistTargetPeer(match)
            return
        }
        if let tname = targetPeerName, let match = discoveredPeers.first(where: { $0.name == tname }) {
            persistTargetPeer(match)
            return
        }
        if let first = discoveredPeers.first {
            persistTargetPeer(first)
        }
    }

    // MARK: Active CGEventTap (Tail of kCGHIDEventTap: Downstream of Typeless, Upstream of RFBEventHelperd)

    private func setupEventTapIfNeeded() {
        let trusted = AXIsProcessTrusted()
        if !trusted {
            if let existing = eventTap {
                CFMachPortInvalidate(existing)
                eventTap = nil
                RelayLog.info("Accessibility revoked; invalidated eventTap")
            }
            return
        }
        guard eventTap == nil else { return }

        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        let callback: CGEventTapCallBack = { (_, type, event, refcon) in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                RelayLog.info("EventTap disabled (type=\(type.rawValue)); re-enabling immediately")
                if let tap = me.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            if event.getIntegerValueField(.eventSourceUserData) == Constants.stealthUserData {
                return nil
            }

            guard me.roleMode == .sender else {
                return Unmanaged.passUnretained(event)
            }

            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

            if type == .keyUp {
                if keyCode == me.swallowedKeyCode && (CFAbsoluteTimeGetCurrent() - me.swallowTimestamp) < 1.0 {
                    me.swallowedKeyCode = -1
                    return nil
                }
                return Unmanaged.passUnretained(event)
            }

            guard type == .keyDown, event.flags.contains(.maskCommand) else {
                return Unmanaged.passUnretained(event)
            }

            let frontBundle = me.currentEffectiveFrontmostBundleID()
            guard Constants.remoteViewerBundleIDs.contains(frontBundle) else {
                return Unmanaged.passUnretained(event)
            }

            // Identify synthetic paste from Typeless via kernel eventSourceUnixProcessID (0 for physical keyboards)
            let srcPID = pid_t(event.getIntegerValueField(.eventSourceUnixProcessID))
            let stateID = event.getIntegerValueField(.eventSourceStateID)
            let pb = NSPasteboard.general
            let hasTransient = pb.types?.contains(Constants.transientPasteboardType) ?? false
            let fromTypeless = me.isTypelessProcess(srcPID) || (srcPID == 0 && stateID == 0 && hasTransient)

            guard fromTypeless else {
                return Unmanaged.passUnretained(event)
            }

            guard let peer = me.activeTargetPeer else {
                RelayLog.info("WARN: Typeless paste detected in \(frontBundle) but no target peer configured")
                return Unmanaged.passUnretained(event)
            }

            let capturedText = pb.string(forType: .string) ?? ""
            let capturedHTML = pb.string(forType: .html)
            guard !capturedText.isEmpty else {
                RelayLog.info("WARN: Typeless paste detected (pid=\(srcPID)) but pasteboard string empty")
                return Unmanaged.passUnretained(event)
            }

            let now = CFAbsoluteTimeGetCurrent()
            me.swallowedKeyCode = keyCode
            me.swallowTimestamp = now

            if now - me.lastInterceptTime > 0.05 {
                me.lastInterceptTime = now
                RelayLog.info("Intercepted Typeless paste! pid=\(srcPID) key=\(keyCode) chars=\(capturedText.count) -> \(peer.name)(\(peer.ip):\(peer.tcpPort))")
                me.relayCapturedTranscript(text: capturedText, html: capturedHTML, to: peer)
            }

            return nil
        }

        var createdTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: refcon
        )
        if createdTap != nil {
            activeTapLocationName = "HID-tail"
        } else {
            createdTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: callback,
                userInfo: refcon
            )
            activeTapLocationName = (createdTap != nil) ? "Session-head" : "failed"
        }

        guard let tap = createdTap else {
            RelayLog.info("ERROR: CGEvent.tapCreate returned nil despite AXIsProcessTrusted=true")
            return
        }

        eventTap = tap
        let runLoopSrc = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSrc, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        RelayLog.info("EventTap active at \(activeTapLocationName)")
    }

    private func relayCapturedTranscript(text: String, html: String?, to peer: PeerInfo) {
        net.sendPaste(text: text, html: html, to: peer) { [weak self] ok in
            guard let self = self else { return }
            let preview = Self.shortPreview(text)
            RelayLog.info("Relay to \(peer.name) result=\(ok)")
            self.lastRelaySummary = ok
                ? L10n.sentSummary(name: peer.name, preview: preview)
                : L10n.sendFailedSummary(name: peer.name)
            self.rebuildMenuAndIcon()
        }
    }

    // MARK: Menu & Status Bar Rendering

    private func rebuildMenuAndIcon() {
        let axTrusted = AXIsProcessTrusted()

        if let btn = statusItem.button {
            let iconState: MenuBarIcon.VisualState
            if !axTrusted {
                iconState = .warningPermission
            } else if roleMode == .receiver {
                iconState = .receiverReady
            } else if activeTargetPeer != nil {
                iconState = .senderConnected
            } else {
                iconState = .senderSearching
            }
            btn.image = MenuBarIcon.make(state: iconState)
            btn.title = ""
        }

        let menu = NSMenu()
        menu.delegate = self

        let header = NSMenuItem(title: "TypelessRelay · \(net?.deviceName ?? localComputerName())", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let statusText: String
        if !axTrusted {
            statusText = L10n.statusNeedAX
        } else if roleMode == .receiver {
            statusText = L10n.statusReceiverReady
        } else if let peer = activeTargetPeer {
            let isOnline = discoveredPeers.contains(where: { $0.id == peer.id })
            statusText = L10n.statusSenderReady(name: peer.name, ip: peer.ip, online: isOnline)
        } else {
            statusText = L10n.statusSenderSearching
        }
        let statusItemRow = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusItemRow.isEnabled = false
        menu.addItem(statusItemRow)

        let recentRow = NSMenuItem(title: L10n.recentRelay(lastRelaySummary), action: nil, keyEquivalent: "")
        recentRow.isEnabled = false
        menu.addItem(recentRow)

        menu.addItem(.separator())

        let sectionHeader = NSMenuItem(title: L10n.roleSectionHeader, action: nil, keyEquivalent: "")
        sectionHeader.isEnabled = false
        menu.addItem(sectionHeader)

        let recvItem = NSMenuItem(title: L10n.actAsReceiver, action: #selector(selectReceiverMode), keyEquivalent: "")
        recvItem.target = self
        recvItem.state = (roleMode == .receiver) ? .on : .off
        menu.addItem(recvItem)

        if discoveredPeers.isEmpty {
            if let savedName = targetPeerName, !savedName.isEmpty, let savedIP = targetPeerIP, !savedIP.isEmpty {
                let cachedItem = NSMenuItem(
                    title: L10n.sendToCached(name: savedName, ip: savedIP),
                    action: #selector(selectCachedSenderPeer),
                    keyEquivalent: ""
                )
                cachedItem.target = self
                cachedItem.state = (roleMode == .sender) ? .on : .off
                menu.addItem(cachedItem)
            } else {
                let emptyItem = NSMenuItem(title: L10n.noPeersFound, action: nil, keyEquivalent: "")
                emptyItem.isEnabled = false
                menu.addItem(emptyItem)
            }
        } else {
            let currentTargetID = activeTargetPeer?.id
            for (idx, peer) in discoveredPeers.enumerated() {
                let isPeerRecv = (peer.role == RoleMode.receiver.rawValue)
                let item = NSMenuItem(
                    title: L10n.sendToPeer(name: peer.name, isReceiver: isPeerRecv, ip: peer.ip),
                    action: #selector(selectSenderPeer(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.tag = idx
                item.state = (roleMode == .sender && peer.id == currentTargetID) ? .on : .off
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: L10n.startAtLogin, action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(loginItem)

        let refreshItem = NSMenuItem(title: L10n.refreshPeers, action: #selector(refreshPeersClicked), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let permTitle = axTrusted ? L10n.openAXGranted : L10n.openAXNeeded
        let permItem = NSMenuItem(title: permTitle, action: #selector(openAccessibilitySettings), keyEquivalent: "")
        permItem.target = self
        menu.addItem(permItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: L10n.quitApp, action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private static func shortPreview(_ s: String) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if flat.count <= 18 { return flat }
        return String(flat.prefix(18)) + "…"
    }

    // MARK: Menu Actions

    @objc private func selectReceiverMode() {
        roleMode = .receiver
        UserDefaults.standard.set(roleMode.rawValue, forKey: Constants.prefRoleMode)
        net.broadcastBeacon(op: "ping")
        rebuildMenuAndIcon()
    }

    @objc private func selectCachedSenderPeer() {
        roleMode = .sender
        UserDefaults.standard.set(roleMode.rawValue, forKey: Constants.prefRoleMode)
        ensureTypelessWhitelistIfSender()
        net.broadcastBeacon(op: "ping")
        setupEventTapIfNeeded()
        rebuildMenuAndIcon()
    }

    @objc private func selectSenderPeer(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard idx >= 0 && idx < discoveredPeers.count else { return }
        let peer = discoveredPeers[idx]
        roleMode = .sender
        persistTargetPeer(peer)
        UserDefaults.standard.set(roleMode.rawValue, forKey: Constants.prefRoleMode)

        ensureTypelessWhitelistIfSender()
        net.sendControl(type: "become_receiver", to: peer)
        net.broadcastBeacon(op: "ping")
        setupEventTapIfNeeded()
        rebuildMenuAndIcon()
    }

    @objc private func refreshPeersClicked() {
        net.refreshNow()
        rebuildMenuAndIcon()
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            RelayLog.info("SMAppService toggle error: \(error)")
        }
        rebuildMenuAndIcon()
    }

    @objc private func openAccessibilitySettings() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
