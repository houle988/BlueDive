import SwiftUI

/// Centralised country-name-to-flag and accent-colour lookup.
/// Supports English and French Canadian country names with accent-insensitive matching.
enum CountryLookup {

    // MARK: - Public API

    /// Resolves a country name to its emoji flag and accent colour.
    /// Returns a white flag with grey colour when the country is unknown.
    static func resolve(_ country: String?) -> (flag: String, color: Color) {
        guard let country, !country.isEmpty,
              let code = normalizedNameToCode[normalizedKey(country)],
              let flag = emojiFlag(for: code) else {
            return ("🏳️", .gray)
        }
        let color = accentColor[code] ?? .cyan
        return (flag, color)
    }

    // MARK: - Private helpers

    /// Strips diacritics and lowercases a string for accent-insensitive lookups.
    private static func normalizedKey(_ string: String) -> String {
        string.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "en"))
    }

    /// Builds the regional-indicator emoji flag from an ISO 3166-1 alpha-2 code.
    private static func emojiFlag(for code: String) -> String? {
        let base: UInt32 = 127397 // Regional Indicator Symbol base
        let flag = code.uppercased().unicodeScalars.compactMap { UnicodeScalar(base + $0.value) }.map { String($0) }.joined()
        return flag.isEmpty ? nil : flag
    }

    /// Country name lookup with keys normalized (diacritics stripped) for accent-insensitive matching.
    private static let normalizedNameToCode: [String: String] = {
        Dictionary(nameToCode.map { (normalizedKey($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
    }()

    // MARK: - Country name → ISO code

    // swiftlint:disable:next line_length
    private static let nameToCode: [String: String] = [
        // A
        "afghanistan": "af", "albania": "al", "algeria": "dz", "andorra": "ad", "angola": "ao",
        "antigua and barbuda": "ag", "argentina": "ar", "armenia": "am", "australia": "au", "austria": "at",
        "azerbaijan": "az",
        // B
        "bahamas": "bs", "bahrain": "bh", "bangladesh": "bd", "barbados": "bb", "belarus": "by",
        "belgium": "be", "belize": "bz", "benin": "bj", "bhutan": "bt", "bolivia": "bo",
        "bosnia and herzegovina": "ba", "botswana": "bw", "brazil": "br", "brunei": "bn", "bulgaria": "bg",
        "burkina faso": "bf", "burundi": "bi",
        // C
        "cabo verde": "cv", "cape verde": "cv", "cambodia": "kh", "cameroon": "cm", "canada": "ca",
        "central african republic": "cf", "chad": "td", "chile": "cl", "china": "cn", "colombia": "co",
        "comoros": "km", "congo": "cg", "costa rica": "cr", "croatia": "hr", "cuba": "cu",
        "cyprus": "cy", "czech republic": "cz", "czechia": "cz",
        // D
        "denmark": "dk", "djibouti": "dj", "dominica": "dm", "dominican republic": "do",
        // E
        "east timor": "tl", "timor-leste": "tl", "ecuador": "ec", "egypt": "eg", "el salvador": "sv",
        "equatorial guinea": "gq", "eritrea": "er", "estonia": "ee", "eswatini": "sz", "ethiopia": "et",
        // F
        "fiji": "fj", "finland": "fi", "france": "fr",
        // G
        "gabon": "ga", "gambia": "gm", "georgia": "ge", "germany": "de", "ghana": "gh",
        "greece": "gr", "grenada": "gd", "guatemala": "gt", "guinea": "gn", "guinea-bissau": "gw",
        "guyana": "gy",
        // H
        "haiti": "ht", "honduras": "hn", "hungary": "hu",
        // I
        "iceland": "is", "india": "in", "indonesia": "id", "iran": "ir", "iraq": "iq",
        "ireland": "ie", "israel": "il", "italy": "it", "ivory coast": "ci", "côte d'ivoire": "ci",
        // J
        "jamaica": "jm", "japan": "jp", "jordan": "jo",
        // K
        "kazakhstan": "kz", "kenya": "ke", "kiribati": "ki", "korea, north": "kp", "north korea": "kp",
        "korea, south": "kr", "south korea": "kr", "kuwait": "kw", "kyrgyzstan": "kg",
        // L
        "laos": "la", "latvia": "lv", "lebanon": "lb", "lesotho": "ls", "liberia": "lr",
        "libya": "ly", "liechtenstein": "li", "lithuania": "lt", "luxembourg": "lu",
        // M
        "madagascar": "mg", "malawi": "mw", "malaysia": "my", "maldives": "mv", "mali": "ml",
        "malta": "mt", "marshall islands": "mh", "mauritania": "mr", "mauritius": "mu", "mexico": "mx",
        "micronesia": "fm", "moldova": "md", "monaco": "mc", "mongolia": "mn", "montenegro": "me",
        "morocco": "ma", "mozambique": "mz", "myanmar": "mm",
        // N
        "namibia": "na", "nauru": "nr", "nepal": "np", "netherlands": "nl", "new zealand": "nz",
        "nicaragua": "ni", "niger": "ne", "nigeria": "ng", "north macedonia": "mk", "norway": "no",
        // O
        "oman": "om",
        // P
        "pakistan": "pk", "palau": "pw", "palestine": "ps", "panama": "pa", "papua new guinea": "pg",
        "paraguay": "py", "peru": "pe", "philippines": "ph", "poland": "pl", "portugal": "pt",
        // Q
        "qatar": "qa",
        // R
        "romania": "ro", "russia": "ru", "rwanda": "rw",
        // S
        "saint kitts and nevis": "kn", "saint lucia": "lc", "saint vincent and the grenadines": "vc",
        "samoa": "ws", "san marino": "sm", "sao tome and principe": "st", "saudi arabia": "sa",
        "senegal": "sn", "serbia": "sr", "seychelles": "sc", "sierra leone": "sl", "singapore": "sg",
        "slovakia": "sk", "slovenia": "si", "solomon islands": "sb", "somalia": "so", "south africa": "za",
        "south sudan": "ss", "spain": "es", "sri lanka": "lk", "sudan": "sd", "suriname": "sr",
        "sweden": "se", "switzerland": "ch", "syria": "sy",
        // T
        "taiwan": "tw", "tajikistan": "tj", "tanzania": "tz", "thailand": "th", "togo": "tg",
        "tonga": "to", "trinidad and tobago": "tt", "tunisia": "tn", "turkey": "tr", "türkiye": "tr",
        "turkmenistan": "tm", "tuvalu": "tv",
        // U
        "uganda": "ug", "ukraine": "ua", "united arab emirates": "ae", "uae": "ae",
        "united kingdom": "gb", "uk": "gb", "england": "gb", "scotland": "gb", "wales": "gb",
        "united states": "us", "usa": "us", "united states of america": "us",
        "uruguay": "uy", "uzbekistan": "uz",
        // V
        "vanuatu": "vu", "vatican city": "va", "venezuela": "ve", "vietnam": "vn", "viet nam": "vn",
        // Y
        "yemen": "ye",
        // Z
        "zambia": "zm", "zimbabwe": "zw",
        // Territories & dependencies commonly visited for diving
        "aruba": "aw", "bermuda": "bm", "bonaire": "bq", "cayman islands": "ky",
        "curaçao": "cw", "curacao": "cw", "french polynesia": "pf", "guadeloupe": "gp",
        "guam": "gu", "martinique": "mq", "new caledonia": "nc", "puerto rico": "pr",
        "réunion": "re", "reunion": "re", "turks and caicos islands": "tc", "turks and caicos": "tc",
        "u.s. virgin islands": "vi", "british virgin islands": "vg",
        "american samoa": "as", "cook islands": "ck", "faroe islands": "fo",
        "french guiana": "gf", "gibraltar": "gi", "greenland": "gl", "hong kong": "hk",
        "macau": "mo", "macao": "mo", "mayotte": "yt", "montserrat": "ms",
        "niue": "nu", "norfolk island": "nf", "northern mariana islands": "mp",
        "pitcairn islands": "pn", "saint helena": "sh", "saint pierre and miquelon": "pm",
        "sint maarten": "sx", "tokelau": "tk", "wallis and futuna": "wf",
        "western sahara": "eh", "åland islands": "ax", "aland islands": "ax",
        // French Canadian (fr-CA) country names
        // A
        "albanie": "al", "algérie": "dz", "allemagne": "de", "andorre": "ad",
        "antigua-et-barbuda": "ag", "arabie saoudite": "sa", "argentine": "ar", "arménie": "am",
        "australie": "au", "autriche": "at", "azerbaïdjan": "az", "afrique du sud": "za",
        // B
        "bahreïn": "bh", "belgique": "be", "bélize": "bz", "bénin": "bj", "bhoutan": "bt",
        "biélorussie": "by", "birmanie": "mm", "bolivie": "bo",
        "bosnie-herzégovine": "ba", "brésil": "br", "brunéi": "bn", "bulgarie": "bg",
        "bermudes": "bm",
        // C
        "cambodge": "kh", "cameroun": "cm", "cap-vert": "cv",
        "centrafrique": "cf", "république centrafricaine": "cf", "chine": "cn", "chypre": "cy",
        "colombie": "co", "comores": "km", "corée du nord": "kp", "corée du sud": "kr",
        "croatie": "hr", "tchéquie": "cz", "république tchèque": "cz",
        // D
        "danemark": "dk",
        "république dominicaine": "do", "dominique": "dm",
        // E
        "écosse": "gb", "égypte": "eg", "émirats arabes unis": "ae", "eau": "ae",
        "équateur": "ec", "érythrée": "er", "espagne": "es", "estonie": "ee",
        "états-unis": "us", "états-unis d'amérique": "us", "éthiopie": "et",
        // F
        "fidji": "fj", "finlande": "fi",
        // G
        "gambie": "gm", "géorgie": "ge", "grenade": "gd", "grèce": "gr",
        "guinée": "gn", "guinée-bissau": "gw", "guinée équatoriale": "gq",
        "guyane": "gy", "guyane française": "gf",
        // H
        "haïti": "ht", "hongrie": "hu",
        // I
        "île maurice": "mu", "îles cook": "ck", "îles marshall": "mh", "îles salomon": "sb",
        "îles féroé": "fo", "îles caïmans": "ky", "îles vierges américaines": "vi",
        "îles vierges britanniques": "vg", "îles mariannes du nord": "mp",
        "îles pitcairn": "pn", "îles turques-et-caïques": "tc",
        "inde": "in", "indonésie": "id", "irak": "iq", "irlande": "ie",
        "islande": "is", "israël": "il", "italie": "it",
        // J
        "jamaïque": "jm", "japon": "jp", "jordanie": "jo",
        // K
        "kirghizistan": "kg",
        // L
        "lettonie": "lv", "liban": "lb", "libye": "ly", "lituanie": "lt",
        // M
        "macédoine du nord": "mk", "malaisie": "my", "mauritanie": "mr", "mexique": "mx",
        "micronésie": "fm", "moldavie": "md", "mongolie": "mn", "monténégro": "me",
        "maroc": "ma",
        // N
        "namibie": "na", "népal": "np", "norvège": "no",
        "nouvelle-calédonie": "nc", "nouvelle-zélande": "nz",
        // O
        // P
        "palaos": "pw", "papouasie-nouvelle-guinée": "pg",
        "pays-bas": "nl", "pérou": "pe", "pologne": "pl",
        "polynésie française": "pf", "porto rico": "pr",
        // Q
        // R
        "la réunion": "re", "roumanie": "ro", "royaume-uni": "gb", "russie": "ru",
        // S
        "sahara occidental": "eh", "saint-kitts-et-nevis": "kn", "sainte-lucie": "lc",
        "saint-vincent-et-les-grenadines": "vc",
        "saint-marin": "sm", "são tomé-et-príncipe": "st", "sénégal": "sn",
        "serbie": "sr", "singapour": "sg", "slovaquie": "sk", "slovénie": "si",
        "somalie": "so", "soudan": "sd", "soudan du sud": "ss",
        "suède": "se", "suisse": "ch", "syrie": "sy",
        "saint-pierre-et-miquelon": "pm", "sainte-hélène": "sh",
        // T
        "tadjikistan": "tj", "tanzanie": "tz", "taïwan": "tw", "tchad": "td",
        "thaïlande": "th", "timor oriental": "tl", "trinité-et-tobago": "tt",
        "tunisie": "tn", "turkménistan": "tm", "turquie": "tr",
        // U
        "ouganda": "ug", "ouzbékistan": "uz",
        // V
        "cité du vatican": "va",
        "viêt nam": "vn", "viêtnam": "vn",
        // W
        "wallis-et-futuna": "wf",
        // Y
        "yémen": "ye",
        // Z
        "zambie": "zm",
    ]

    // MARK: - ISO code → accent colour

    /// Accent colour for the background circle behind the country flag.
    private static let accentColor: [String: Color] = [
        // A
        "af": .green, "al": .red, "dz": .green, "ad": .red, "ao": .red,
        "ag": .red, "ar": .cyan, "am": .orange, "au": .blue, "at": .red,
        "az": .cyan, "aw": .cyan,
        // B
        "bs": .cyan, "bh": .red, "bd": .green, "bb": .blue, "by": .red,
        "be": .yellow, "bz": .blue, "bj": .green, "bt": .orange, "bo": .green,
        "ba": .blue, "bw": .cyan, "br": .green, "bn": .yellow, "bg": .green,
        "bf": .green, "bi": .red, "bm": .red, "bq": .blue,
        // C
        "cv": .blue, "kh": .red, "cm": .green, "ca": .red, "cf": .blue,
        "td": .blue, "cl": .red, "cn": .red, "co": .yellow, "km": .green,
        "cg": .green, "cr": .red, "hr": .red, "cu": .blue, "cy": .orange,
        "cz": .blue, "cw": .blue, "ck": .blue,
        // D
        "dk": .red, "dj": .cyan, "dm": .green, "do": .red,
        // E
        "tl": .red, "ec": .yellow, "eg": .red, "sv": .blue, "gq": .green,
        "er": .blue, "ee": .blue, "sz": .blue, "et": .green,
        // F
        "fj": .cyan, "fi": .blue, "fr": .blue, "fo": .blue,
        // G
        "ga": .green, "gm": .red, "ge": .red, "de": .orange, "gh": .green,
        "gr": .blue, "gd": .red, "gt": .cyan, "gn": .green, "gw": .red,
        "gy": .green, "gi": .red, "gl": .red, "gp": .blue, "gu": .blue,
        // H
        "ht": .blue, "hn": .blue, "hu": .red, "hk": .red,
        // I
        "is": .blue, "in": .orange, "id": .red, "ir": .green, "iq": .red,
        "ie": .green, "il": .blue, "it": .green, "ci": .orange,
        // J
        "jm": .green, "jp": .red, "jo": .red,
        // K
        "kz": .cyan, "ke": .red, "ki": .red, "kp": .red, "kr": .blue,
        "kw": .green, "kg": .red, "ky": .blue,
        // L
        "la": .red, "lv": .red, "lb": .red, "ls": .blue, "lr": .red,
        "ly": .green, "li": .blue, "lt": .yellow, "lu": .cyan,
        // M
        "mg": .red, "mw": .red, "my": .blue, "mv": .red, "ml": .green,
        "mt": .red, "mh": .blue, "mr": .green, "mu": .red, "mx": .green,
        "fm": .blue, "md": .blue, "mc": .red, "mn": .red, "me": .red,
        "ma": .red, "mz": .green, "mm": .yellow, "mq": .blue, "ms": .blue,
        "mo": .green, "yt": .blue, "mp": .blue,
        // N
        "na": .blue, "nr": .blue, "np": .red, "nl": .orange, "nz": .blue,
        "ni": .blue, "ne": .orange, "ng": .green, "mk": .red, "no": .red,
        "nc": .blue, "nu": .yellow, "nf": .green,
        // O
        "om": .red,
        // P
        "pk": .green, "pw": .cyan, "ps": .green, "pa": .red, "pg": .red,
        "py": .red, "pe": .red, "ph": .blue, "pl": .red, "pt": .green,
        "pr": .blue, "pn": .blue, "pm": .blue,
        // Q
        "qa": .purple,
        // R
        "ro": .blue, "ru": .blue, "rw": .blue, "re": .blue,
        // S
        "kn": .green, "lc": .cyan, "vc": .blue, "ws": .red, "sm": .cyan,
        "st": .green, "sa": .green, "sn": .green, "sr": .green, "sc": .blue,
        "sl": .green, "sg": .red, "sk": .blue, "si": .blue, "sb": .blue,
        "so": .cyan, "za": .green, "ss": .green, "es": .red, "lk": .yellow,
        "sd": .green, "se": .blue, "ch": .red, "sy": .red, "sh": .blue,
        "sx": .red,
        // T
        "tw": .red, "tj": .red, "tz": .green, "th": .blue, "tg": .green,
        "to": .red, "tt": .red, "tn": .red, "tr": .red, "tm": .green,
        "tv": .cyan, "tc": .blue, "tk": .blue,
        // U
        "ug": .yellow, "ua": .blue, "ae": .green, "gb": .blue, "us": .blue,
        "uy": .blue, "uz": .cyan,
        // V
        "vu": .red, "va": .yellow, "ve": .yellow, "vn": .red, "vi": .blue, "vg": .blue,
        // W
        "wf": .red, "eh": .green,
        // Y
        "ye": .red,
        // Z
        "zm": .green, "zw": .green,
        // Åland
        "ax": .blue,
    ]
}
