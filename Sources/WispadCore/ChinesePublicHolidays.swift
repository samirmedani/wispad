import Foundation

/// Calendrier explicite des congés nationaux, sans extrapolation des années suivantes.
enum ChinesePublicHolidays {
    /// Conseil d'État, avis 国办发明电〔2025〕7号, publié le 4 novembre 2025.
    /// https://www.gov.cn/zhengce/content/202511/content_7047090.htm
    /// Reproduction officielle : https://www.beijing.gov.cn/zhengce/zhengcefagui/202511/t20251104_4258873.html
    /// Les week-ends de travail compensatoire restent hors pointe selon DeepSeek.
    private static let holidayDays: [Int: [Int: ClosedRange<Int>]] = [
        2026: [
            1: 1...3,      // Nouvel An
            2: 15...23,    // Fête du printemps
            4: 4...6,      // Qingming
            5: 1...5,      // Fête du travail
            6: 19...21,    // Fête des bateaux-dragons
            9: 25...27,    // Fête de la mi-automne
            10: 1...7      // Fête nationale
        ]
    ]

    /// nil signifie que le calendrier officiel de cette année n'est pas intégré.
    static func isHoliday(_ date: Date) -> Bool? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day,
              let daysByMonth = holidayDays[year] else { return nil }
        return daysByMonth[month]?.contains(day) ?? false
    }
}
