struct DabBufferReservationState {
    struct Reservation: Equatable {
        let slot: Int
        let token: UInt64
        let signalValue: UInt64
    }

    private enum SlotState {
        case available
        case reserved(token: UInt64)
        case inFlight(reusableAfterValue: UInt64)
    }

    private var slots: [SlotState]
    private var nextToken: UInt64 = 1
    private var nextSignalValue: UInt64 = 1
    private var searchStart = 0

    init(slotCount: Int) {
        precondition(slotCount > 0)
        slots = Array(repeating: .available, count: slotCount)
    }

    mutating func acquire(completedValue: UInt64) -> Reservation? {
        for offset in slots.indices {
            let index = (searchStart + offset) % slots.count
            switch slots[index] {
            case .available:
                break
            case .reserved:
                continue
            case let .inFlight(reusableAfterValue):
                guard completedValue >= reusableAfterValue else {
                    continue
                }
            }

            let reservation = Reservation(
                slot: index,
                token: nextToken,
                signalValue: nextSignalValue
            )
            nextToken &+= 1
            nextSignalValue &+= 1
            searchStart = (index + 1) % slots.count
            slots[index] = .reserved(token: reservation.token)
            return reservation
        }

        return nil
    }

    func isReserved(_ reservation: Reservation) -> Bool {
        guard slots.indices.contains(reservation.slot) else {
            return false
        }
        guard case let .reserved(token) = slots[reservation.slot] else {
            return false
        }
        return token == reservation.token
    }

    mutating func markSubmitted(_ reservation: Reservation) -> Bool {
        guard isReserved(reservation) else {
            return false
        }
        slots[reservation.slot] = .inFlight(
            reusableAfterValue: reservation.signalValue
        )
        return true
    }

    mutating func abandon(_ reservation: Reservation) -> Bool {
        guard isReserved(reservation) else {
            return false
        }
        slots[reservation.slot] = .available
        return true
    }
}
