import XCTest
@testable import VoiceOperator

final class DictationCorpusTests: XCTestCase {
    private var directory: URL!
    private var corpus: DictationCorpus!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("vo-corpus-\(UUID().uuidString)")
        corpus = DictationCorpus(directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func recognition(_ transcript: Transcript, source: DictationCorpus.Source = .dictation,
                             provider: any TranscriptionProvider = ParakeetProvider()) -> DictationCorpus.Recognition {
        .init(source: source, provider: provider, transcript: transcript, fellBack: false, seconds: 2, mic: "Mic")
    }

    func testNamesTheModelThatRecognizedIt() {
        let clip = URL(fileURLWithPath: "/clips/a.wav")
        let id = UUID()
        corpus.record(recognition(Transcript(text: "hello")), clipAt: clip, id: id)
        let entry = corpus.entries().first
        XCTAssertEqual(entry?.id, id)
        XCTAssertEqual(entry?.clip, "/clips/a.wav")
        XCTAssertEqual(entry?.recognition.provider, "parakeet")
        XCTAssertEqual(entry?.recognition.model, "parakeet-tdt-0.6b-v2")
        XCTAssertEqual(entry?.recognition.recognized, "hello")
        XCTAssertNil(entry?.recognition.cleaned)
    }

    func testKeepsRecognizedTextBesideTheCleanedText() {
        corpus.record(recognition(Transcript(text: "Hello.", raw: "um hello")), clipAt: URL(fileURLWithPath: "/a.wav"))
        XCTAssertEqual(corpus.entries().first?.recognition.recognized, "um hello")
        XCTAssertEqual(corpus.entries().first?.recognition.cleaned, "Hello.")
    }

    func testACleanedUpProviderReportsTheModelBehindIt() {
        let provider = CleanedUpProvider(base: ParakeetProvider(), clean: { $0 })
        XCTAssertEqual(recognition(Transcript(text: "x"), provider: provider).model, "parakeet-tdt-0.6b-v2")
    }

    func testKeepsAClipNothingElseKeeps() throws {
        let wav = WAVFile(sampleRate: 16_000, samples: Data(count: 320)).data
        corpus.record(recognition(Transcript(text: "from the phone"), source: .phone), keeping: wav)
        let entry = try XCTUnwrap(corpus.entries().first)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: entry.clip)), wav)
        XCTAssertEqual(entry.recognition.source, .phone)
    }

    func testAppendsInOrder() {
        for word in ["one", "two", "three"] {
            corpus.record(recognition(Transcript(text: word)), clipAt: URL(fileURLWithPath: "/a.wav"))
        }
        XCTAssertEqual(corpus.entries().map(\.recognition.recognized), ["one", "two", "three"])
    }

    func testSkipsEmptyRecognitions() {
        corpus.record(recognition(Transcript(text: "  \n")), clipAt: URL(fileURLWithPath: "/a.wav"))
        XCTAssertTrue(corpus.entries().isEmpty)
    }
}
