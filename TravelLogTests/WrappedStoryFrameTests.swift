//
//  WrappedStoryFrameTests.swift
//  TravelLogTests
//
//  Wrapped's cards are laid out for a phone. On a phone (either
//  orientation) pages stay full-bleed; on a large screen each card sits in
//  a centred story frame of phone proportions that fits inside the safe
//  area and keeps clear of the Close button.
//

import Testing
import SwiftUI
@testable import TravelLog

@MainActor
struct WrappedStoryFrameTests {

    private static let phoneInsets = EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0)
    private static let phoneLandscapeInsets = EdgeInsets(top: 0, leading: 62, bottom: 21, trailing: 62)
    private static let tabletInsets = EdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0)

    @Test("a phone keeps the full-bleed page in portrait and landscape")
    func phoneStaysFullBleed() {
        #expect(WrappedView.storyFrameSize(screen: CGSize(width: 402, height: 874),
                                           safeArea: Self.phoneInsets) == nil)
        #expect(WrappedView.storyFrameSize(screen: CGSize(width: 440, height: 956),
                                           safeArea: Self.phoneInsets) == nil)
        #expect(WrappedView.storyFrameSize(screen: CGSize(width: 956, height: 440),
                                           safeArea: Self.phoneLandscapeInsets) == nil)
    }

    @Test("a large portrait screen gets the widest story frame")
    func tabletPortrait() {
        let frame = WrappedView.storyFrameSize(screen: CGSize(width: 1032, height: 1376),
                                               safeArea: Self.tabletInsets)
        #expect(frame == CGSize(width: 540, height: 960))
    }

    @Test("every large screen gets a story-shaped frame inside the safe area, clear of Close",
          arguments: [
              CGSize(width: 1376, height: 1032), CGSize(width: 1032, height: 1376),
              CGSize(width: 1194, height: 834), CGSize(width: 834, height: 1194),
              CGSize(width: 1133, height: 744), CGSize(width: 744, height: 1133),
              CGSize(width: 669, height: 951), CGSize(width: 620, height: 900),
          ])
    func largeScreenFits(screen: CGSize) throws {
        let insets = Self.tabletInsets
        let frame = try #require(WrappedView.storyFrameSize(screen: screen, safeArea: insets))
        #expect(frame.width <= WrappedView.storyMaxWidth)
        #expect(abs(frame.width / frame.height - WrappedView.storyAspect) < 0.01)
        #expect(frame.height <= screen.height - 2 * (max(insets.top, insets.bottom)
                                                      + WrappedView.storyVerticalMargin))
        #expect(frame.width <= screen.width - 2 * WrappedView.storySideClearance)
    }
}
