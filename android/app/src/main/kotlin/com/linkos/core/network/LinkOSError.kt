package com.linkos.core.network

/**
 * Unified error model for the LinkOS protocol layer.
 * Provides structured error codes and user-facing localised messages.
 */
sealed class LinkOSError(
    val code: String,
    val userMessage: String
) {
    class ConnectionLost : LinkOSError(
        "ERR_CONN_LOST",
        "Connection lost. Attempting to reconnect…"
    )

    class VerificationFailed(detail: String) : LinkOSError(
        "ERR_VERIFICATION_FAILED",
        "File verification failed: $detail"
    )

    class AckTimeout(transferId: String) : LinkOSError(
        "ERR_ACK_TIMEOUT",
        "Timeout waiting for acknowledgement (transfer: $transferId)"
    )

    class PermissionDenied(feature: String) : LinkOSError(
        "ERR_PERMISSION_DENIED",
        "Permission denied for $feature"
    )

    class StorageFull : LinkOSError(
        "ERR_STORAGE_FULL",
        "Storage full. Free up space and try again."
    )

    class ChecksumMismatch(expected: String, actual: String) : LinkOSError(
        "ERR_CHECKSUM_MISMATCH",
        "Checksum mismatch (expected: ${expected.take(8)}…, got: ${actual.take(8)}…)"
    )

    class ChunkWriteFailure(chunkIndex: Int, reason: String) : LinkOSError(
        "ERR_CHUNK_WRITE",
        "Failed to write chunk $chunkIndex: $reason"
    )

    class PairingFailed(reason: String) : LinkOSError(
        "ERR_PAIRING_FAILED",
        "Pairing failed: $reason"
    )

    class ProtocolVersionMismatch(local: Int, remote: Int) : LinkOSError(
        "ERR_PROTOCOL_VERSION",
        "Protocol version mismatch (local: $local, remote: $remote)"
    )

    class Unknown(message: String) : LinkOSError(
        "ERR_UNKNOWN",
        message
    )

    override fun toString(): String = "[$code] $userMessage"
}
