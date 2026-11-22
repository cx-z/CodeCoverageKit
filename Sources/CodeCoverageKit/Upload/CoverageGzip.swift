#if CODE_COVERAGE_KIT_ENABLED
import Foundation
import zlib

/// Encodes a single deterministic RFC 1952 member using the system zlib library.
enum CoverageGzip {
    enum EncodingError: Error {
        case inputTooLarge
        case zlibFailure(Int32)
    }

    /// Compresses all bytes even when gzip overhead makes the result larger than its input.
    static func encode(_ data: Data) throws -> Data {
        guard data.count <= Int(UInt32.max) else { throw EncodingError.inputTooLarge }
        var t_stream = z_stream()
        let t_initial = deflateInit2_(&t_stream, 6, Z_DEFLATED, 16 + MAX_WBITS, 8,
                                     Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard t_initial == Z_OK else { throw EncodingError.zlibFailure(t_initial) }
        defer { deflateEnd(&t_stream) }
        return try data.withUnsafeBytes { t_input in
            t_stream.next_in = UnsafeMutablePointer<Bytef>(mutating: t_input.bindMemory(to: Bytef.self).baseAddress)
            t_stream.avail_in = uInt(data.count)
            var t_result = Data()
            var t_chunk = [UInt8](repeating: 0, count: 65536)
            var t_status = Z_OK
            repeat {
                t_status = t_chunk.withUnsafeMutableBytes { t_output in
                    t_stream.next_out = t_output.bindMemory(to: Bytef.self).baseAddress
                    t_stream.avail_out = uInt(t_output.count)
                    return deflate(&t_stream, Z_FINISH)
                }
                guard t_status == Z_OK || t_status == Z_STREAM_END else {
                    throw EncodingError.zlibFailure(t_status)
                }
                t_result.append(contentsOf: t_chunk.prefix(t_chunk.count - Int(t_stream.avail_out)))
            } while t_status != Z_STREAM_END
            return t_result
        }
    }
}
#endif
