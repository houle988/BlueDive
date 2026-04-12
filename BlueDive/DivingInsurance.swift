import Foundation
import SwiftData

// MARK: - Diving Insurance Model

@Model
final class DivingInsurance {
    var id: UUID = UUID()
    var insurerName: String = ""       // Insurer name (e.g., DAN, General Insurance…)
    var policyNumber: String = ""      // Policy number
    var coverageType: String = ""      // Coverage type (e.g., Accident, Evacuation, Equipment…)
    var startDate: Date = Date.now           // Start date
    var endDate: Date = Date.now             // End date / renewal
    var contactPhone: String?     // Emergency phone
    var contactEmail: String?     // Email
    var notes: String?            // Free-form notes

    init(
        id: UUID = UUID(),
        insurerName: String,
        policyNumber: String,
        coverageType: String,
        startDate: Date = Date(),
        endDate: Date = Calendar.current.date(byAdding: .year, value: 1, to: Date()) ?? Date(),
        contactPhone: String? = nil,
        contactEmail: String? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.insurerName = insurerName
        self.policyNumber = policyNumber
        self.coverageType = coverageType
        self.startDate = startDate
        self.endDate = endDate
        self.contactPhone = contactPhone
        self.contactEmail = contactEmail
        self.notes = notes
    }
}

// MARK: - Computed Properties

extension DivingInsurance {
    /// Checks if the insurance is expired
    var isExpired: Bool {
        endDate < Date()
    }

    /// Checks if the insurance expires in the next 30 days
    var isExpiringSoon: Bool {
        guard !isExpired else { return false }
        let limit = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
        return endDate < limit
    }

    /// Days remaining until expiration
    var daysUntilExpiration: Int? {
        let components = Calendar.current.dateComponents([.day], from: Date(), to: endDate)
        return components.day
    }
}


