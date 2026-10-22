//
//  StayClassificationResult.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//


import Foundation
import FoundationModels

/// The structured output type for stay classification via Foundation Models.
///
/// The on-device model is constrained by guided generation to produce exactly
/// this type. No JSON parsing, no hallucinated fields - the model's token
/// generation is forced to match this schema at decode time.
///
/// ## Token Budget
///
/// Each `SingleStayClassification` is ~15-20 output tokens.
/// With 20 stays per batch, output ≈ 300-400 tokens.
/// Instructions ≈ 150 tokens, prompt ≈ 500-700 tokens.
/// Total ≈ 1000-1250 tokens - well within the 4096 limit.
///
/// No per-stay trip-continuation field: trip boundaries are decided
/// deterministically in Stage 3, and a constant per stay would roughly
/// double output length — the axis the model's documented skip-an-index
/// failure mode scales with.
@Generable
struct StayClassificationResult {

    @Guide(description: "Array of classifications, one per stay, in the same order as input")
    var classifications: [SingleStayClassification]
}

@Generable
struct SingleStayClassification {

    @Guide(description: "The index of the stay in the input array, starting from 0")
    var stayIndex: Int

    @Guide(description: "The category: destination means intentionally visited, transit means passing through like airport layover or gas stop")
    @Guide(.anyOf(["destination", "transit"]))
    var category: String
}
