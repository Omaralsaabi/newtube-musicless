import Foundation

/// One adaptive file's init segment, segment index and segments, read through a `MediaFetcher`
/// (US-012). The first request takes the init and index ranges plus whatever follows them up to the
/// fetcher's first-chunk size, so the opening segment (≈ 160 KB for 10 s of 128 kbps AAC) usually
/// arrives with them: one round trip instead of three before the first sound.
public struct FMP4Header: Sendable {
    public var initSegment: FMP4Init
    public var index: FMP4SegmentIndex
    /// Bytes read past the index (the start of the first segments), reused by `segments(from:)`.
    public var prefix: Data
    public var prefixOffset: Int64

    public func track(_ kind: FMP4Track.Kind) -> FMP4Track? { initSegment.tracks.first { $0.kind == kind } }
}

public enum FMP4Reader {
    /// Reads and parses the init and index ranges (inclusive byte ranges from the /player answer).
    public static func open(_ fetcher: MediaFetcher, initRange: ClosedRange<Int64>,
                            indexRange: ClosedRange<Int64>) async throws -> FMP4Header {
        let length = await fetcher.file.contentLength
        let first = fetcher.configuration.firstChunk
        let initData: Data, indexData: Data, prefix: Data
        if indexRange.lowerBound == initRange.upperBound + 1 {
            let end = min(max(indexRange.upperBound, initRange.lowerBound + first - 1), length - 1)
            let data = try await fetcher.read(initRange.lowerBound...end)
            func slice(_ range: ClosedRange<Int64>) -> Data {
                data.subdata(in: Int(range.lowerBound - initRange.lowerBound)..<Int(range.upperBound - initRange.lowerBound + 1))
            }
            initData = slice(initRange)
            indexData = slice(indexRange)
            prefix = end > indexRange.upperBound ? slice((indexRange.upperBound + 1)...end) : Data()
        } else {
            initData = try await fetcher.read(initRange)
            indexData = try await fetcher.read(indexRange)
            prefix = Data()
        }
        return FMP4Header(initSegment: try FMP4Demuxer.parseInit(initData),
                          index: try FMP4Demuxer.parseIndex(indexData, fileOffset: indexRange.lowerBound),
                          prefix: prefix, prefixOffset: indexRange.upperBound + 1)
    }

    /// The segments from sidx reference `start` to the end, each whole. Pull-based: requests group
    /// consecutive segments, starting at the fetcher's first-chunk size and doubling to its maximum
    /// (always at least one segment); nothing is fetched until the consumer asks.
    public static func segments(_ fetcher: MediaFetcher, header: FMP4Header, from start: Int) -> FMP4Segments {
        FMP4Segments(fetcher: fetcher, references: header.index.references, start: start,
                     prefix: header.prefix, prefixOffset: header.prefixOffset,
                     first: fetcher.configuration.firstChunk, maxSize: fetcher.configuration.maxChunk)
    }
}

public struct FMP4Segments: AsyncSequence {
    public struct Segment: Sendable {
        /// Index of the sidx reference.
        public let index: Int
        public let reference: FMP4SegmentIndex.Reference
        public let data: Data
    }

    let fetcher: MediaFetcher
    let references: [FMP4SegmentIndex.Reference]
    let start: Int
    let prefix: Data
    let prefixOffset: Int64
    let first: Int64
    let maxSize: Int64

    public func makeAsyncIterator() -> Iterator {
        Iterator(sequence: self, next: start, size: first)
    }

    public struct Iterator: AsyncIteratorProtocol {
        let sequence: FMP4Segments
        var next: Int
        var size: Int64
        var buffered: [Segment] = []

        public mutating func next() async throws -> Segment? {
            if buffered.isEmpty { try await fill() }
            return buffered.isEmpty ? nil : buffered.removeFirst()
        }

        private mutating func fill() async throws {
            let references = sequence.references
            guard next < references.count else { return }
            // Group whole segments up to the current request size (at least one).
            var last = next
            while last + 1 < references.count,
                  references[last + 1].bytes.upperBound - references[next].bytes.lowerBound + 1 <= size {
                last += 1
            }
            let wanted = references[next].bytes.lowerBound...references[last].bytes.upperBound
            // Bytes already read by `open` cover the start of the range; fetch only the rest.
            let prefixEnd = sequence.prefixOffset + Int64(sequence.prefix.count) - 1
            var data = Data()
            var from = wanted.lowerBound
            if !sequence.prefix.isEmpty, wanted.lowerBound >= sequence.prefixOffset, wanted.lowerBound <= prefixEnd {
                let upTo = Swift.min(prefixEnd, wanted.upperBound)
                data = sequence.prefix.subdata(in: Int(wanted.lowerBound - sequence.prefixOffset)..<Int(upTo - sequence.prefixOffset + 1))
                from = upTo + 1
            }
            if from <= wanted.upperBound {
                data.append(try await sequence.fetcher.read(from...wanted.upperBound))
                size = Swift.min(size * 2, sequence.maxSize)
            }
            for index in next...last {
                let bytes = references[index].bytes
                let lower = Int(bytes.lowerBound - wanted.lowerBound)
                let upper = Int(bytes.upperBound - wanted.lowerBound)
                buffered.append(Segment(index: index, reference: references[index], data: data.subdata(in: lower..<(upper + 1))))
            }
            next = last + 1
        }
    }
}
