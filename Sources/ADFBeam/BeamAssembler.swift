import Compression
import Foundation

/// Turns a complete `ChunkCollector` back into the original ADF JSON bytes.
public enum BeamAssembler {
    public enum AssemblyError: Error, Equatable {
        case incomplete
        case decompressionFailed
    }

    public static func assemble(_ collector: ChunkCollector) throws -> Data {
        guard let joined = collector.assembledChunks() else { throw AssemblyError.incomplete }
        return try inflate(joined)
    }

    /// Raw-deflate decompression (matches pako `inflateRaw`; Apple's
    /// `COMPRESSION_ZLIB` is raw deflate, without the zlib header).
    public static func inflate(_ input: Data) throws -> Data {
        try process(input, operation: COMPRESSION_STREAM_DECODE)
    }

    /// Raw-deflate compression; used by tests to build synthetic payloads.
    public static func deflate(_ input: Data) throws -> Data {
        try process(input, operation: COMPRESSION_STREAM_ENCODE)
    }

    private static func process(_ input: Data, operation: compression_stream_operation) throws -> Data {
        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }
        guard compression_stream_init(streamPointer, operation, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw AssemblyError.decompressionFailed
        }
        defer { compression_stream_destroy(streamPointer) }

        let bufferSize = 64 * 1024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destination.deallocate() }

        return try input.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else {
                throw AssemblyError.decompressionFailed
            }
            streamPointer.pointee.src_ptr = base
            streamPointer.pointee.src_size = input.count

            var output = Data()
            var status: compression_status
            repeat {
                streamPointer.pointee.dst_ptr = destination
                streamPointer.pointee.dst_size = bufferSize
                status = compression_stream_process(streamPointer, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                guard status == COMPRESSION_STATUS_OK || status == COMPRESSION_STATUS_END else {
                    throw AssemblyError.decompressionFailed
                }
                output.append(destination, count: bufferSize - streamPointer.pointee.dst_size)
            } while status == COMPRESSION_STATUS_OK
            return output
        }
    }
}
