//  Tempo/TempoSyncView.swift - created by Travis Luckenbaugh on 1/10/26.

import SwiftUI
import HealthKit

actor Semaphore {
    private var count: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    
    init(_ count: Int) { self.count = count }
    
    func wait() async {
        if count > 0 {
            count -= 1
        } else {
            await withCheckedContinuation { waiters.append($0) }
        }
    }
    
    func signal() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            count += 1
        }
    }
}

struct TempoSyncMetricProgressState {
    let type: String
    let status: String
    let current: Int
    let total: Int
    
    var isComplete: Bool { status == "C" || status == "E" || status == "X" }
}

struct TempoSyncView: View {
    @StateObject var healthKit = HealthKitManager()
    @State var healthKitMetrics = [TempoSyncMetricProgressState]()
    @State private var syncTask: Task<Void, Never>?
    
    var syncNotActive: Bool {
        healthKitMetrics.isEmpty || healthKitMetrics.allSatisfy(\.isComplete)
    }
    
    @MainActor func replaceState(_ metric: TempoSyncMetricProgressState) {
        healthKitMetrics = healthKitMetrics.map {
            return $0.type == metric.type ? metric : $0
        }
    }
    
    @MainActor func replaceState(type: String, status: String, current: Int, total: Int) {
        replaceState(TempoSyncMetricProgressState(type: type, status: status, current: current, total: total))
    }
    
    var body: some View {
        NavigationStack {
            Group {
                if healthKitMetrics.isEmpty {
                    VStack {
                        Button("Sync to Server") {
                            Task {
                                await syncData()
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    List(healthKitMetrics, id: \.type) { metric in
                        HStack {
                            Text(friendlyName(for: metric.type))
                                .font(.headline)
                            Spacer()
                                
                            if metric.total > 0 {
                                Text("\(metric.status) \(metric.current)/\(metric.total)").font(.subheadline)
                            } else {
                                Text("\(metric.status)").font(.subheadline)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Uploader")
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
        .tabItem { Label("Sync", systemImage: syncNotActive ? "arrow.clockwise" : "hourglass.circle") }
    }
    
    func syncData() async {
        let workerSemaphore = Semaphore(4)
        let sampleTypes = healthKit.typesToRead.sorted {
            friendlyName(for: $0.identifier) < friendlyName(for: $1.identifier)
        }.compactMap { $0 as? HKSampleType }
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        healthKitMetrics = sampleTypes.map {
            TempoSyncMetricProgressState(type: $0.identifier, status: "W", current: 0, total: 0)
        }
        syncTask = Task {
            var tasks: [Task<Void, Never>] = []
            for sampleType in sampleTypes {
                let task = Task {
                    do {
                        await workerSemaphore.wait()
                        defer { Task { await workerSemaphore.signal() } }
                        replaceState(type: sampleType.identifier, status: "F", current: 0, total: 0)
                        guard syncTask?.isCancelled == false else { throw CancellationError() }
                        let predicate = HKQuery.predicateForSamples(withStart: thirtyDaysAgo, end: Date())
                        let qSamples = try await healthKit.fetchSamples(sampleType: sampleType, predicate: predicate)
                        
                        replaceState(type: sampleType.identifier, status: "U", current: 0, total: qSamples.count)
                        guard syncTask?.isCancelled == false else { throw CancellationError() }
                        let hSamples = qSamples.map(HealthSample.init)
                        try await syncSamplesToServer(hSamples) {
                            replaceState(type: sampleType.identifier, status: "U", current: $0, total: $1)
                        }
                        
                        replaceState(type: sampleType.identifier, status: "C", current: qSamples.count, total: qSamples.count)
                    } catch is CancellationError {
                        replaceState(type: sampleType.identifier, status: "X", current: 0, total: 0)
                    } catch {
                        replaceState(type: sampleType.identifier, status: "E", current: 0, total: 0)
                        syncTask?.cancel()
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

func syncSamplesToServer(_ samples: [HealthSample], onProgress: ((Int, Int) -> Void)? = nil) async throws {
    guard let url = URL(string: serverEndpoint) else { return }
    let batchSize = 4000
    var totalSynced = 0
    
    // Split into batches
    let batches = stride(from: 0, to: samples.count, by: batchSize).map {
        Array(samples[$0..<min($0 + batchSize, samples.count)])
    }
    
    await MainActor.run {
        onProgress?(0, samples.count)
    }
    
    for batch in batches {
        // Check for cancellation
        try Task.checkCancellation()
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = try encoder.encode(batch)
        
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
        totalSynced += syncResponse.stored
        
        await MainActor.run {
            onProgress?(totalSynced, samples.count)
        }
    }
    
    await MainActor.run {
        onProgress?(totalSynced, samples.count)
    }
}
