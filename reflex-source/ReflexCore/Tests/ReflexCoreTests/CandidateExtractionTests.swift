import Testing
@testable import ReflexCore

/// Entity extraction. Dispatchers parse only `Candidates`, never the raw
/// transcript, so a wrong cut here is a wrong action everywhere.
@Suite("PayloadExtractor")
struct CandidateExtractionTests {
    private func extract(_ transcript: String, target: String?) -> Candidates {
        PayloadExtractor.extract(from: transcript, target: target)
    }

    @Test("free text after a typing verb becomes the payload")
    func extractsTypedText() {
        #expect(extract("type hello world", target: "type_text").text == "hello world")
        #expect(extract("write out the summary", target: "type_text").text == "the summary")
    }

    @Test("\"in <non-app>\" stays part of the typed text")
    func nonAppTargetIsNotStripped() {
        let candidates = extract("type buy milk in the morning", target: "type_text")
        #expect(candidates.text == "buy milk in the morning")
        #expect(candidates.inApp == nil)
    }

    @Test("a trailing submit phrase sets the flag and leaves the payload clean")
    func foldsSubmit() {
        let candidates = extract("type hello and press enter", target: "type_text")
        #expect(candidates.submit)
        #expect(candidates.text == "hello")
    }

    @Test("scroll direction and amount")
    func extractsScroll() {
        #expect(extract("scroll down", target: "scroll").direction == "down")
        #expect(extract("scroll up a little", target: "scroll").direction == "up")
        #expect(extract("scroll down a lot", target: "scroll").amount == "a_lot")
    }

    @Test("volume intent")
    func extractsVolume() {
        #expect(extract("set the volume to 30", target: "media_control").volumeOp == .percent(30))
        #expect(extract("mute", target: "media_control").volumeOp == .mute)
        #expect(extract("louder", target: "media_control").volumeOp == .up(delta: 15))
        #expect(extract("quieter", target: "media_control").volumeOp == .down(delta: 15))
    }

    @Test("link ordinals are zero based")
    func extractsLinkIndex() {
        #expect(extract("open the first result", target: "browser_command").linkIndex == 0)
        #expect(extract("open the third link", target: "browser_command").linkIndex == 2)
    }

    @Test("a named payload becomes the title")
    func extractsTitle() {
        #expect(extract("new document called q3 report", target: "new_item").title == "q3 report")
    }

    @Test("folder aliases resolve to canonical names")
    func extractsFolder() {
        #expect(extract("open the downloads folder", target: "open_folder").folder == "Downloads")
        #expect(extract("open my documents", target: "open_folder").folder == "Documents")
    }

    @Test("site-targeted search splits host and query")
    func extractsSiteSearch() {
        let search = PayloadExtractor.siteSearch(in: "youtube.com search selfie")
        #expect(search?.host == "youtube.com")
        #expect(search?.query == "selfie")
    }

    @Test("a spoken domain is normalized")
    func normalizesSpokenDomain() {
        #expect(PayloadExtractor.normalizeSpokenDomain("youtube dot com") == "youtube.com")
        #expect(PayloadExtractor.normalizeSpokenDomain("news dot ycombinator dot com") == "news.ycombinator.com")
    }

    @Test("site tokens are recognized", arguments: [
        "youtube", "github.com", "wikipedia", "translate",
    ])
    func recognizesSiteTokens(token: String) {
        #expect(PayloadExtractor.isSiteToken(token))
    }

    @Test("ordinary words are not site tokens", arguments: [
        "morning", "invoice", "the weather", "ridgeline",
    ])
    func rejectsNonSiteTokens(token: String) {
        #expect(!PayloadExtractor.isSiteToken(token))
    }
}
