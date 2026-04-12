import Foundation
import SwiftData

@Model
final class Certification {
    var id: UUID = UUID()
    var name: String = ""
    var organization: String = "" // PADI, SSI, CMAS, etc.
    var level: String = "" // Open Water, Advanced, Rescue, etc.
    var certificationNumber: String = ""
    var issueDate: Date = Date.now
    var expirationDate: Date?
    var instructorName: String?
    var notes: String?
    
    init(
        id: UUID = UUID(),
        name: String,
        organization: String,
        level: String,
        certificationNumber: String,
        issueDate: Date,
        expirationDate: Date? = nil,
        instructorName: String? = nil,
        notes: String? = nil,
    ) {
        self.id = id
        self.name = name
        self.organization = organization
        self.level = level
        self.certificationNumber = certificationNumber
        self.issueDate = issueDate
        self.expirationDate = expirationDate
        self.instructorName = instructorName
        self.notes = notes
    }
}

// MARK: - Computed Properties

extension Certification {
    /// Checks if the certification is expired
    var isExpired: Bool {
        guard let expiration = expirationDate else { return false }
        return expiration < Date()
    }
    
    /// Checks if the certification expires soon (within 30 days)
    var isExpiringSoon: Bool {
        guard let expiration = expirationDate else { return false }
        let thirtyDaysFromNow = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
        return expiration < thirtyDaysFromNow && !isExpired
    }
    
    /// Days remaining until expiration
    var daysUntilExpiration: Int? {
        guard let expiration = expirationDate else { return nil }
        let components = Calendar.current.dateComponents([.day], from: Date(), to: expiration)
        return components.day
    }
    
    /// Status color
    var statusColor: String {
        if isExpired {
            return "red"
        } else if isExpiringSoon {
            return "orange"
        } else {
            return "green"
        }
    }
}

// MARK: - Organizations

enum CertificationOrganization: String, CaseIterable, Identifiable {
    case padi = "PADI"
    case ssi = "SSI"
    case cmas = "CMAS"
    case naui = "NAUI"
    case sdi = "SDI"
    case bsac = "BSAC"
    case other = "Other"
    
    var id: String { rawValue }
    
    var color: String {
        switch self {
        case .padi: return "blue"
        case .ssi: return "cyan"
        case .cmas: return "orange"
        case .naui: return "green"
        case .sdi: return "purple"
        case .bsac: return "red"
        case .other: return "gray"
        }
    }
}

// MARK: - Certification Levels per Organization

extension CertificationOrganization {
    var levels: [String] {
        switch self {
        case .padi:
            return [
                // Core Levels
                "Scuba Diver",
                "Open Water Diver",
                "Advanced Open Water Diver",
                "Rescue Diver",
                "Master Scuba Diver",
                // Professional Levels
                "Divemaster",
                "Assistant Instructor",
                "Open Water Scuba Instructor",
                "Master Scuba Diver Trainer",
                "IDC Staff Instructor",
                "Master Instructor",
                "Course Director",
                // Specialties
                "Altitude Diver",
                "Boat Diver",
                "Cavern Diver",
                "Deep Diver",
                "DSMB Diver",
                "Digital Underwater Photographer",
                "Drift Diver",
                "Dry Suit Diver",
                "Emergency First Response",
                "Emergency Oxygen Provider",
                "Enriched Air Diver",
                "Equipment Specialist",
                "Fish Identification",
                "Full Face Mask Diver",
                "Ice Diver",
                "Night Diver",
                "Peak Performance Buoyancy",
                "Search and Recovery Diver",
                "Self-Reliant Diver",
                "Sidemount Diver",
                "Underwater Navigator",
                "Underwater Videographer",
                "Wreck Diver",
                "Other",
            ]
        case .ssi:
            return [
                // Core Levels
                "Open Water Diver",
                "Advanced Adventurer",
                "Specialty Diver",
                "Advanced Open Water Diver",
                "Master Diver",
                // Professional Levels
                "Dive Guide",
                "Divemaster",
                "Assistant Instructor",
                "Open Water Instructor",
                "Divemaster Instructor",
                "Instructor Trainer",
                // Specialties
                "Deep Diving",
                "Diver Stress and Rescue",
                "Drift Diving",
                "Dry Suit Diving",
                "Enriched Air Nitrox",
                "Ice Diving",
                "Navigation",
                "Night and Limited Visibility",
                "Perfect Buoyancy",
                "Photo and Video",
                "Science of Diving",
                "Search and Recovery",
                "Sidemount Diving",
                "Wreck Diving",
                "Other",
            ]
        case .cmas:
            return [
                // Star System
                "One Star Diver",
                "Two Star Diver",
                "Three Star Diver",
                "Four Star Diver",
                // Instructor Levels
                "One Star Instructor",
                "Two Star Instructor",
                "Three Star Instructor",
                // Specialties
                "Nitrox Diver",
                "Night Diving",
                "Drift Diving",
                "Dry Suit Diving",
                "Sidemount Diving",
                "Underwater Navigation",
                "Underwater Photography",
                "Wreck Diving",
                "Ice Diving",
                "Cave Diving",
                "First Aid Diver",
                // Freediving
                "One Star Freediver",
                "Two Star Freediver",
                "Three Star Freediver",
                "Other",
            ]
        case .naui:
            return [
                // Core Levels
                "Scuba Diver",
                "Advanced Scuba Diver",
                "Rescue Scuba Diver",
                "Master Scuba Diver",
                // Professional Levels
                "Divemaster",
                "Assistant Instructor",
                "Instructor",
                "Instructor Trainer",
                "Course Director",
                // Specialties
                "Enriched Air Nitrox Diver",
                "Deep Diver",
                "Night Diver",
                "Drysuit Diver",
                "Navigation Diver",
                "Wreck Diver",
                "Search and Recovery",
                "Underwater Photography",
                "Ice Diving",
                "Sidemount Diving",
                "Full Face Mask Diving",
                "Other",
            ]
        case .sdi:
            return [
                // Core Levels
                "Open Water Scuba Diver",
                "Advanced Adventure Diver",
                "Advanced Diver Development",
                "Rescue Diver",
                "Master Scuba Diver",
                // Professional Levels
                "Divemaster",
                "Assistant Instructor",
                "Open Water Scuba Diver Instructor",
                "Specialty Instructor",
                "Course Director",
                "Instructor Trainer",
                // Specialties
                "Advanced Buoyancy Control",
                "Boat Diver",
                "Computer Nitrox",
                "Deep Diver",
                "Drift Diver",
                "Dry Suit Diver",
                "Full Face Mask Diver",
                "Ice Diver",
                "Night and Limited Visibility Diver",
                "Search and Recovery",
                "Sidemount Diver",
                "Solo Diver",
                "Underwater Navigation",
                "Underwater Photographer",
                "Wreck Diver",
                "Other",
            ]
        case .bsac:
            return [
                // Diver Grades
                "Discovery Diver",
                "Ocean Diver",
                "Advanced Ocean Diver",
                "Sports Diver",
                "Dive Leader",
                "Advanced Diver",
                "First Class Diver",
                // Instructor Grades
                "Assistant Diving Instructor",
                "Theory Instructor",
                "Assistant Open Water Instructor",
                "Practical Instructor",
                "Open Water Instructor",
                "Advanced Instructor",
                "Instructor Trainer",
                "National Instructor",
                // Skill Development Courses
                "Drysuit Training",
                "Deeper Diver",
                "Wreck Diver",
                "Advanced Wreck Diver",
                "Nitrox Workshop",
                "Accelerated Decompression Procedures",
                "Sports Mixed Gas Diver",
                "Search and Recovery",
                "Ice Diving",
                "Underwater Photography",
                "First Aid for Divers",
                "Oxygen Administration",
                "Boat Handling",
                "Other",
            ]
        case .other:
            return [
                "Open Water Diver",
                "Advanced Open Water Diver",
                "Rescue Diver",
                "Divemaster",
                "Instructor",
                "Nitrox",
                "Deep Diver",
                "Wreck Diver",
                "Night Diver",
                "Dry Suit Diver",
                "Ice Diver",
                "Other",
            ]
        }
    }
}
