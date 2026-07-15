enum RecordingState: Equatable {
    case idle
    case recording
    case paused
    case processing

    var canPauseOrResume: Bool { self == .recording || self == .paused }
    var canFinish: Bool { self == .recording || self == .paused }
    var canCancel: Bool { self != .idle }

    func canPauseOrResume(recorderReady: Bool, pushToTalk: Bool) -> Bool {
        canPauseOrResume && recorderReady && (!pushToTalk || self == .paused)
    }
}
