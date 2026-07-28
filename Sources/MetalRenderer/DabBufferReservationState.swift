struct DabBufferReservationState {
    struct Reservation: Equatable, Sendable {
        let slot: Int
        let token: UInt64
        let signalValue: UInt64
    }

    private enum SlotState {
        case available
        case reserved(token: UInt64)
        case inFlight(token: UInt64, reusableAfterValue: UInt64)
    }

    private var slots: [SlotState]
    private var nextToken: UInt64 = 1
    private var nextSignalValue: UInt64 = 1
    private var searchStart = 0

    var unavailableSlotCount: Int {
        slots.reduce(into: 0) { count, state in
            switch state {
            case .available:
                break
            case .reserved, .inFlight:
                count += 1
            }
        }
    }

    func unavailableSlotCount(completedValue: UInt64) -> Int {
        slots.reduce(into: 0) { count, state in
            switch state {
            case .available:
                break
            case .reserved:
                count += 1
            case let .inFlight(_, reusableAfterValue):
                if completedValue < reusableAfterValue {
                    count += 1
                }
            }
        }
    }

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
            case let .inFlight(_, reusableAfterValue):
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

    mutating func acquire(
        count: Int,
        completedValue: UInt64
    ) -> [Reservation]? {
        precondition((0...slots.count).contains(count))
        guard count > 0 else { return [] }

        var candidate = self
        var reservations: [Reservation] = []
        reservations.reserveCapacity(count)
        for _ in 0..<count {
            guard let reservation = candidate.acquire(
                completedValue: completedValue
            ) else {
                return nil
            }
            reservations.append(reservation)
        }
        self = candidate
        return reservations
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
            token: reservation.token,
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

    mutating func abandon(_ reservations: [Reservation]) -> Bool {
        guard Set(reservations.map(\.slot)).count == reservations.count,
              reservations.allSatisfy({ isReserved($0) })
        else {
            return false
        }
        for reservation in reservations {
            slots[reservation.slot] = .available
        }
        return true
    }

    mutating func reclaimTerminalFailure(
        _ reservation: Reservation
    ) -> Bool {
        guard slots.indices.contains(reservation.slot) else {
            return false
        }
        guard case let .inFlight(token, reusableAfterValue) =
            slots[reservation.slot],
            token == reservation.token,
            reusableAfterValue == reservation.signalValue
        else {
            return false
        }
        slots[reservation.slot] = .available
        return true
    }
}
