//  Tempo/TempoApp.swift - created by Travis Luckenbaugh on 12/28/25.

import Foundation
import HealthKit
import SwiftUI
import Combine

struct HealthSample: Codable {
    let uuid: UUID
    let type: String
    let quantity: Double
    let startDate: Date
    let endDate: Date?
}

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
        HKObjectType.workoutType()
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
    
    func fetchHistoricalData() async throws -> [HealthSample] {
        var samples: [HealthSample] = []
        
        // Fetch heart rate samples from last 30 days
        let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        let predicate = HKQuery.predicateForSamples(withStart: thirtyDaysAgo, end: Date())
        
        let heartRateSamples = try await fetchSamples(type: heartRateType, predicate: predicate)
        samples.append(contentsOf: heartRateSamples)
        
        // TODO: Add weight, workouts, RHR, steps, etc.
        
        return samples
    }
    
    private func fetchSamples(type: HKQuantityType, predicate: NSPredicate) async throws -> [HealthSample] {
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: true)]
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let samples = samples as? [HKQuantitySample] else {
                    continuation.resume(returning: [])
                    return
                }
                
                let healthSamples = samples.map { sample in
                    HealthSample(
                        uuid: sample.uuid,
                        type: type.identifier,
                        quantity: sample.quantity.doubleValue(for: self.unit(for: type)),
                        startDate: sample.startDate,
                        endDate: sample.endDate
                    )
                }
                
                continuation.resume(returning: healthSamples)
            }
            
            healthStore.execute(query)
        }
    }
    
    private func unit(for type: HKQuantityType) -> HKUnit {
        switch type.identifier {
        case HKQuantityTypeIdentifier.heartRate.rawValue:
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
}

let serverEndpoint = "https://tempo.melvis.site/api/health/sync"

struct SyncResponse: Codable {
    let received: Int
    let stored: Int
}

func syncSamplesToServer(_ samples: [HealthSample]) async throws -> Int {
    guard let url = URL(string: serverEndpoint) else { return 0 }
    let batchSize = 500
    var totalSynced = 0
    
    // Split into batches
    let batches = stride(from: 0, to: samples.count, by: batchSize).map {
        Array(samples[$0..<min($0 + batchSize, samples.count)])
    }
    
    print("Syncing \(samples.count) samples in \(batches.count) batches...")
    
    for (index, batch) in batches.enumerated() {
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
        
        print("Batch \(index + 1)/\(batches.count): stored \(syncResponse.stored) samples")
    }
    
    return totalSynced
}

struct MainView: View {
    @StateObject private var healthKit = HealthKitManager()
    @State private var syncStatus = "Not synced"
    @State private var isRequestingAuth = false
    
    var body: some View {
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
                
                Text(syncStatus)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
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
    }
    
    func syncData() async {
        syncStatus = "Syncing..."
        
        do {
            let samples = try await healthKit.fetchHistoricalData()
            let count = try await syncSamplesToServer(samples)
            syncStatus = "Success: \(count) sent"
        } catch {
            syncStatus = "Error: \(error.localizedDescription)"
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
