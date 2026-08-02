import Foundation

/// Unified error model for the LinkOS protocol layer.
/// Provides structured error codes and user-facing localised messages.
enum LinkOSError: Error, CustomStringConvertible, Equatable {
    case connectionLost
    case verificationFailed(detail: String)
    case ackTimeout(transferId: String)
    case permissionDenied(feature: String)
    case storageFull
    case checksumMismatch(expected: String, actual: String)
    case chunkWriteFailure(chunkIndex: Int, reason: String)
    case pairingFailed(reason: String)
    case protocolVersionMismatch(local: Int, remote: Int)
    case unknown(message: String)
    
    // MARK: - Error Codes
    
    var code: String {
        switch self {
        case .connectionLost:          return "ERR_CONN_LOST"
        case .verificationFailed:      return "ERR_VERIFICATION_FAILED"
        case .ackTimeout:              return "ERR_ACK_TIMEOUT"
        case .permissionDenied:        return "ERR_PERMISSION_DENIED"
        case .storageFull:             return "ERR_STORAGE_FULL"
        case .checksumMismatch:        return "ERR_CHECKSUM_MISMATCH"
        case .chunkWriteFailure:       return "ERR_CHUNK_WRITE"
        case .pairingFailed:           return "ERR_PAIRING_FAILED"
        case .protocolVersionMismatch: return "ERR_PROTOCOL_VERSION"
        case .unknown:                 return "ERR_UNKNOWN"
        }
    }
    
    // MARK: - User-Facing Messages
    
    var userMessage: String {
        switch self {
        case .connectionLost:
            return "Connection lost. Attempting to reconnect…"
        case .verificationFailed(let detail):
            return "File verification failed: \(detail)"
        case .ackTimeout(let transferId):
            return "Timeout waiting for acknowledgement (transfer: \(transferId))"
        case .permissionDenied(let feature):
            return "Permission denied for \(feature)"
        case .storageFull:
            return "Storage full. Free up space and try again."
        case .checksumMismatch(let expected, let actual):
            return "Checksum mismatch (expected: \(expected.prefix(8))…, got: \(actual.prefix(8))…)"
        case .chunkWriteFailure(let idx, let reason):
            return "Failed to write chunk \(idx): \(reason)"
        case .pairingFailed(let reason):
            return "Pairing failed: \(reason)"
        case .protocolVersionMismatch(let local, let remote):
            return "Protocol version mismatch (local: \(local), remote: \(remote))"
        case .unknown(let message):
            return message
        }
    }
    
    var description: String {
        "[\(code)] \(userMessage)"
    }
}
