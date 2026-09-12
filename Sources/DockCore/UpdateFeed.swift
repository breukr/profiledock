import Foundation

public struct VendorRelease: Equatable, Sendable {
    public let version: String
    public let build: Int
    public let architecture: String
    public let minimumSystemVersion: String
    public let url: URL
    public let length: Int
    public let signature: Data

    public static func allowedDownload(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "persistent.oaistatic.com" && url.port == nil
            && url.user == nil && url.password == nil && url.path.hasPrefix("/codex-app-prod/") && url.pathExtension == "zip"
    }
}

public final class UpdateFeed: NSObject, XMLParserDelegate {
    private var releases: [VendorRelease] = []
    private var values: [String: String] = [:]
    private var enclosure: [String: String] = [:]
    private var element = ""
    private var deltaDepth = 0

    public static func latest(data: Data, architecture: String, systemVersion: String) throws -> VendorRelease? {
        let delegate = UpdateFeed()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { throw parser.parserError ?? CocoaError(.fileReadCorruptFile) }
        return delegate.releases.filter {
            ($0.architecture == architecture || $0.architecture == "universal") && $0.minimumSystemVersion.compare(systemVersion, options: .numeric) != .orderedDescending
        }.max { $0.build < $1.build }
    }

    public func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        element = name
        if name == "item" { values = [:]; enclosure = [:]; deltaDepth = 0 }
        if name == "sparkle:deltas" { deltaDepth += 1 }
        if name == "enclosure", deltaDepth == 0, enclosure.isEmpty { enclosure = attributes }
    }
    public func parser(_ parser: XMLParser, foundCharacters string: String) { values[element, default: ""] += string }
    public func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "sparkle:deltas" { deltaDepth -= 1 }
        guard name == "item", let build = Int(value("sparkle:version")),
              let url = URL(string: enclosure["url"] ?? ""), VendorRelease.allowedDownload(url),
              let length = Int(enclosure["length"] ?? ""), length > 0, length < 2_000_000_000,
              let signature = Data(base64Encoded: enclosure["sparkle:edSignature"] ?? ""), signature.count == 64 else { return }
        releases.append(VendorRelease(version: value("sparkle:shortVersionString"), build: build, architecture: value("sparkle:hardwareRequirements"), minimumSystemVersion: value("sparkle:minimumSystemVersion"), url: url, length: length, signature: signature))
    }
    private func value(_ key: String) -> String { values[key, default: ""].trimmingCharacters(in: .whitespacesAndNewlines) }
}
