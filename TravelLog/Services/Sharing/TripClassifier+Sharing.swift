//
//  TripClassifier+Sharing.swift
//  TravelLog
//
//  The home areas a shared trip is judged against, measured the way
//  classification measures them: every Home and temporary home as an anchor,
//  its seed shape, learned orbit and taught corrections attached. The sender
//  drops what falls inside its own areas; the recipient drops shared evidence
//  inside theirs. Both read `matchesHome`, the predicate that stamps `.home`.
//

import Foundation
import SwiftData

extension TripClassifier {

    /// Every anchor's ring with its measured membership, in `HomeAnchors.fetch`
    /// order. Read-only: primes the shape and orbit memo the way any reader
    /// outside a pass does. Throws when the homes, the temporary homes, the
    /// overrides or the orbit evidence cannot be read: a share must not leave
    /// the device, and shared evidence must not enter it, judged against
    /// missing home areas.
    func sharingHomeRings() async throws -> [HomeRing] {
        guard await primeHomeShapes() else { throw CocoaError(.fileReadUnknown) }
        let anchors = try fetchRequiredAnchors()
        let overrides = try modelContext.fetch(FetchDescriptor<HomeAreaOverride>())
        return withShapes(anchors.map { HomeRing($0) }, overrides: overrides)
    }
}
