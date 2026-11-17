import Testing
@testable import WorktimeDomain

struct ReminderLeadSettingsTests {
    @Test func `missing preference preserves legacy fifteen minutes and empty suppresses notifications`() {
        #expect(ReminderLeadSettings.decode(nil) == [.fifteen])
        #expect(ReminderLeadSettings.decode("") == [])
        #expect(ReminderLeadSettings.encode([]) == "")
    }

    @Test func `all combinations survive persistence encoding`() {
        for mask in 0 ..< 8 {
            let selected = Set(ReminderLead.allCases.enumerated().compactMap { index, lead in
                mask & (1 << index) != 0 ? lead : nil
            })
            #expect(ReminderLeadSettings.decode(ReminderLeadSettings.encode(selected)) == selected)
        }
        #expect(ReminderLeadSettings.encode([.thirty, .five, .fifteen]) == "300,900,1800")
    }

    @Test func `malformed preferences fail closed`() {
        for invalid in ["abc", "900,600", "900,900", "900,", "0900", " 900"] {
            #expect(ReminderLeadSettings.decode(invalid).isEmpty)
        }
    }
}
