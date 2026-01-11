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
        // Activity & Fitness
        HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!,
        HKObjectType.quantityType(forIdentifier: .basalEnergyBurned)!,
        HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning)!,
        HKObjectType.quantityType(forIdentifier: .flightsClimbed)!,
        HKObjectType.quantityType(forIdentifier: .stepCount)!,
        HKObjectType.quantityType(forIdentifier: .runningPower)!,

        // Body Measurements
        HKObjectType.quantityType(forIdentifier: .bodyFatPercentage)!,
        HKObjectType.quantityType(forIdentifier: .bodyMass)!,
        HKObjectType.quantityType(forIdentifier: .height)!,
        HKObjectType.quantityType(forIdentifier: .leanBodyMass)!,
        HKObjectType.quantityType(forIdentifier: .waistCircumference)!,

        // Cardiovascular
        HKObjectType.quantityType(forIdentifier: .heartRate)!,
        HKObjectType.quantityType(forIdentifier: .restingHeartRate)!,
        HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!,
        HKObjectType.quantityType(forIdentifier: .bloodPressureSystolic)!,
        HKObjectType.quantityType(forIdentifier: .bloodPressureDiastolic)!,

        // Respiratory
        HKObjectType.quantityType(forIdentifier: .oxygenSaturation)!,
        HKObjectType.quantityType(forIdentifier: .respiratoryRate)!,
        HKObjectType.quantityType(forIdentifier: .vo2Max)!,

        // Temperature
        HKObjectType.quantityType(forIdentifier: .appleSleepingWristTemperature)!,
        HKObjectType.quantityType(forIdentifier: .bodyTemperature)!,

        // Walking & Mobility
        HKObjectType.quantityType(forIdentifier: .appleWalkingSteadiness)!,
        HKObjectType.quantityType(forIdentifier: .sixMinuteWalkTestDistance)!,
        HKObjectType.quantityType(forIdentifier: .stairAscentSpeed)!,
        HKObjectType.quantityType(forIdentifier: .stairDescentSpeed)!,
        HKObjectType.quantityType(forIdentifier: .walkingAsymmetryPercentage)!,
        HKObjectType.quantityType(forIdentifier: .walkingDoubleSupportPercentage)!,
        HKObjectType.quantityType(forIdentifier: .walkingSpeed)!,
        HKObjectType.quantityType(forIdentifier: .walkingStepLength)!,

        // Nutrition
        HKObjectType.quantityType(forIdentifier: .dietaryEnergyConsumed)!,
        HKObjectType.quantityType(forIdentifier: .dietaryProtein)!,
        HKObjectType.quantityType(forIdentifier: .dietaryCarbohydrates)!,
        HKObjectType.quantityType(forIdentifier: .dietaryFiber)!,
        HKObjectType.quantityType(forIdentifier: .dietarySugar)!,
        HKObjectType.quantityType(forIdentifier: .dietaryFatTotal)!,
        HKObjectType.quantityType(forIdentifier: .dietarySodium)!,
        HKObjectType.quantityType(forIdentifier: .dietaryWater)!,

        // Blood Glucose & Metabolic
        HKObjectType.quantityType(forIdentifier: .bloodGlucose)!,
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
    // Activity & Fitness
    case HKQuantityTypeIdentifier.activeEnergyBurned.rawValue: return HKUnit.kilocalorie()
    case HKQuantityTypeIdentifier.basalEnergyBurned.rawValue: return HKUnit.kilocalorie()
    case HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue: return HKUnit.mile()
    case HKQuantityTypeIdentifier.flightsClimbed.rawValue: return HKUnit.count()
    case HKQuantityTypeIdentifier.stepCount.rawValue: return HKUnit.count()
    case HKQuantityTypeIdentifier.runningPower.rawValue: return HKUnit.watt()

    // Body Measurements
    case HKQuantityTypeIdentifier.bodyFatPercentage.rawValue: return HKUnit.percent()
    case HKQuantityTypeIdentifier.bodyMass.rawValue: return HKUnit.pound()
    case HKQuantityTypeIdentifier.height.rawValue: return HKUnit.inch()
    case HKQuantityTypeIdentifier.leanBodyMass.rawValue: return HKUnit.pound()
    case HKQuantityTypeIdentifier.waistCircumference.rawValue: return HKUnit.inch()

    // Cardiovascular
    case HKQuantityTypeIdentifier.heartRate.rawValue: return HKUnit.count().unitDivided(by: .minute())
    case HKQuantityTypeIdentifier.restingHeartRate.rawValue: return HKUnit.count().unitDivided(by: .minute())
    case HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue: return HKUnit.secondUnit(with: .milli)
    case HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue: return HKUnit.millimeterOfMercury()
    case HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue: return HKUnit.millimeterOfMercury()

    // Respiratory
    case HKQuantityTypeIdentifier.oxygenSaturation.rawValue: return HKUnit.percent()
    case HKQuantityTypeIdentifier.respiratoryRate.rawValue: return HKUnit.count().unitDivided(by: .minute())
    case HKQuantityTypeIdentifier.vo2Max.rawValue: return HKUnit.literUnit(with: .milli).unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))

    // Temperature
    case HKQuantityTypeIdentifier.appleSleepingWristTemperature.rawValue: return HKUnit.degreeFahrenheit()
    case HKQuantityTypeIdentifier.bodyTemperature.rawValue: return HKUnit.degreeFahrenheit()

    // Walking & Mobility
    case HKQuantityTypeIdentifier.appleWalkingSteadiness.rawValue: return HKUnit.percent()
    case HKQuantityTypeIdentifier.sixMinuteWalkTestDistance.rawValue: return HKUnit.meter()
    case HKQuantityTypeIdentifier.stairAscentSpeed.rawValue: return HKUnit.meter().unitDivided(by: HKUnit.second())
    case HKQuantityTypeIdentifier.stairDescentSpeed.rawValue: return HKUnit.meter().unitDivided(by: HKUnit.second())
    case HKQuantityTypeIdentifier.walkingAsymmetryPercentage.rawValue: return HKUnit.percent()
    case HKQuantityTypeIdentifier.walkingDoubleSupportPercentage.rawValue: return HKUnit.percent()
    case HKQuantityTypeIdentifier.walkingSpeed.rawValue: return HKUnit.meter().unitDivided(by: HKUnit.second())
    case HKQuantityTypeIdentifier.walkingStepLength.rawValue: return HKUnit.meter()

    // Nutrition
    case HKQuantityTypeIdentifier.dietaryEnergyConsumed.rawValue: return HKUnit.kilocalorie()
    case HKQuantityTypeIdentifier.dietaryProtein.rawValue: return HKUnit.gram()
    case HKQuantityTypeIdentifier.dietaryCarbohydrates.rawValue: return HKUnit.gram()
    case HKQuantityTypeIdentifier.dietaryFiber.rawValue: return HKUnit.gram()
    case HKQuantityTypeIdentifier.dietarySugar.rawValue: return HKUnit.gram()
    case HKQuantityTypeIdentifier.dietaryFatTotal.rawValue: return HKUnit.gram()
    case HKQuantityTypeIdentifier.dietarySodium.rawValue: return HKUnit.gramUnit(with: .milli)
    case HKQuantityTypeIdentifier.dietaryWater.rawValue: return HKUnit.literUnit(with: .milli)

    // Blood Glucose & Metabolic
    case HKQuantityTypeIdentifier.bloodGlucose.rawValue: return HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))

    default:
        assert(false, "WARNING: unit/1 not implemented for (\(type.identifier))")
        return HKUnit.count()
    }
}

func friendlyName(for identifier: String) -> String {
    switch identifier {
    // Activity & Fitness
    case "HKQuantityTypeIdentifierActiveEnergyBurned": return "Active Energy"
    case "HKQuantityTypeIdentifierBasalEnergyBurned": return "Resting Energy"
    case "HKQuantityTypeIdentifierDistanceWalkingRunning": return "Distance"
    case "HKQuantityTypeIdentifierFlightsClimbed": return "Flights Climbed"
    case "HKQuantityTypeIdentifierStepCount": return "Step Count"
    case "HKQuantityTypeIdentifierRunningPower": return "Running Power"

    // Body Measurements
    case "HKQuantityTypeIdentifierBodyFatPercentage": return "Body Fat %"
    case "HKQuantityTypeIdentifierBodyMass": return "Weight"
    case "HKQuantityTypeIdentifierHeight": return "Height"
    case "HKQuantityTypeIdentifierLeanBodyMass": return "Lean Body Mass"
    case "HKQuantityTypeIdentifierWaistCircumference": return "Waist Circumference"

    // Cardiovascular
    case "HKQuantityTypeIdentifierHeartRate": return "Heart Rate"
    case "HKQuantityTypeIdentifierRestingHeartRate": return "Resting Heart Rate"
    case "HKQuantityTypeIdentifierHeartRateVariabilitySDNN": return "HRV (SDNN)"
    case "HKQuantityTypeIdentifierBloodPressureSystolic": return "Blood Pressure (Systolic)"
    case "HKQuantityTypeIdentifierBloodPressureDiastolic": return "Blood Pressure (Diastolic)"

    // Respiratory
    case "HKQuantityTypeIdentifierOxygenSaturation": return "Blood Oxygen"
    case "HKQuantityTypeIdentifierRespiratoryRate": return "Respiratory Rate"
    case "HKQuantityTypeIdentifierVO2Max": return "VO2 Max"

    // Temperature
    case "HKQuantityTypeIdentifierAppleSleepingWristTemperature": return "Wrist Temperature"
    case "HKQuantityTypeIdentifierBodyTemperature": return "Body Temperature"

    // Walking & Mobility
    case "HKQuantityTypeIdentifierAppleWalkingSteadiness": return "Walking Steadiness"
    case "HKQuantityTypeIdentifierSixMinuteWalkTestDistance": return "Six-Minute Walk"
    case "HKQuantityTypeIdentifierStairAscentSpeed": return "Stair Speed: Up"
    case "HKQuantityTypeIdentifierStairDescentSpeed": return "Stair Speed: Down"
    case "HKQuantityTypeIdentifierWalkingAsymmetryPercentage": return "Walking Asymmetry %"
    case "HKQuantityTypeIdentifierWalkingDoubleSupportPercentage": return "Double Support Time"
    case "HKQuantityTypeIdentifierWalkingSpeed": return "Walking Speed"
    case "HKQuantityTypeIdentifierWalkingStepLength": return "Step Length"

    // Nutrition
    case "HKQuantityTypeIdentifierDietaryEnergyConsumed": return "Calories Consumed"
    case "HKQuantityTypeIdentifierDietaryProtein": return "Protein"
    case "HKQuantityTypeIdentifierDietaryCarbohydrates": return "Carbohydrates"
    case "HKQuantityTypeIdentifierDietaryFiber": return "Fiber"
    case "HKQuantityTypeIdentifierDietarySugar": return "Sugar"
    case "HKQuantityTypeIdentifierDietaryFatTotal": return "Total Fat"
    case "HKQuantityTypeIdentifierDietarySodium": return "Sodium"
    case "HKQuantityTypeIdentifierDietaryWater": return "Water"

    // Blood Glucose & Metabolic
    case "HKQuantityTypeIdentifierBloodGlucose": return "Blood Glucose"

    default:
        assert(false, "friendlyName/1 not implemented for (\(identifier))!")
        return identifier
    }
}

func friendlyName(for type: HKSampleType) -> String {
    friendlyName(for: type.identifier)
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

struct MainView: View {
    @StateObject private var healthKit = HealthKitManager()
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
}

@main struct TempoApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                MainView()
                    .tabItem { Label("Home", systemImage: "heart.fill") }
                TempoSyncView()
            }
        }
    }
}
