import Testing
@testable import KlarschiffCore

@Test func germanByteFormatting() {
  #expect(ByteFormat.string(11_990_000_000) == "11,99 GB")
  #expect(ByteFormat.string(250_400_000) == "250,4 MB")
}
