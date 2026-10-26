//
//  ReconciliationDrainTests.swift
//  TravelLogTestSupport
//

import Testing

/// The drain's reentrancy flag is process-wide, even with per-test defaults.
/// Serialize all consuming suites together while preserving nested-drain tests.
/// Every test bundle declares this parent; bundles run one after another.
@Suite(.serialized)
struct ReconciliationDrainTests {}
