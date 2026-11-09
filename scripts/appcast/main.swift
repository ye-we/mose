// The appcast command scripts/publish-release.sh runs (built with swiftc
// together with Appcast.swift):
//
//   appcast add --feed appcast.xml --version 1.2 --build 4 --dmg-url URL
//               --sign-update-output 'sparkle:edSignature="…" length="…"'
//               --notes-file notes.md --notes-page URL [--minimum-macos 14.2]
//   appcast list --feed appcast.xml
//   appcast empty --feed appcast.xml --title Mose --website URL
import Foundation

func exitWithError(_ message: String) -> Never {
    FileHandle.standardError.write(Data("appcast: \(message)\n".utf8))
    exit(1)
}

func optionValues(from commandLineArguments: [String]) -> [String: String] {
    var optionValuesByName: [String: String] = [:]
    var argumentIndex = 0
    while argumentIndex < commandLineArguments.count {
        let argument = commandLineArguments[argumentIndex]
        guard argument.hasPrefix("--"), argumentIndex + 1 < commandLineArguments.count else {
            exitWithError("unexpected argument \(argument)")
        }
        optionValuesByName[String(argument.dropFirst(2))] = commandLineArguments[argumentIndex + 1]
        argumentIndex += 2
    }
    return optionValuesByName
}

func requiredOption(_ optionName: String, in optionValuesByName: [String: String]) -> String {
    guard let optionValue = optionValuesByName[optionName], !optionValue.isEmpty else {
        exitWithError("missing --\(optionName)")
    }
    return optionValue
}

let commandLineArguments = Array(CommandLine.arguments.dropFirst())
guard let subcommand = commandLineArguments.first else {
    exitWithError("usage: appcast add|list|empty --feed appcast.xml …")
}
let optionValuesByName = optionValues(from: Array(commandLineArguments.dropFirst()))
let feedPath = requiredOption("feed", in: optionValuesByName)

switch subcommand {
case "empty":
    let emptyFeedText = Appcast.emptyFeedText(
        title: requiredOption("title", in: optionValuesByName),
        websiteURL: requiredOption("website", in: optionValuesByName)
    )
    do {
        try emptyFeedText.write(toFile: feedPath, atomically: true, encoding: .utf8)
    } catch {
        exitWithError("couldn't write \(feedPath): \(error.localizedDescription)")
    }

case "list":
    guard let feedText = try? String(contentsOfFile: feedPath, encoding: .utf8) else {
        exitWithError("couldn't read \(feedPath)")
    }
    do {
        for itemSummary in try Appcast.itemSummaries(inFeedText: feedText) {
            print("\(itemSummary.shortVersionString ?? "?") build \(itemSummary.buildNumber)")
        }
    } catch {
        exitWithError("\(error)")
    }

case "add":
    guard let feedText = try? String(contentsOfFile: feedPath, encoding: .utf8) else {
        exitWithError("couldn't read \(feedPath)")
    }
    let notesPath = requiredOption("notes-file", in: optionValuesByName)
    guard let releaseNotesMarkdown = try? String(contentsOfFile: notesPath, encoding: .utf8) else {
        exitWithError("couldn't read \(notesPath)")
    }
    guard let buildNumber = Int(requiredOption("build", in: optionValuesByName)) else {
        exitWithError("--build must be a whole number")
    }
    guard let signatureAndLength = Appcast.signatureAndLength(
        fromSignUpdateOutput: requiredOption("sign-update-output", in: optionValuesByName)
    ) else {
        exitWithError("--sign-update-output doesn't look like sign_update's output")
    }
    let release = AppcastRelease(
        shortVersionString: requiredOption("version", in: optionValuesByName),
        buildNumber: buildNumber,
        publicationDate: Date(),
        dmgURL: requiredOption("dmg-url", in: optionValuesByName),
        dmgLengthInBytes: signatureAndLength.lengthInBytes,
        edSignature: signatureAndLength.edSignature,
        minimumSystemVersion: optionValuesByName["minimum-macos"] ?? "14.2",
        releaseNotesPageURL: requiredOption("notes-page", in: optionValuesByName),
        releaseNotesMarkdown: releaseNotesMarkdown
    )
    do {
        let updatedFeedText = try Appcast.feedText(feedText, addingItemFor: release)
        // Read it back before writing, so a broken feed never reaches people.
        let updatedItemSummaries = try Appcast.itemSummaries(inFeedText: updatedFeedText)
        guard updatedItemSummaries.first == AppcastItemSummary(shortVersionString: release.shortVersionString, buildNumber: String(buildNumber)) else {
            exitWithError("the new item didn't read back as the newest release")
        }
        try updatedFeedText.write(toFile: feedPath, atomically: true, encoding: .utf8)
        print("Added \(release.shortVersionString) (build \(buildNumber)) to \(feedPath)")
    } catch {
        exitWithError("\(error)")
    }

default:
    exitWithError("unknown command \(subcommand)")
}
