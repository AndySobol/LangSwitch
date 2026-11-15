import Foundation

/// A dotted version number: "1.3.0". Whatever follows the numbers ("-beta.1") does not take part in
/// the ordering.
package struct AppVersion: Sendable, Comparable, Hashable, CustomStringConvertible {
    package let parts: [Int]

    /// Accepts "1.3.0", "v1.3.0" and "1.3.0-beta.1"; nil when there is no number to read.
    package init?(_ text: String) {
        var numbers: [Int] = []
        var digits = ""
        for character in text.drop(while: { $0 == "v" || $0 == "V" }) {
            if character.isASCII, character.isNumber {
                digits.append(character)
            } else if character == ".", !digits.isEmpty {
                guard let number = Int(digits) else { return nil }
                numbers.append(number)
                digits = ""
            } else {
                break
            }
        }
        if let number = Int(digits) { numbers.append(number) }
        guard !numbers.isEmpty else { return nil }
        // "1.3" and "1.3.0" are the same version.
        while numbers.count > 1, numbers.last == 0 { numbers.removeLast() }
        parts = numbers
    }

    package static func < (left: AppVersion, right: AppVersion) -> Bool {
        for index in 0..<max(left.parts.count, right.parts.count) {
            let first = index < left.parts.count ? left.parts[index] : 0
            let second = index < right.parts.count ? right.parts[index] : 0
            if first != second { return first < second }
        }
        return false
    }

    package var description: String {
        (parts + [Int](repeating: 0, count: max(3 - parts.count, 0))).map(String.init).joined(separator: ".")
    }
}

/// A published release of the application.
package struct ReleaseInfo: Sendable, Equatable {
    package var version: AppVersion
    package var title: String
    /// The release page, for "what is new".
    package var page: URL
    /// The disk image with the application, and the list of checksums published next to it.
    package var diskImage: URL
    package var checksums: URL

    package init(version: AppVersion, title: String, page: URL, diskImage: URL, checksums: URL) {
        self.version = version
        self.title = title
        self.page = page
        self.diskImage = diskImage
        self.checksums = checksums
    }

    package var diskImageName: String { diskImage.lastPathComponent }
}

/// Reads what the releases page says. No networking here: the application fetches the data, this
/// decides what it means.
///
/// The source is the Atom feed of the repository's releases, which unlike the JSON API has no request
/// quota per address. The feed does not list files, so their addresses follow the convention of
/// `scripts/package.sh`: `LangSwitch-<version>.dmg` and `SHA256SUMS.txt` under the release's tag.
package enum ReleaseFeed {
    private final class AtomReader: NSObject, XMLParserDelegate {
        var entries: [(tag: String, title: String)] = []
        private var insideEntry = false
        private var text = ""
        private var tag: String?
        private var title: String?

        func parser(
            _ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
            attributes: [String: String] = [:]
        ) {
            text = ""
            if name == "entry" {
                insideEntry = true
                tag = nil
                title = nil
            } else if insideEntry, name == "link", attributes["rel"] == "alternate",
                let address = attributes["href"],
                let marker = address.range(of: "/releases/tag/")
            {
                tag = String(address[marker.upperBound...]).removingPercentEncoding
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(
            _ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?
        ) {
            if insideEntry, name == "title" {
                title = text.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if name == "entry" {
                if let tag { entries.append((tag, title ?? tag)) }
                insideEntry = false
            }
        }
    }

    package enum FeedError: Error {
        case unreadable
    }

    /// Reads the Atom feed of `https://github.com/<repository>/releases.atom`. Entries whose tag is
    /// not a version are skipped.
    package static func releases(fromAtom data: Data, repository: String) throws -> [ReleaseInfo] {
        let reader = AtomReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else { throw FeedError.unreadable }
        return reader.entries.compactMap { entry in
            // The tag becomes part of an address: nothing but a plain version tag is accepted.
            guard let version = AppVersion(entry.tag),
                entry.tag.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
                ),
                let base = URL(string: "https://github.com/\(repository)/releases/"),
                let page = URL(string: "tag/\(entry.tag)", relativeTo: base)?.absoluteURL,
                let files = URL(string: "download/\(entry.tag)/", relativeTo: base)?.absoluteURL
            else { return nil }
            return ReleaseInfo(
                version: version, title: entry.title, page: page,
                diskImage: files.appendingPathComponent("LangSwitch-\(version).dmg"),
                checksums: files.appendingPathComponent("SHA256SUMS.txt"))
        }
    }

    /// Releases newer than `current`, the newest first.
    package static func updates(in releases: [ReleaseInfo], newerThan current: AppVersion) -> [ReleaseInfo] {
        releases.filter { $0.version > current }.sorted { $0.version > $1.version }
    }

    /// The SHA-256 digest listed for a file in a `shasum`-style list ("<digest>  <name>").
    package static func checksum(for name: String, in list: String) -> String? {
        for line in list.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2, let digest = fields.first, digest.count == 64,
                digest.allSatisfy(\.isHexDigit)
            else { continue }
            // `shasum` marks binary mode with an asterisk before the name.
            let listed = fields.dropFirst().joined(separator: " ").drop(while: { $0 == "*" })
            if listed == name { return digest.lowercased() }
        }
        return nil
    }
}
