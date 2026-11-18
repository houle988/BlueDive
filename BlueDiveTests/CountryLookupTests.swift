import Testing
@testable import BlueDive

/// `CountryLookup`: the flags shown beside a dive's country (dive list, Site Details,
/// My Trips cards, PDF logbook).
struct CountryLookupTests {

    @Test func knownCountryGivesItsFlag() {
        #expect(CountryLookup.flag(for: "Egypt") == "🇪🇬")
    }

    @Test func caseAccentsAndSurroundingSpacesAreIgnored() {
        #expect(CountryLookup.flag(for: " egypt ") == "🇪🇬")
        #expect(CountryLookup.flag(for: "EGYPT") == "🇪🇬")
        #expect(CountryLookup.flag(for: "Curacao") == "🇨🇼")
        #expect(CountryLookup.flag(for: "Curaçao") == "🇨🇼")
    }

    @Test func namesInTheAppLanguagesAreKnown() {
        #expect(CountryLookup.flag(for: "Égypte") == "🇪🇬")
        #expect(CountryLookup.flag(for: "Ägypten") == "🇪🇬")
    }

    @Test func unknownMissingOrEmptyCountryGivesNoFlag() {
        #expect(CountryLookup.flag(for: "Atlantis") == nil)
        #expect(CountryLookup.flag(for: nil) == nil)
        #expect(CountryLookup.flag(for: "") == nil)
        #expect(CountryLookup.flag(for: "   ") == nil)
    }

    /// `resolve` matches the same names as `flag(for:)`, and falls back to the white flag.
    @Test func resolveAgreesWithFlag() {
        #expect(CountryLookup.resolve(" Egypt ").flag == "🇪🇬")
        #expect(CountryLookup.resolve("Atlantis").flag == "🏳️")
        #expect(CountryLookup.resolve(nil).flag == "🏳️")
    }
}
