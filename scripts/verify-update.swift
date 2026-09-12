import Foundation
import CryptoKit

// Verification uses only the public key. It never opens the Keychain.
final class EnclosureReader: NSObject, XMLParserDelegate {
    var enclosures: [[String: String]] = []
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        if elementName == "enclosure" { enclosures.append(attributes) }
    }
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: "ProfileDock verification", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

do {
    let args = CommandLine.arguments
    try require(args.count == 4, "Usage: swift scripts/verify-update.swift APPCAST ARCHIVE PUBLIC_KEY")
    let feed = try Data(contentsOf: URL(fileURLWithPath: args[1]))
    let archive = try Data(contentsOf: URL(fileURLWithPath: args[2]))
    guard let keyData = Data(base64Encoded: args[3]) else { throw CocoaError(.fileReadCorruptFile) }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    let marker = Data("<!-- sparkle-signatures:".utf8)
    guard let range = feed.range(of: marker, options: .backwards),
          let trailer = String(data: feed[range.lowerBound...], encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
    let regex = try NSRegularExpression(pattern: #"\A<!-- sparkle-signatures:\s*edSignature: ([A-Za-z0-9+/=]+)\s*length: ([0-9]+)\s*-->\s*\z"#)
    guard let match = regex.firstMatch(in: trailer, range: NSRange(trailer.startIndex..., in: trailer)),
          let signatureRange = Range(match.range(at: 1), in: trailer),
          let lengthRange = Range(match.range(at: 2), in: trailer),
          let signature = Data(base64Encoded: String(trailer[signatureRange])),
          let length = Int(trailer[lengthRange]) else { throw CocoaError(.fileReadCorruptFile) }
    try require(length == range.lowerBound, "Feed signature length does not match its content")
    let verifiedXML = feed.prefix(length)
    try require(key.isValidSignature(signature, for: verifiedXML), "Invalid feed signature")
    let reader = EnclosureReader(), parser = XMLParser(data: verifiedXML)
    parser.delegate = reader
    try require(parser.parse(), "Invalid feed XML")
    try require(reader.enclosures.count == 1, "Expected exactly one full release archive")
    let enclosure = reader.enclosures[0]
    guard let encoded = enclosure["sparkle:edSignature"], let archiveSignature = Data(base64Encoded: encoded) else { throw CocoaError(.fileReadCorruptFile) }
    try require(Int(enclosure["length"] ?? "") == archive.count, "Archive length does not match the feed")
    try require(key.isValidSignature(archiveSignature, for: archive), "Invalid archive signature")
    print("Feed and archive signatures verified using the public key; no Keychain access.")
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
