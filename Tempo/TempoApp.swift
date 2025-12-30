//  Tempo/TempoApp.swift - created by Travis Luckenbaugh on 12/28/25.

import Foundation
import HealthKit
import SwiftUI
import Combine

class HealthKitManager: ObservableObject {
    let healthStore = HKHealthStore()
    
    @Published var isAuthorized = false
    @Published var latestHeartRate: Double?
    @Published var restingHeartRate: Double?
    
    let typesToRead: Set<HKObjectType> = [
        HKObjectType.quantityType(forIdentifier: .heartRate)!,
        HKObjectType.quantityType(forIdentifier: .restingHeartRate)!,
        HKObjectType.quantityType(forIdentifier: .bodyMass)!,
        HKObjectType.quantityType(forIdentifier: .stepCount)!,
        HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!,
//        HKObjectType.workoutType()
    ]
    
    func requestAuthorization() async throws {
        try await healthStore.requestAuthorization(toShare: [], read: typesToRead)
        await MainActor.run {
            isAuthorized = true
        }
    }
    
    func fetchLatestHeartRate() async throws {
        let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        
        let query = HKSampleQuery(
            sampleType: heartRateType,
            predicate: nil,
            limit: 1,
            sortDescriptors: [sortDescriptor]
        ) { _, samples, error in
            guard let samples = samples as? [HKQuantitySample],
                  let sample = samples.first else { return }
            
            let bpm = sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
            
            Task { @MainActor in
                self.latestHeartRate = bpm
            }
        }
        
        healthStore.execute(query)
    }
    
    func fetchSamples(sampleType: HKSampleType, predicate: NSPredicate?, limit: Int = HKObjectQueryNoLimit, sortDescriptors: [NSSortDescriptor]? = nil) async throws -> [HKQuantitySample] {
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: sampleType,
                predicate: predicate,
                limit: limit,
                sortDescriptors: sortDescriptors
            ) { (_query: HKSampleQuery, samples: [HKSample]?, error: (any Error)?) in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                if let samples = samples as? [HKQuantitySample] {
                    continuation.resume(returning: samples)
                } else {
                    continuation.resume(returning: [])
                }
            }
            healthStore.execute(query)
        }
    }
    
    func fetchHistoricalBatch(sampleType: HKSampleType, beforeDate: Date) async throws -> [HKQuantitySample] {
        let predicate = HKQuery.predicateForSamples(withStart: .distantPast, end: beforeDate, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(keyPath: \HKQuantitySample.endDate, ascending: false)
        return try await fetchSamples(sampleType: sampleType, predicate: predicate, limit: 500, sortDescriptors: [sortDescriptor])
    }
}

func unit(for type: HKSampleType) -> HKUnit {
    switch type.identifier {
    case HKQuantityTypeIdentifier.heartRate.rawValue:
        return HKUnit.count().unitDivided(by: .minute())
    case HKQuantityTypeIdentifier.restingHeartRate.rawValue:
        return HKUnit.count().unitDivided(by: .minute())
    case HKQuantityTypeIdentifier.bodyMass.rawValue:
        return HKUnit.pound()
    case HKQuantityTypeIdentifier.stepCount.rawValue:
        return HKUnit.count()
    case HKQuantityTypeIdentifier.activeEnergyBurned.rawValue:
        return HKUnit.kilocalorie()
    default:
        return HKUnit.count()
    }
}

struct HealthSample: Codable {
    let uuid: UUID
    let type: String
    let quantity: Double
    let startDate: Date
    let endDate: Date?
    
    init(_ sample: HKQuantitySample) {
        uuid = sample.uuid
        type = sample.sampleType.identifier
        quantity = sample.quantity.doubleValue(for: unit(for: sample.sampleType))
        startDate = sample.startDate
        endDate = sample.endDate
    }
}

let serverEndpoint = "https://tempo.melvis.site/api/health/sync"

struct SyncResponse: Codable {
    let received: Int
    let stored: Int
}

func syncSamplesToServer(_ samples: [HealthSample], onProgress: ((Int, Int) -> Void)? = nil) async throws {
    guard let url = URL(string: serverEndpoint) else { return }
    let batchSize = 500
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

struct SyncProgressView: View {
    @Binding var syncStatus: [(String, String)]
    @Binding var isSyncComplete: Bool
    let onCancel: () -> Void
    let onDone: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            List(syncStatus, id: \.0) { (type, status) in
                HStack {
                    Text(friendlyName(for: type))
                        .font(.headline)
                    Spacer()
                    Text(status)
                        .font(.subheadline)
                }
            }
            
            // Bottom button bar
            HStack(spacing: 12) {
                if isSyncComplete {
                    Button("Done") {
                        onDone()
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                } else {
                    Button("Cancel") {
                        onCancel()
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding()
            .background(Color(UIColor.systemBackground))
        }
    }
    
    private func friendlyName(for identifier: String) -> String {
        switch identifier {
        case "HKQuantityTypeIdentifierHeartRate":
            return "Heart Rate"
        case "HKQuantityTypeIdentifierRestingHeartRate":
            return "Resting Heart Rate"
        case "HKQuantityTypeIdentifierBodyMass":
            return "Body Mass"
        case "HKQuantityTypeIdentifierStepCount":
            return "Step Count"
        case "HKQuantityTypeIdentifierActiveEnergyBurned":
            return "Active Energy"
        default:
            return identifier
        }
    }
}

struct MainView: View {
    @StateObject private var healthKit = HealthKitManager()
    @State private var syncStatus: [(String, String)] = []
    @State private var isRequestingAuth = false
    @State private var syncTask: Task<Void, Never>?
    @State private var isSyncComplete = false
    
    var body: some View {
        if syncStatus.isEmpty {
            VStack(spacing: 20) {
                Text("Tempo")
                    .font(.largeTitle)
                
                if healthKit.isAuthorized {
                    if let hr = healthKit.latestHeartRate {
                        Text("Latest HR: \(Int(hr)) bpm")
                            .font(.title2)
                    } else {
                        Text("No heart rate data")
                    }
                    
                    Button("Fetch Latest HR") {
                        Task {
                            try? await healthKit.fetchLatestHeartRate()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    
                    Button("Sync to Server") {
                        Task {
                            await syncData()
                        }
                    }
                    .buttonStyle(.bordered)
                } else if isRequestingAuth {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Requesting HealthKit access...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Button("Enable HealthKit") {
                        Task {
                            isRequestingAuth = true
                            try? await healthKit.requestAuthorization()
                            isRequestingAuth = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        } else {
            SyncProgressView(
                syncStatus: $syncStatus,
                isSyncComplete: $isSyncComplete,
                onCancel: {
                    syncTask?.cancel()
                    syncStatus = []
                    isSyncComplete = false
                },
                onDone: {
                    syncStatus = []
                    isSyncComplete = false
                }
            )
        }
        
    }
    
    func syncData() async {
        let sampleTypes: [HKSampleType] = healthKit.typesToRead.compactMap { $0 as? HKSampleType }
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        syncStatus = sampleTypes.map { ($0.identifier, "Fetching...") }
        isSyncComplete = false
        
        syncTask = Task {
            var activeTasks: [Task<Void, Never>] = []
            
            for sampleType in sampleTypes {
                let task = Task {
                    do {
                        // Check for cancellation before starting
                        try Task.checkCancellation()
                        
                        let predicate = HKQuery.predicateForSamples(withStart: thirtyDaysAgo, end: Date())
                        let qSamples = try await healthKit.fetchSamples(sampleType: sampleType, predicate: predicate)
                        
                        // Check for cancellation after fetching
                        try Task.checkCancellation()
                        
                        let hSamples = qSamples.map(HealthSample.init)
                        
                        await MainActor.run {
                            syncStatus = syncStatus.map { status in
                                if status.0 == sampleType.identifier {
                                    return (status.0, "Uploading: 0/\(hSamples.count)")
                                } else {
                                    return status
                                }
                            }
                        }
                        
                        try await syncSamplesToServer(hSamples) { (x, y) in
                            syncStatus = syncStatus.map { status in
                                if status.0 == sampleType.identifier {
                                    return (status.0, "Uploading: \(x)/\(y)")
                                } else {
                                    return status
                                }
                            }
                        }
                        
                        await MainActor.run {
                            syncStatus = syncStatus.map { status in
                                if status.0 == sampleType.identifier {
                                    return (status.0, "Complete ✓")
                                } else {
                                    return status
                                }
                            }
                        }
                    } catch is CancellationError {
                        await MainActor.run {
                            syncStatus = syncStatus.map { status in
                                if status.0 == sampleType.identifier {
                                    return (status.0, "Cancelled")
                                } else {
                                    return status
                                }
                            }
                        }
                    } catch {
                        await MainActor.run {
                            syncStatus = syncStatus.map { status in
                                if status.0 == sampleType.identifier {
                                    return (status.0, "Error: \(error.localizedDescription)")
                                } else {
                                    return status
                                }
                            }
                        }
                    }
                }
                activeTasks.append(task)
            }
            
            // Wait for all tasks to complete
            for task in activeTasks {
                await task.value
            }
            
            // Mark sync as complete
            await MainActor.run {
                isSyncComplete = true
            }
        }
    }
}

@main struct TempoApp: App {
    var body: some Scene {
        WindowGroup {
            MainView()
        }
    }
}
