// Mose's Sparkle feed (appcast.xml in the repository root, served from
// https://raw.githubusercontent.com/ye-we/mose/main/appcast.xml): the text of
// one release's <item>, adding it to the feed, and the version rules a new
// release must follow. Pure Foundation, so scripts/run-sketch-tests.sh tests
// it; scripts/appcast/main.swift is the command scripts/publish-release.sh runs.
import Foundation

struct AppcastRelease: Equatable {
    /// MARKETING_VERSION, shown to people ("1.2").
    var shortVersionString: String
    /// CURRENT_PROJECT_VERSION, the build number Sparkle compares. It must go
    /// up with every release, or nobody is offered the new one.
    var buildNumber: Int
    var publicationDate: Date
    var dmgURL: String
    var dmgLengthInBytes: Int
    /// sign_update's EdDSA signature of the DMG, base64.
    var edSignature: String
    var minimumSystemVersion: String
    /// The GitHub release page.
    var releaseNotesPageURL: String
    /// Markdown, shown in Sparkle's update window (Sparkle 2.9+, sparkle:format="markdown").
    var releaseNotesMarkdown: String
}

struct AppcastItemSummary: Equatable {
    var shortVersionString: String?
    var buildNumber: String
}

enum AppcastError: Error, Equatable, CustomStringConvertible {
    case notAnAppcast(String)
    case buildNumberNotNew(newBuildNumber: Int, highestExistingBuildNumber: Int)
    case versionAlreadyListed(String)
    case missingField(String)

    var description: String {
        switch self {
        case .notAnAppcast(let reason):
            return "appcast.xml isn't a Sparkle feed: \(reason)"
        case .buildNumberNotNew(let newBuildNumber, let highestExistingBuildNumber):
            return "build \(newBuildNumber) isn't higher than build \(highestExistingBuildNumber), already in the feed; Sparkle would never offer it"
        case .versionAlreadyListed(let shortVersionString):
            return "version \(shortVersionString) is already in the feed"
        case .missingField(let fieldName):
            return "the release has no \(fieldName)"
        }
    }
}

enum Appcast {
    static let sparkleNamespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"

    /// A feed with no releases yet, for a fresh appcast.xml.
    static func emptyFeedText(title: String, websiteURL: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="\(sparkleNamespace)">
            <channel>
                <title>\(escapedXMLText(title))</title>
                <link>\(escapedXMLText(websiteURL))</link>
                <description>New versions of \(escapedXMLText(title)). The app checks this feed about once a day.</description>
                <language>en</language>
            </channel>
        </rss>

        """
    }

    /// RFC 822 dates, as RSS and Sparkle expect ("Mon, 09 Nov 2026 14:03:00 +0000").
    static func rssDateText(_ date: Date) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return dateFormatter.string(from: date)
    }

    static func itemText(for release: AppcastRelease) throws -> String {
        let requiredFields: [(String, String)] = [
            ("version", release.shortVersionString),
            ("DMG URL", release.dmgURL),
            ("EdDSA signature", release.edSignature),
            ("minimum macOS version", release.minimumSystemVersion),
            ("release notes link", release.releaseNotesPageURL),
        ]
        for (fieldName, fieldValue) in requiredFields where fieldValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AppcastError.missingField(fieldName)
        }
        guard release.dmgLengthInBytes > 0 else { throw AppcastError.missingField("DMG length") }
        guard release.buildNumber > 0 else { throw AppcastError.missingField("build number") }

        // The notes go in CDATA so markdown needs no escaping; a literal
        // "]]>" in them would end the section early, so it's split in two.
        let releaseNotesForCDATA = release.releaseNotesMarkdown
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "]]>", with: "]]]]><![CDATA[>")

        return """
                <item>
                    <title>Version \(escapedXMLText(release.shortVersionString))</title>
                    <link>\(escapedXMLText(release.releaseNotesPageURL))</link>
                    <pubDate>\(rssDateText(release.publicationDate))</pubDate>
                    <sparkle:version>\(release.buildNumber)</sparkle:version>
                    <sparkle:shortVersionString>\(escapedXMLText(release.shortVersionString))</sparkle:shortVersionString>
                    <sparkle:minimumSystemVersion>\(escapedXMLText(release.minimumSystemVersion))</sparkle:minimumSystemVersion>
                    <description sparkle:format="markdown"><![CDATA[
        \(releaseNotesForCDATA)
        ]]></description>
                    <enclosure url="\(escapedXMLAttribute(release.dmgURL))" length="\(release.dmgLengthInBytes)" type="application/octet-stream" sparkle:edSignature="\(escapedXMLAttribute(release.edSignature))"/>
                </item>

        """
    }

    /// The releases already in a feed, newest first as written.
    static func itemSummaries(inFeedText feedText: String) throws -> [AppcastItemSummary] {
        let feedDocument: XMLDocument
        do {
            feedDocument = try XMLDocument(xmlString: feedText, options: [])
        } catch {
            throw AppcastError.notAnAppcast("it isn't valid XML (\(error.localizedDescription))")
        }
        guard let channelElement = try feedDocument.nodes(forXPath: "/rss/channel").first as? XMLElement else {
            throw AppcastError.notAnAppcast("there's no <rss><channel>")
        }
        return channelElement.elements(forName: "item").map { itemElement in
            AppcastItemSummary(
                shortVersionString: itemElement.elements(forLocalName: "shortVersionString", uri: sparkleNamespace).first?.stringValue,
                buildNumber: itemElement.elements(forLocalName: "version", uri: sparkleNamespace).first?.stringValue ?? ""
            )
        }
    }

    /// The feed with the new release added first in the channel. Refuses a
    /// build number that isn't higher than every one already listed (Sparkle
    /// compares build numbers, so a lower one would never be offered) and a
    /// version that's already there.
    static func feedText(_ feedText: String, addingItemFor release: AppcastRelease) throws -> String {
        let existingItemSummaries = try itemSummaries(inFeedText: feedText)
        if existingItemSummaries.contains(where: { $0.shortVersionString == release.shortVersionString }) {
            throw AppcastError.versionAlreadyListed(release.shortVersionString)
        }
        let highestExistingBuildNumber = existingItemSummaries.compactMap { Int($0.buildNumber) }.max() ?? 0
        if release.buildNumber <= highestExistingBuildNumber {
            throw AppcastError.buildNumberNotNew(newBuildNumber: release.buildNumber, highestExistingBuildNumber: highestExistingBuildNumber)
        }

        let newItemText = try itemText(for: release)
        let insertionIndex: String.Index
        if let firstItemRange = feedText.range(of: "<item>") {
            // Back up to the start of that line, so the indentation stays tidy.
            insertionIndex = feedText[..<firstItemRange.lowerBound].lastIndex(of: "\n").map { feedText.index(after: $0) } ?? firstItemRange.lowerBound
        } else if let channelEndRange = feedText.range(of: "</channel>") {
            insertionIndex = feedText[..<channelEndRange.lowerBound].lastIndex(of: "\n").map { feedText.index(after: $0) } ?? channelEndRange.lowerBound
        } else {
            throw AppcastError.notAnAppcast("there's no </channel>")
        }
        var updatedFeedText = feedText
        updatedFeedText.insert(contentsOf: newItemText, at: insertionIndex)
        return updatedFeedText
    }

    /// sign_update prints `sparkle:edSignature="…" length="…"`.
    static func signatureAndLength(fromSignUpdateOutput signUpdateOutput: String) -> (edSignature: String, lengthInBytes: Int)? {
        guard let edSignature = attributeValue(named: "sparkle:edSignature", in: signUpdateOutput),
              let lengthText = attributeValue(named: "length", in: signUpdateOutput),
              let lengthInBytes = Int(lengthText),
              !edSignature.isEmpty else {
            return nil
        }
        return (edSignature, lengthInBytes)
    }

    private static func attributeValue(named attributeName: String, in text: String) -> String? {
        guard let attributeStart = text.range(of: "\(attributeName)=\"") else { return nil }
        let valueStart = attributeStart.upperBound
        guard let valueEnd = text[valueStart...].firstIndex(of: "\"") else { return nil }
        return String(text[valueStart..<valueEnd])
    }

    static func escapedXMLText(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func escapedXMLAttribute(_ text: String) -> String {
        escapedXMLText(text).replacingOccurrences(of: "\"", with: "&quot;")
    }
}
