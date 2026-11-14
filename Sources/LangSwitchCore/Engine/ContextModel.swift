import Foundation

/// How often one word follows another in everyday text.
///
/// Built offline from open sentence collections by the `LangSwitchData` tool and shipped as one
/// read-only file per language. Words are identified by their rank in the frequency list the model was
/// built against; the list's signature is stored in the file, so a model can never be read against a
/// different list.
///
/// File layout (little-endian): a 32-byte header, then for every word the total number of pairs it
/// opens, then row offsets, then the rows. A row holds the followers of one word, sorted by rank; an
/// entry packs the follower (20 bits) and the pair count, capped at 4095 (12 bits).
package struct ContextModel: Sendable {
    private static let magic: UInt32 = 0x4D43_534C
    private static let version: UInt32 = 1
    private static let headerSize = 32
    private static let countBits = 12
    private static let countCap = (1 << countBits) - 1
    /// Followers must fit into the remaining 20 bits of an entry.
    package static let vocabularyLimit = 1 << 20

    private let data: Data
    private let vocabulary: Int
    private let totalsOffset: Int
    private let rowsOffset: Int
    private let entriesOffset: Int
    package let pairCount: Int

    /// - Parameter signature: of the frequency list in use; the model is rejected when it was built
    ///   against another one.
    package init?(data: Data, signature: UInt64) {
        guard data.count >= Self.headerSize else { return nil }
        func header(_ offset: Int) -> UInt32 { Self.read(data, at: offset) }
        guard header(0) == Self.magic, header(4) == Self.version else { return nil }
        let vocabulary = Int(header(8))
        let pairs = Int(header(12))
        let stored = UInt64(header(16)) | UInt64(header(20)) << 32
        guard stored == signature, vocabulary <= Self.vocabularyLimit else { return nil }
        self.vocabulary = vocabulary
        self.pairCount = pairs
        self.totalsOffset = Self.headerSize
        self.rowsOffset = totalsOffset + vocabulary * 4
        self.entriesOffset = rowsOffset + (vocabulary + 1) * 4
        guard data.count == entriesOffset + pairs * 4 else { return nil }
        self.data = data
    }

    private static func read(_ data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }

    /// How many pairs in the corpus begin with the word.
    package func total(after first: Int) -> Int {
        guard first >= 0, first < vocabulary else { return 0 }
        return Int(Self.read(data, at: totalsOffset + first * 4))
    }

    private func row(_ first: Int) -> Range<Int> {
        guard first >= 0, first < vocabulary else { return 0..<0 }
        let start = Int(Self.read(data, at: rowsOffset + first * 4))
        let end = Int(Self.read(data, at: rowsOffset + (first + 1) * 4))
        return start..<end
    }

    /// How many times `second` follows `first` (capped at 4095); 0 when the pair was not seen.
    package func count(_ first: Int, _ second: Int) -> Int {
        var range = row(first)
        guard second >= 0, second < vocabulary else { return 0 }
        return data.withUnsafeBytes { bytes in
            while !range.isEmpty {
                let middle = range.lowerBound + range.count / 2
                let entry = UInt32(
                    littleEndian: bytes.loadUnaligned(
                        fromByteOffset: entriesOffset + middle * 4, as: UInt32.self))
                let word = Int(entry >> UInt32(Self.countBits))
                if word == second { return Int(entry) & Self.countCap }
                if word < second {
                    range = (middle + 1)..<range.upperBound
                } else {
                    range = range.lowerBound..<middle
                }
            }
            return 0
        }
    }

    /// The words that most often follow `first`, most frequent first.
    package func followers(of first: Int, limit: Int) -> [(word: Int, count: Int)] {
        let range = row(first)
        guard !range.isEmpty, limit > 0 else { return [] }
        var best: [(word: Int, count: Int)] = []
        data.withUnsafeBytes { bytes in
            for index in range {
                let entry = UInt32(
                    littleEndian: bytes.loadUnaligned(
                        fromByteOffset: entriesOffset + index * 4, as: UInt32.self))
                let count = Int(entry) & Self.countCap
                if best.count == limit, let last = best.last, last.count >= count { continue }
                let item = (word: Int(entry >> UInt32(Self.countBits)), count: count)
                let position = best.firstIndex { $0.count < count } ?? best.count
                best.insert(item, at: position)
                if best.count > limit { best.removeLast() }
            }
        }
        return best
    }

    /// Collects pair counts and writes the file.
    package struct Builder {
        private var counts: [UInt64: UInt32] = [:]

        package init() {}

        package mutating func add(_ first: Int, _ second: Int, count: Int = 1) {
            guard first >= 0, second >= 0, first < ContextModel.vocabularyLimit,
                second < ContextModel.vocabularyLimit
            else { return }
            counts[UInt64(first) << 32 | UInt64(second), default: 0] += UInt32(count)
        }

        package var pairCount: Int { counts.count }

        /// - Parameter minimumCount: pairs seen fewer times are noise and are dropped.
        package func build(vocabulary: Int, signature: UInt64, minimumCount: Int = 1) -> Data {
            var totals = [UInt32](repeating: 0, count: vocabulary)
            var kept: [(key: UInt64, count: UInt32)] = []
            kept.reserveCapacity(counts.count)
            for (key, count) in counts {
                let first = Int(key >> 32)
                guard first < vocabulary, Int(key & 0xFFFF_FFFF) < vocabulary else { continue }
                // Totals keep every observation, so that rare followers still weigh on the share.
                totals[first] &+= count
                if count >= UInt32(minimumCount) { kept.append((key, count)) }
            }
            kept.sort { $0.key < $1.key }

            var rows = [UInt32](repeating: 0, count: vocabulary + 1)
            for item in kept { rows[Int(item.key >> 32) + 1] += 1 }
            for index in 1...max(vocabulary, 1) where index <= vocabulary { rows[index] += rows[index - 1] }

            var data = Data(capacity: ContextModel.headerSize + (vocabulary * 2 + 1 + kept.count) * 4)
            func append(_ value: UInt32) {
                withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
            }
            append(ContextModel.magic)
            append(ContextModel.version)
            append(UInt32(vocabulary))
            append(UInt32(kept.count))
            append(UInt32(truncatingIfNeeded: signature))
            append(UInt32(truncatingIfNeeded: signature >> 32))
            append(0)
            append(0)
            totals.forEach(append)
            rows.forEach(append)
            for item in kept {
                let second = UInt32(item.key & 0xFFFF_FFFF)
                append(
                    second << UInt32(ContextModel.countBits) | min(item.count, UInt32(ContextModel.countCap)))
            }
            return data
        }
    }
}
