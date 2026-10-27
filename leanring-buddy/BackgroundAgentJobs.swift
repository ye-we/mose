//
//  BackgroundAgentJobs.swift
//  leanring-buddy
//
//  Background tasks: when the user asks for real work ("research X and make
//  me a PDF"), Claude answers with an [AGENT:title|brief] tag and Clicky hands
//  the brief to a separate Claude Code session. BackgroundAgentJobRunner runs
//  those inside the app; BackgroundAgentJobsClient sends them to an HTTP
//  bridge instead (local-bridge/server.mjs, /agent/jobs) when CLICKY_BRIDGE_URL
//  is set. This file has the job model, the tag parser, the service both
//  provide and the bridge client; CompanionManager tracks the jobs and the
//  panel lists them.
//

import Foundation

/// One background task as the panel shows it.
struct BackgroundAgentJob: Identifiable, Decodable, Equatable {
    let id: String
    let title: String
    /// "running", "done", "failed", "stopped" or "interrupted" (Clicky quit mid-run).
    let status: String
    let startedAt: String
    let finishedAt: String?
    /// What it's doing right now ("searching the web for ..."), while running.
    let latestProgress: String?
    /// Its final message; the first sentence is what gets read aloud.
    let result: String?
    let folder: String
    let outputFiles: [String]

    var isRunning: Bool { status == "running" }
    var isDone: Bool { status == "done" }

    /// The first sentence of the result, for reading aloud and the panel.
    var resultHeadline: String? {
        guard let result = result?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty else { return nil }
        let markdownFreeResult = result.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "**", with: "")
        if let sentenceEnd = markdownFreeResult.range(of: #"[.!?](\s|$)"#, options: .regularExpression) {
            return String(markdownFreeResult[..<sentenceEnd.upperBound]).trimmingCharacters(in: .whitespaces)
        }
        return markdownFreeResult
    }
}

enum BackgroundAgentTagParser {
    /// Parses "[AGENT:short title|the full brief]". The title is optional; without
    /// one, the first words of the brief stand in. Returns nil if there's no
    /// real brief to hand off.
    static func parseAgentTag(_ tagText: String) -> (title: String, brief: String)? {
        guard let colonIndex = tagText.firstIndex(of: ":"), tagText.hasSuffix("]") else { return nil }
        let tagBody = tagText[tagText.index(after: colonIndex)..<tagText.index(before: tagText.endIndex)]
        let titleAndBrief = tagBody.split(separator: "|", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let brief = titleAndBrief.count == 2 ? titleAndBrief[1] : titleAndBrief.first ?? ""
        guard brief.count >= 12 else { return nil }

        let explicitTitle = titleAndBrief.count == 2 ? titleAndBrief[0] : ""
        let title = explicitTitle.isEmpty
            ? brief.split(separator: " ").prefix(6).joined(separator: " ")
            : explicitTitle
        return (String(title.prefix(60)), brief)
    }
}

/// Starts, lists and stops background tasks.
@MainActor
protocol BackgroundAgentJobService {
    func startJob(title: String, brief: String, screenshotJPEGData: Data?) async throws -> BackgroundAgentJob
    /// Newest first.
    func listJobs() async throws -> [BackgroundAgentJob]
    func stopJob(withID jobID: String) async throws
    /// Clicky is quitting.
    func stopAllRunningJobs()
}

/// Talks to an HTTP bridge's /agent/jobs routes.
struct BackgroundAgentJobsClient: BackgroundAgentJobService {
    let bridgeBaseURL: String

    private struct JobListResponse: Decodable { let jobs: [BackgroundAgentJob] }
    private struct JobResponse: Decodable { let job: BackgroundAgentJob }

    func startJob(title: String, brief: String, screenshotJPEGData: Data?) async throws -> BackgroundAgentJob {
        var requestBody: [String: Any] = ["title": title, "brief": brief]
        if let screenshotJPEGData {
            requestBody["screenshotJPEGBase64"] = screenshotJPEGData.base64EncodedString()
        }
        let responseData = try await postJSON(path: "/agent/jobs", body: requestBody)
        return try JSONDecoder().decode(JobResponse.self, from: responseData).job
    }

    func listJobs() async throws -> [BackgroundAgentJob] {
        guard let jobsURL = URL(string: "\(bridgeBaseURL)/agent/jobs") else { return [] }
        let (responseData, _) = try await URLSession.shared.data(from: jobsURL)
        return try JSONDecoder().decode(JobListResponse.self, from: responseData).jobs
    }

    func stopJob(withID jobID: String) async throws {
        _ = try await postJSON(path: "/agent/jobs/\(jobID)/stop", body: [:])
    }

    /// The bridge's jobs belong to the bridge and keep running.
    func stopAllRunningJobs() {}

    private func postJSON(path: String, body: [String: Any]) async throws -> Data {
        guard let requestURL = URL(string: "\(bridgeBaseURL)\(path)") else { throw URLError(.badURL) }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let errorText = String(data: responseData, encoding: .utf8) ?? "unknown error"
            throw NSError(domain: "BackgroundAgentJobs", code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: errorText])
        }
        return responseData
    }
}
