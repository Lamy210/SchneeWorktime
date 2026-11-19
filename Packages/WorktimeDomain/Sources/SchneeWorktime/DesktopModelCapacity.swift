#if os(macOS)
    extension DesktopModel {
        var allowsOptionalJournalMutation: Bool {
            guard let capacity = controller?.journalCapacity, capacity.remainingEvents > 0 else { return false }
            return glance?.day.state == .ended || !capacity.isExitReserve
        }
    }
#endif
