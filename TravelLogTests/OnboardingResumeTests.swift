import Testing
@testable import TravelLog

struct OnboardingResumeTests {
    @Test("Resume preserves saved steps and requires a home beyond step 2", arguments: [false, true])
    func resumeStep(hasHome: Bool) {
        #expect(OnboardingView.resumeStep(saved: 0, hasHome: hasHome) == 0)
        #expect(OnboardingView.resumeStep(saved: 2, hasHome: hasHome) == 2)
        #expect(OnboardingView.resumeStep(saved: 5, hasHome: hasHome) == (hasHome ? 5 : 2))
    }

    @Test("Resume clamps corrupt saved indices into the onboarding range", arguments: [false, true])
    func clampsInvalidStep(hasHome: Bool) {
        #expect(OnboardingView.resumeStep(saved: -1, hasHome: hasHome) == 0)
        #expect(OnboardingView.resumeStep(saved: 8, hasHome: hasHome) == (hasHome ? 7 : 2))
        #expect(OnboardingView.resumeStep(saved: Int.min, hasHome: hasHome) == 0)
        #expect(OnboardingView.resumeStep(saved: Int.max, hasHome: hasHome) == (hasHome ? 7 : 2))
    }
}
