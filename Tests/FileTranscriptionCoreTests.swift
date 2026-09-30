import Foundation

enum FileTranscriptionCoreTests {
    static func run() {
        audioFilesAreAccepted()
        anythingElseIsRefusedBeforeItIsRead()
        emptyAndOversizedFilesAreRefused()
        aMissingFileSaysSoRatherThanCallingItEmpty()
        aRunningJobReportsProgressAndNoTranscript()
        aFinishedJobCarriesItsTranscript()
        aFailedJobCarriesItsReason()
    }

    private static func audioFilesAreAccepted() {
        for name in ["meeting.wav", "Recording.MP3", "voice memo.m4a", "take.flac", "clip.mp4"] {
            TestSupport.expect(
                FileTranscriptionCore.refusal(forName: name, sizeInBytes: 1024) == nil,
                "\(name) should be accepted"
            )
        }
    }

    /// Refused up front rather than several seconds later with a codec error.
    private static func anythingElseIsRefusedBeforeItIsRead() {
        let refusal = FileTranscriptionCore.refusal(forName: "notes.pdf", sizeInBytes: 1024)
        TestSupport.expect(refusal == .unsupportedType("pdf"), "a PDF is not audio")
        TestSupport.expect(
            refusal?.message.contains(".pdf files") == true,
            "the message names the type, got \(refusal?.message ?? "nil")"
        )
        TestSupport.expect(
            FileTranscriptionCore.refusal(forName: "noextension", sizeInBytes: 10) == .unsupportedType(""),
            "a file with no extension is refused"
        )
    }

    private static func emptyAndOversizedFilesAreRefused() {
        TestSupport.expect(
            FileTranscriptionCore.refusal(forName: "a.wav", sizeInBytes: 0) == .empty,
            "an empty file is refused"
        )
        let huge = FileTranscriptionCore.maximumBytes + 1
        TestSupport.expect(
            FileTranscriptionCore.refusal(forName: "a.wav", sizeInBytes: huge) == .tooLarge(bytes: huge),
            "an oversized file is refused"
        )
    }

    /// A file that was moved and a file that is there but empty are different
    /// mistakes, and reporting both as "empty" sends people looking in the
    /// wrong place.
    private static func aMissingFileSaysSoRatherThanCallingItEmpty() {
        let refusal = FileTranscriptionCore.refusal(forName: "gone.wav", sizeInBytes: 0, exists: false)
        TestSupport.expect(refusal == .missing, "a missing file is not an empty one")
        TestSupport.expect(
            refusal?.message.contains("could not find") == true,
            "the message says it is missing, got \(refusal?.message ?? "nil")"
        )
    }

    private static func aRunningJobReportsProgressAndNoTranscript() {
        let job = FileTranscriptionCore.Job(id: "j1", fileName: "a.wav", state: .running(progress: 0.4))
        let payload = job.payload
        TestSupport.expectEqual(payload["state"] as? String, "running")
        TestSupport.expectEqual(payload["progress"] as? Double, 0.4)
        TestSupport.expect(payload["transcript"] == nil, "a running job has no transcript yet")
    }

    private static func aFinishedJobCarriesItsTranscript() {
        var job = FileTranscriptionCore.Job(id: "j2", fileName: "a.wav")
        job.state = .finished(transcript: "hello there")
        job.engine = "local"
        let payload = job.payload
        TestSupport.expectEqual(payload["state"] as? String, "finished")
        TestSupport.expectEqual(payload["transcript"] as? String, "hello there")
        TestSupport.expectEqual(payload["engine"] as? String, "local")
        TestSupport.expect(payload["progress"] == nil, "a finished job does not also report progress")
    }

    private static func aFailedJobCarriesItsReason() {
        var job = FileTranscriptionCore.Job(id: "j3", fileName: "a.wav")
        job.state = .failed(message: "no speech")
        TestSupport.expectEqual(job.payload["state"] as? String, "failed")
        TestSupport.expectEqual(job.payload["error"] as? String, "no speech")
    }
}
