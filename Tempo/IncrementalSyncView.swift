//  Tempo/IncrementalSyncView.swift - created by Travis Luckenbaugh on 1/13/26.

import SwiftUI
import HealthKit

// MARK: - Data Models

struct WatermarkSample: Codable {
    let type: String
    let endDate: String
}

struct StatusResponse: Codable {
    let samples: [WatermarkSample]
}

// MARK: - Progress State

struct IncrementalSyncMetricProgressState {
    let type: String
    let status: String
    let current: Int
    let total: Int?
    let cursor: Date?

    var isComplete: Bool { status == "C" || status == "E" || status == "X" }
}

// MARK: - HealthKit Extension

extension HealthKitManager {
    func fetchIncrementalBatch(
        sampleType: HKSampleType,
        cursor: Date,
        limit: Int = 1000
    ) async throws -> [HKQuantitySample] {
        let predicate = HKQuery.predicateForSamples(
            withStart: cursor,
            end: Date(),
            options: .strictStartDate
        )
        let sortDescriptor = NSSortDescriptor(
            key: HKSampleSortIdentifierStartDate,
            ascending: true
        )
        return try await fetchSamples(
            sampleType: sampleType,
            predicate: predicate,
            limit: limit,
            sortDescriptors: [sortDescriptor]
        )
    }
}

// MARK: - API Client

let statusEndpoint = "https://tempo.melvis.site/api/health/status"

func fetchWatermarks() async throws -> [String: Date] {
    guard let url = URL(string: statusEndpoint) else {
        throw URLError(.badURL)
    }

    let (data, response) = try await URLSession.shared.data(from: url)

    guard let httpResponse = response as? HTTPURLResponse,
          httpResponse.statusCode == 200 else {
        throw URLError(.badServerResponse)
    }

    let statusResponse = try JSONDecoder().decode(StatusResponse.self, from: data)

    var watermarks: [String: Date] = [:]
    let dateFormatter = ISO8601DateFormatter()
    for sample in statusResponse.samples {
        if let date = dateFormatter.date(from: sample.endDate) {
            watermarks[sample.type] = date
        }
    }

    return watermarks
}

func syncIncrementalBatch(
    _ samples: [HealthSample],
    onProgress: ((Int) -> Void)? = nil
) async throws -> SyncResponse {
    guard let url = URL(string: serverEndpoint) else {
        throw URLError(.badURL)
    }

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let payload = try encoder.encode(samples)

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = payload

    let (data, response) = try await URLSession.shared.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse,
          httpResponse.statusCode == 200 else {
        throw URLError(.badServerResponse)
    }

    let syncResponse = try JSONDecoder().decode(SyncResponse.self, from: data)

    await MainActor.run {
        onProgress?(syncResponse.stored)
    }

    return syncResponse
}

// MARK: - Incremental Sync View

struct IncrementalSyncView: View {
    @StateObject var healthKit = HealthKitManager()
    @State var healthKitMetrics = [IncrementalSyncMetricProgressState]()
    @State private var syncTask: Task<Void, Never>?

    var syncNotActive: Bool {
        healthKitMetrics.isEmpty || healthKitMetrics.allSatisfy(\.isComplete)
    }

    @MainActor func replaceState(_ metric: IncrementalSyncMetricProgressState) {
        healthKitMetrics = healthKitMetrics.map {
            return $0.type == metric.type ? metric : $0
        }
    }

    @MainActor func replaceState(type: String, status: String, current: Int, total: Int?, cursor: Date?) {
        replaceState(IncrementalSyncMetricProgressState(
            type: type,
            status: status,
            current: current,
            total: total,
            cursor: cursor
        ))
    }

    var body: some View {
        NavigationStack {
            Group {
                if healthKitMetrics.isEmpty {
                    VStack {
                        Button("Start Incremental Sync") {
                            Task {
                                await syncData()
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    List(healthKitMetrics, id: \.type) { metric in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(friendlyName(for: metric.type))
                                    .font(.headline)
                                Spacer()

                                if let total = metric.total, total > 0 {
                                    Text("\(metric.status) \(metric.current)/\(total)")
                                        .font(.subheadline)
                                } else {
                                    Text("\(metric.status) \(metric.current)")
                                        .font(.subheadline)
                                }
                            }

                            if let cursor = metric.cursor {
                                Text("Cursor: \(cursor, style: .date) \(cursor, style: .time)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle("Incremental Sync")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !healthKitMetrics.isEmpty {
                        if syncNotActive {
                            Button("Sync") {
                                Task { await syncData() }
                            }
                        } else {
                            Button("Cancel") {
                                syncTask?.cancel()
                            }
                        }
                    }
                }
            }
        }
        .tabItem {
            Label("Incremental", systemImage: syncNotActive ? "arrow.triangle.2.circlepath" : "hourglass.circle")
        }
    }

    func syncData() async {
        let workerSemaphore = Semaphore(4)
        let sampleTypes = healthKit.typesToRead.sorted {
            friendlyName(for: $0.identifier) < friendlyName(for: $1.identifier)
        }.compactMap { $0 as? HKSampleType }

        // Initialize progress state
        healthKitMetrics = sampleTypes.map {
            IncrementalSyncMetricProgressState(
                type: $0.identifier,
                status: "W",
                current: 0,
                total: nil,
                cursor: nil
            )
        }

        syncTask = Task {
            // Fetch watermarks from server
            var serverWatermarks: [String: Date] = [:]
            do {
                serverWatermarks = try await fetchWatermarks()
            } catch {
                print("Failed to fetch watermarks: \(error)")
            }

            var tasks: [Task<Void, Never>] = []
            for sampleType in sampleTypes {
                let task = Task {
                    do {
                        await workerSemaphore.wait()
                        defer { Task { await workerSemaphore.signal() } }

                        // Get watermark from server, or .distantPast if none
                        let cursor = serverWatermarks[sampleType.identifier] ?? .distantPast

                        replaceState(
                            type: sampleType.identifier,
                            status: "F",
                            current: 0,
                            total: nil,
                            cursor: cursor
                        )

                        // Fetch and upload in batches
                        var currentCursor = cursor
                        var totalSynced = 0

                        while !Task.isCancelled {
                            // Fetch batch from HealthKit
                            guard syncTask?.isCancelled == false else { throw CancellationError() }

                            let qSamples = try await healthKit.fetchIncrementalBatch(
                                sampleType: sampleType,
                                cursor: currentCursor,
                                limit: 1000
                            )

                            // Stop if batch is not full
                            if qSamples.isEmpty {
                                break
                            }

                            replaceState(
                                type: sampleType.identifier,
                                status: "U",
                                current: totalSynced,
                                total: nil,
                                cursor: currentCursor
                            )

                            // Upload batch
                            guard syncTask?.isCancelled == false else { throw CancellationError() }

                            let hSamples = qSamples.map(HealthSample.init)
                            let syncResponse = try await syncIncrementalBatch(hSamples) { stored in
                                // Progress callback (optional)
                            }

                            totalSynced += syncResponse.stored

                            // Advance cursor to last sample's endDate
                            if let lastSample = qSamples.last {
                                currentCursor = lastSample.endDate
                            }

                            replaceState(
                                type: sampleType.identifier,
                                status: "U",
                                current: totalSynced,
                                total: nil,
                                cursor: currentCursor
                            )

                            // Stop after upload when batch is not full
                            if qSamples.count < 1000 {
                                break
                            }
                        }

                        replaceState(
                            type: sampleType.identifier,
                            status: "C",
                            current: totalSynced,
                            total: totalSynced,
                            cursor: currentCursor
                        )
                    } catch is CancellationError {
                        replaceState(
                            type: sampleType.identifier,
                            status: "X",
                            current: 0,
                            total: nil,
                            cursor: nil
                        )
                    } catch {
                        print("Error syncing \(sampleType.identifier): \(error)")
                        replaceState(
                            type: sampleType.identifier,
                            status: "E",
                            current: 0,
                            total: nil,
                            cursor: nil
                        )
                        // Don't cancel all tasks on individual errors
                    }
                }
                tasks.append(task)
            }

            for task in tasks {
                await task.value
            }
        }
    }
}
