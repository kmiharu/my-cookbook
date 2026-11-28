import Testing
@testable import CatalogCore

@Test(arguments: [("1", 1), (" １２３４\n", 1_234), ("1000000", 1_000_000), ("003", 3)])
func parsesWholeYen(input: String, amount: Int) {
    #expect(YenAmount.parse(input) == amount)
}

@Test(arguments: ["", "0", "０", "1000001", "1,000", "1.25", "-1", "+1", "1円", "１２ ３"])
func rejectsInvalidYen(input: String) {
    #expect(YenAmount.parse(input) == nil)
}
