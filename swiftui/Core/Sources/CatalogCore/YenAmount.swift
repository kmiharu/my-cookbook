import Foundation

public enum YenAmount {
    public static func parse(_ raw: String) -> Int? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: .widthInsensitive, locale: Locale(identifier: "ja_JP"))
        guard (1...7).contains(normalized.utf8.count),
              normalized.utf8.allSatisfy({ (48...57).contains($0) }),
              let amount = Int(normalized), (1...1_000_000).contains(amount) else { return nil }
        return amount
    }
}
