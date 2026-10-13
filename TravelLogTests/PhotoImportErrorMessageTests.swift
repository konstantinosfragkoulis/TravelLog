import Foundation
import Testing
@testable import TravelLog

@MainActor
struct PhotoImportErrorMessageTests {
    @Test("Every photo import error provides a non-empty recovery message")
    func allErrorMessages() {
        let errors: [PhotoImportError] = [
            .alreadyRunning,
            .noPhotoPermission,
            .noResumableState,
            .persistenceFailure("save failed"),
            .incompleteLocalData,
            .inconsistentLocalData,
            .bgTaskSubmissionFailed("submission failed"),
            .lowPowerMode,
            .insufficientDiskSpace(bytesAvailable: 42 * 1024 * 1024)
        ]
        for error in errors {
            #expect(!error.userFacingMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @Test("Photo import recovery messages retain underlying failure details")
    func associatedDetails() {
        #expect(PhotoImportError.persistenceFailure("save sentinel").userFacingMessage.contains("save sentinel"))
        #expect(PhotoImportError.bgTaskSubmissionFailed("task sentinel").userFacingMessage.contains("task sentinel"))
    }
}
