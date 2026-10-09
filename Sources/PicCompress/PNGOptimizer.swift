import Foundation
import CZlib

/// PNG 纯容器级无损优化。
///
/// 做法：把 IDAT 数据流解出来，用 zlib 最高压缩等级重新压回去。
/// 像素数据一个字节都不会变（真·无损），但很多 PNG 能因此小 10%~35%。
///
/// 之所以需要它：ImageIO 的 PNG 编码器压缩等级偏保守，实测有 27%~31% 的余量。
enum PNGOptimizer {

    private static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// 返回优化后的 PNG 数据；无可优化空间时返回 nil
    static func optimize(_ input: Data) -> Data? {
        let bytes = [UInt8](input)
        guard bytes.count > 8, Array(bytes[0..<8]) == signature else { return nil }

        // ---- 拆 chunk ----
        var chunks: [(type: String, body: [UInt8])] = []
        var index = 8

        while index + 12 <= bytes.count {
            let length = Int(be32(bytes, index))
            guard index + 12 + length <= bytes.count else { return nil }
            let type = String(bytes: bytes[index + 4..<index + 8], encoding: .ascii) ?? "?"
            let body = Array(bytes[index + 8..<index + 8 + length])
            chunks.append((type, body))
            index += 12 + length
            if type == "IEND" { break }
        }

        guard chunks.contains(where: { $0.type == "IHDR" }),
              chunks.contains(where: { $0.type == "IDAT" }) else { return nil }

        // ---- 合并并重压 IDAT ----
        var combined: [UInt8] = []
        for chunk in chunks where chunk.type == "IDAT" {
            combined.append(contentsOf: chunk.body)
        }

        guard let raw = inflate(Data(combined)) else { return nil }
        guard let repacked = deflate(raw, level: 9) else { return nil }
        guard repacked.count < combined.count else { return nil }

        // ---- 重组 ----
        var out: [UInt8] = signature
        out.reserveCapacity(bytes.count)
        var idatWritten = false

        for chunk in chunks {
            if chunk.type == "IDAT" {
                if !idatWritten {
                    out.append(contentsOf: makeChunk("IDAT", [UInt8](repacked)))
                    idatWritten = true
                }
                continue
            }
            out.append(contentsOf: makeChunk(chunk.type, chunk.body))
        }

        return Data(out)
    }

    // MARK: - zlib 桥接

    private static func inflate(_ input: Data) -> Data? {
        guard !input.isEmpty else { return nil }

        var stream = z_stream()
        let version = String(cString: zlibVersion())
        guard inflateInit_(&stream, version, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            return nil
        }
        defer { inflateEnd(&stream) }

        let bufferSize = 1 << 18
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var output = Data()
        output.reserveCapacity(input.count * 4)

        var status: Int32 = Z_OK

        input.withUnsafeBytes { rawInput in
            guard let base = rawInput.bindMemory(to: Bytef.self).baseAddress else { return }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(input.count)

            while status == Z_OK || status == Z_BUF_ERROR {
                var produced = 0
                buffer.withUnsafeMutableBytes { rawOut in
                    stream.next_out = rawOut.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(bufferSize)
                    status = CZlib.inflate(&stream, Z_NO_FLUSH)
                    produced = bufferSize - Int(stream.avail_out)
                }
                if produced > 0 {
                    output.append(contentsOf: buffer[0..<produced])
                }
                if produced == 0 { break }
            }
        }

        guard status == Z_STREAM_END else { return nil }
        return output
    }

    private static func deflate(_ input: Data, level: Int32) -> Data? {
        var stream = z_stream()
        let version = String(cString: zlibVersion())
        guard deflateInit_(&stream, level, version, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            return nil
        }
        defer { deflateEnd(&stream) }

        let bufferSize = 1 << 18
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var output = Data()

        var status: Int32 = Z_OK

        input.withUnsafeBytes { rawInput in
            stream.next_in = UnsafeMutablePointer(mutating: rawInput.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)

            while status == Z_OK {
                var produced = 0
                buffer.withUnsafeMutableBytes { rawOut in
                    stream.next_out = rawOut.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(bufferSize)
                    status = CZlib.deflate(&stream, Z_FINISH)
                    produced = bufferSize - Int(stream.avail_out)
                }
                if produced > 0 {
                    output.append(contentsOf: buffer[0..<produced])
                }
            }
        }

        guard status == Z_STREAM_END else { return nil }
        return output
    }

    // MARK: - chunk 工具

    private static func makeChunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
        var payload = Array(type.utf8)
        payload.append(contentsOf: body)

        var out: [UInt8] = []
        out.reserveCapacity(payload.count + 12)
        out.append(contentsOf: be32Bytes(UInt32(body.count)))
        out.append(contentsOf: payload)
        let checksum = crc32(0, payload, uInt(payload.count))
        out.append(contentsOf: be32Bytes(UInt32(truncatingIfNeeded: checksum)))
        return out
    }

    private static func be32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    private static func be32Bytes(_ value: UInt32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
    }
}
