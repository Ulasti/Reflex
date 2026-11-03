import Testing
import Foundation
@testable import ReflexCore

@Suite("Music entity resolver")
struct MusicEntityResolverTests {
    @Test("normalizes weekend alias")
    func normalize() {
        let r = MusicEntityResolver()
        #expect(r.normalize("Weekend") == "the weeknd")
    }

    @Test("resolves exact name with high score")
    func resolveExact() async {
        let r = MusicEntityResolver()
        let entities = [
            MusicEntity(id: "1", name: "The Weeknd", artist: "The Weeknd", source: "local", score: 0),
            MusicEntity(id: "2", name: "Weeknd Vibes", artist: "DJ X", source: "local", score: 0)
        ]
        let res = r.resolve(query: "weekend", candidates: entities)
        if case .resolved(let e) = res {
            #expect(e.name == "The Weeknd")
        } else {
            #expect(Bool(false), "expected resolved")
        }
    }

    @Test("no match for unknown")
    func noMatch() {
        let r = MusicEntityResolver()
        let res = r.resolve(query: "zzzzzz", candidates: [MusicEntity(id: "1", name: "The Weeknd", source: "local", score: 0)])
        if case .noMatch = res { } else { #expect(Bool(false), "expected noMatch") }
    }

    @Test("in-memory provider returns entities")
    func provider() async {
        let p = InMemoryMusicSourceProvider(entities: [MusicEntity(id: "1", name: "X", source: "local")])
        let got = await p.search(query: "x", entityType: .artist)
        #expect(got.count == 1)
    }
}

@Suite("Container resolver")
struct ContainerResolverTests {
    @Test("exact match")
    func exact() {
        let c = ContainerResolver()
        #expect(c.resolve(spoken: "Inbox", candidates: ["Inbox", "Drafts"]) == "Inbox")
    }

    @Test("prefix match")
    func prefix() {
        let c = ContainerResolver()
        #expect(c.resolve(spoken: "draft", candidates: ["Inbox", "Drafts"]) == "Drafts")
    }

    @Test("empty falls back to first")
    func empty() {
        let c = ContainerResolver()
        #expect(c.resolve(spoken: "", candidates: ["Inbox", "Drafts"]) == "Inbox")
    }
}

@Suite("Music intent")
struct MusicIntentTests {
    @Test("default operation is play")
    func defaultOp() {
        let i = MusicIntent(entityType: .artist, query: "weekend")
        #expect(i.operation == .play)
    }
}
