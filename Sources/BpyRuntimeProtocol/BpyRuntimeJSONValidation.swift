import CryptoKit
import Foundation

public enum BpyRuntimeJSONValidation {
    private struct Invalid: Error {}

    private struct Parser {
        let file: BpyRuntimeFile
        let checking: () throws -> Void
        var buffer = Data()
        var index = 0
        var offset: UInt64 = 0
        var digest = SHA256()

        mutating func peek() throws -> UInt8? {
            if index == buffer.count {
                guard offset < file.byteCount else { return nil }
                try checking()
                buffer = try file.read(offset: offset, maximum: 65_536)
                guard !buffer.isEmpty else { throw Invalid() }
                digest.update(data: buffer)
                offset += UInt64(buffer.count)
                index = 0
            }
            return buffer[index]
        }

        mutating func take() throws -> UInt8 {
            guard let value = try peek() else { throw Invalid() }
            index += 1
            return value
        }

        mutating func expect(_ byte: UInt8) throws {
            guard try take() == byte else { throw Invalid() }
        }

        mutating func whitespace() throws {
            while let byte = try peek(), [0x20, 0x09, 0x0a, 0x0d].contains(byte) { index += 1 }
        }

        mutating func document() throws {
            try whitespace()
            guard let first = try peek(), first == 0x7b || first == 0x5b else { throw Invalid() }
            try value(depth: 0)
            try whitespace()
            guard try peek() == nil,
                  digest.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256 else { throw Invalid() }
            try checking()
        }

        mutating func value(depth: Int) throws {
            try whitespace()
            guard let byte = try peek() else { throw Invalid() }
            switch byte {
            case 0x7b:
                guard depth < 512 else { throw Invalid() }
                try object(depth: depth + 1)
            case 0x5b:
                guard depth < 512 else { throw Invalid() }
                try array(depth: depth + 1)
            case 0x22: try string()
            case 0x74: try literal("true")
            case 0x66: try literal("false")
            case 0x6e: try literal("null")
            case 0x2d, 0x30...0x39: try number()
            default: throw Invalid()
            }
        }

        mutating func object(depth: Int) throws {
            try expect(0x7b)
            try whitespace()
            if try peek() == 0x7d { index += 1; return }
            while true {
                try string()
                try whitespace()
                try expect(0x3a)
                try value(depth: depth)
                try whitespace()
                let next = try take()
                if next == 0x7d { return }
                guard next == 0x2c else { throw Invalid() }
                try whitespace()
            }
        }

        mutating func array(depth: Int) throws {
            try expect(0x5b)
            try whitespace()
            if try peek() == 0x5d { index += 1; return }
            while true {
                try value(depth: depth)
                try whitespace()
                let next = try take()
                if next == 0x5d { return }
                guard next == 0x2c else { throw Invalid() }
            }
        }

        mutating func literal(_ text: StaticString) throws {
            for byte in String(describing: text).utf8 { try expect(byte) }
        }

        mutating func digits() throws {
            guard let first = try peek(), (0x30...0x39).contains(first) else { throw Invalid() }
            repeat { index += 1 } while try peek().map({ (0x30...0x39).contains($0) }) == true
        }

        mutating func number() throws {
            if try peek() == 0x2d { index += 1 }
            if try peek() == 0x30 { index += 1 }
            else {
                guard let first = try peek(), (0x31...0x39).contains(first) else { throw Invalid() }
                try digits()
            }
            if try peek() == 0x2e { index += 1; try digits() }
            if let byte = try peek(), byte == 0x65 || byte == 0x45 {
                index += 1
                if let sign = try peek(), sign == 0x2b || sign == 0x2d { index += 1 }
                try digits()
            }
        }

        mutating func hexadecimal() throws -> UInt16 {
            var value: UInt16 = 0
            for _ in 0..<4 {
                let byte = try take(), digit: UInt16
                switch byte {
                case 0x30...0x39: digit = UInt16(byte - 0x30)
                case 0x41...0x46: digit = UInt16(byte - 0x41 + 10)
                case 0x61...0x66: digit = UInt16(byte - 0x61 + 10)
                default: throw Invalid()
                }
                value = value * 16 + digit
            }
            return value
        }

        mutating func escaped() throws {
            switch try take() {
            case 0x22, 0x5c, 0x2f, 0x62, 0x66, 0x6e, 0x72, 0x74: return
            case 0x75:
                let value = try hexadecimal()
                if (0xd800...0xdbff).contains(value) {
                    try expect(0x5c); try expect(0x75)
                    guard try (0xdc00...0xdfff).contains(hexadecimal()) else { throw Invalid() }
                } else if (0xdc00...0xdfff).contains(value) { throw Invalid() }
            default: throw Invalid()
            }
        }

        mutating func unicode(after first: UInt8) throws {
            let continuation: Int, lower: UInt8, upper: UInt8
            switch first {
            case 0xc2...0xdf: continuation = 1; lower = 0x80; upper = 0xbf
            case 0xe0: continuation = 2; lower = 0xa0; upper = 0xbf
            case 0xe1...0xec, 0xee...0xef: continuation = 2; lower = 0x80; upper = 0xbf
            case 0xed: continuation = 2; lower = 0x80; upper = 0x9f
            case 0xf0: continuation = 3; lower = 0x90; upper = 0xbf
            case 0xf1...0xf3: continuation = 3; lower = 0x80; upper = 0xbf
            case 0xf4: continuation = 3; lower = 0x80; upper = 0x8f
            default: throw Invalid()
            }
            guard try (lower...upper).contains(take()) else { throw Invalid() }
            for _ in 1..<continuation {
                guard try (0x80...0xbf).contains(take()) else { throw Invalid() }
            }
        }

        mutating func string() throws {
            try expect(0x22)
            while true {
                let byte = try take()
                switch byte {
                case 0x22: return
                case 0x5c: try escaped()
                case 0x00...0x1f: throw Invalid()
                case 0x80...0xff: try unicode(after: byte)
                default: break
                }
            }
        }
    }

    public static func validate(_ file: BpyRuntimeFile, checking: @escaping () throws -> Void = {}) throws {
        let held = try file.retained()
        defer { held.release() }
        var parser = Parser(file: held, checking: checking)
        try parser.document()
    }
}
