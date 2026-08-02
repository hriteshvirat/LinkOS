import Foundation

final class TerminalSession {
    let id: String
    private var ptyMasterFd: Int32 = -1
    private var childPid: pid_t = 0
    private var isRunning: Bool = false
    
    private var dispatchSource: DispatchSourceRead?
    private let readQueue = DispatchQueue(label: "com.linkos.terminal.read", qos: .userInitiated)
    
    var onOutput: ((Data) -> Void)?
    
    init(id: String = UUID().uuidString) {
        self.id = id
    }
    
    func startSession(shell: String = "/bin/zsh", cols: UInt16 = 80, rows: UInt16 = 24) throws {
        var masterFd: Int32 = 0
        var win = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        
        let pid = forkpty(&masterFd, nil, nil, &win)
        if pid < 0 {
            throw NSError(domain: "TerminalSession", code: 1, userInfo: [NSLocalizedDescriptionKey: "forkpty failed"])
        }
        
        if pid == 0 {
            // Child process: Exec shell
            let env = ["TERM": "xterm-256color", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"]
            for (k, v) in env { setenv(k, v, 1) }
            
            let cShell = strdup(shell)
            let args: [UnsafeMutablePointer<CChar>?] = [cShell, nil]
            execv(shell, args)
            exit(1)
        }
        
        // Parent process
        self.ptyMasterFd = masterFd
        self.childPid = pid
        self.isRunning = true
        
        // Set PTY master descriptor to non-blocking
        let flags = fcntl(masterFd, F_GETFL, 0)
        _ = fcntl(masterFd, F_SETFL, flags | O_NONBLOCK)
        
        // Setup asynchronous dispatch source read monitor
        let source = DispatchSource.makeReadSource(fileDescriptor: masterFd, queue: readQueue)
        self.dispatchSource = source
        
        source.setEventHandler { [weak self] in
            guard let self = self, self.ptyMasterFd >= 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let bytesRead = read(self.ptyMasterFd, &buffer, buffer.count)
            if bytesRead > 0 {
                let data = Data(buffer[0..<bytesRead])
                self.onOutput?(data)
            } else if bytesRead < 0 {
                let err = errno
                if err != EAGAIN && err != EWOULDBLOCK {
                    self.stopSession()
                }
            } else {
                // EOF
                self.stopSession()
            }
        }
        
        source.setCancelHandler { [weak self] in
            guard let self = self else { return }
            if self.ptyMasterFd >= 0 {
                close(self.ptyMasterFd)
                self.ptyMasterFd = -1
            }
        }
        
        source.resume()
        LinkOSLogger.shared.info("Started PTY terminal session \(id) (PID \(pid))", category: .terminal)
    }
    
    func writeInput(_ data: Data) {
        guard isRunning, ptyMasterFd >= 0 else { return }
        data.withUnsafeBytes { ptr in
            if let base = ptr.baseAddress {
                _ = write(ptyMasterFd, base, data.count)
            }
        }
    }
    
    func resize(cols: UInt16, rows: UInt16) {
        guard ptyMasterFd >= 0 else { return }
        var win = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(ptyMasterFd, TIOCSWINSZ, &win)
    }
    
    func sendSignal(_ sig: Int32) {
        guard childPid > 0 else { return }
        kill(childPid, sig)
    }
    
    func stopSession() {
        guard isRunning else { return }
        isRunning = false
        
        if let source = dispatchSource {
            source.cancel()
            dispatchSource = nil
        } else {
            if ptyMasterFd >= 0 {
                close(ptyMasterFd)
                ptyMasterFd = -1
            }
        }
        
        if childPid > 0 {
            kill(childPid, SIGTERM)
            var status: Int32 = 0
            waitpid(childPid, &status, WNOHANG)
            childPid = 0
        }
    }
}

final class TerminalPlugin: LinkOSPlugin {
    let pluginId = "terminal"
    let displayName = "Terminal & PTY"
    let version = "1.0.0"
    let subscribedChannels: Set<String> = ["terminal"]
    let requiredPermissions: Set<String> = ["TERMINAL_ACCESS"]
    
    private(set) var isActive = false
    private var activeSessions: [String: TerminalSession] = [:]
    private weak var connectionManager: ConnectionManager?
    
    init(connectionManager: ConnectionManager? = nil) {
        self.connectionManager = connectionManager
    }
    
    func activate() async throws {
        isActive = true
        LinkOSLogger.shared.info("TerminalPlugin activated", category: .terminal)
    }
    
    func deactivate() async {
        isActive = false
        for session in activeSessions.values {
            session.stopSession()
        }
        activeSessions.removeAll()
        LinkOSLogger.shared.info("TerminalPlugin deactivated", category: .terminal)
    }
    
    func handleMessage(_ message: LinkOSMessageEnvelope) async {
        guard let json = try? JSONSerialization.jsonObject(with: message.payload) as? [String: Any],
              let action = json["action"] as? String else { return }
        
        switch action {
        case "start":
            let session = TerminalSession()
            activeSessions[session.id] = session
            session.onOutput = { [weak self] data in
                Task {
                    await self?.sendTerminalOutput(sessionId: session.id, data: data)
                }
            }
            try? session.startSession()
            
            // Respond with session created handshake
            let responseDict: [String: Any] = [
                "status": "session_created",
                "session_id": session.id
            ]
            if let responseData = try? JSONSerialization.data(withJSONObject: responseDict),
               let responseStr = String(data: responseData, encoding: .utf8) {
                let response = MessageRouter.createResponse(channel: "terminal", payload: responseStr.data(using: .utf8)!, correlationId: message.correlationId)
                try? await connectionManager?.send(response, to: message.deviceId)
            }
            
        case "input":
            if let sessionId = json["session_id"] as? String,
               let text = json["text"] as? String,
               let session = activeSessions[sessionId],
               let data = text.data(using: .utf8) {
                session.writeInput(data)
            }
            
        case "signal":
            if let sessionId = json["session_id"] as? String,
               let sig = json["signal"] as? Int32,
               let session = activeSessions[sessionId] {
                session.sendSignal(sig)
            }
            
        default:
            break
        }
    }
    
    private func sendTerminalOutput(sessionId: String, data: Data) async {
        guard let connectionManager else { return }
        let text = String(decoding: data, as: UTF8.self)
        let payloadDict: [String: Any] = [
            "action": "output",
            "session_id": sessionId,
            "text": text
        ]
        if let payloadData = try? JSONSerialization.data(withJSONObject: payloadDict),
           let payloadStr = String(data: payloadData, encoding: .utf8) {
            let msg = MessageRouter.createEvent(channel: "terminal", payload: payloadStr.data(using: .utf8)!)
            await connectionManager.broadcast(msg)
        }
    }
}
