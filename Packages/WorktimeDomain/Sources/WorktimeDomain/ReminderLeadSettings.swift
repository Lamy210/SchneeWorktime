/// Stable preference encoding, independent of the work journal.
public enum ReminderLeadSettings {
    public static func decode(_ stored: String?) -> Set<ReminderLead> {
        guard let stored else { return [.fifteen] }
        guard !stored.isEmpty else { return [] }
        var selected: Set<ReminderLead> = []
        for value in stored.split(separator: ",", omittingEmptySubsequences: false) {
            guard let seconds = Int64(value), let lead = ReminderLead(rawValue: seconds),
                  String(seconds) == value, selected.insert(lead).inserted
            else { return [] }
        }
        return selected
    }

    public static func encode(_ selected: Set<ReminderLead>) -> String {
        selected.map(\.rawValue).sorted().map { String($0) }.joined(separator: ",")
    }
}
