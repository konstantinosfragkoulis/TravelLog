//
//  StayPingIDAppendTests.swift
//  TravelLogTests
//
//  Pins `Stay.appendPingID` against the accessor path it
//  replaced in the import fold: for every writer-produced (well-formed)
//  string the incremental O(1) append must yield the EXACT serialized bytes
//  and count the old parse-append-re-join produced — that equivalence is what
//  makes the change a pure optimization. Also pins the one deliberate
//  divergence: malformed segments are preserved, not silently cleansed
//  (repairing corrupt references is DebugStayReferenceRepair's job).
//

import Testing
import Foundation
@testable import TravelLog

@MainActor
struct StayPingIDAppendTests {

    private func makeStay(pingIDs: [UUID]) -> Stay {
        Stay(startTime: .now, endTime: .now,
             centroidLatitude: 0, centroidLongitude: 0,
             h3IndexRes6: "8a1ed8677ffffff", pingCount: pingIDs.count,
             distanceFromHomeKm: 0, pingIDs: pingIDs)
    }

    @Test("incremental append is byte-identical to the old parse-append-rejoin, from empty through N appends")
    func appendMatchesAccessorPathExactly() {
        let incremental = makeStay(pingIDs: [])
        let reference = makeStay(pingIDs: [])

        for _ in 0..<25 {
            let id = UUID()
            incremental.appendPingID(id)

            // The pre-2026-08-08 fold body, verbatim.
            var ids = reference.pingIDs
            ids.append(id)
            reference.pingIDs = ids
            reference.pingCount = ids.count

            #expect(incremental.pingIDsString == reference.pingIDsString)
            #expect(incremental.pingCount == reference.pingCount)
        }
        #expect(incremental.pingIDs == reference.pingIDs)
        #expect(incremental.pingCount == 25)
    }

    @Test("append preserves a malformed segment instead of silently cleansing it")
    func appendPreservesMalformedSegments() {
        let stay = makeStay(pingIDs: [])
        stay.pingIDsString = "not-a-uuid"
        stay.pingCount = 1

        let id = UUID()
        stay.appendPingID(id)

        #expect(stay.pingIDsString == "not-a-uuid," + id.uuidString)
        #expect(stay.pingCount == 2)
        // The accessor still parses only the valid segment — same as before.
        #expect(stay.pingIDs == [id])
    }
}
