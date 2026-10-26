def patch(path, pairs):
    s = open(path).read()
    for old, new in pairs:
        assert old in s, f"{path}: not found:\n{old[:160]}"
        assert s.count(old) == 1, f"{path}: ambiguous:\n{old[:160]}"
        s = s.replace(old, new)
    open(path, 'w').write(s)

# ---- Router: spoken domains ("github dot com") are bare entities; two more
# media phrasings the demo corpus uses. ----
patch('reflexApp/ReflexCore/Sources/ReflexCore/RuleRouter.swift', [
(
'''        // Bare entity — "safari", "calendar", "youtube.com": a one-word phrase
        // that is exactly a known app or site is a launch, not a query.
        let bareEntity = t.trimmingCharacters(in: .whitespacesAndNewlines)''',
'''        // Bare entity — "safari", "calendar", "youtube.com", "github dot com": a
        // one-word phrase that is exactly a known app or site is a launch, not a
        // query. Spoken domains are normalized first so the space in "dot com"
        // does not disqualify them.
        let bareEntity = PayloadExtractor.normalizeSpokenDomain(t.trimmingCharacters(in: .whitespacesAndNewlines))'''
),
(
'''            || t.contains("next track") || t.contains("previous track") || t.contains("last song")
            || t.contains("last one") || t.contains("playback")
            || t.contains("skip") || t.contains("stop the music") || t.contains("stop playing")''',
'''            || t.contains("next track") || t.contains("previous track") || t.contains("last song")
            || t.contains("last one") || t.contains("previous one") || t.contains("playback")
            || t.contains("skip") || t.contains("stop the music") || t.contains("stop playing")
            || t.contains("stop for a")'''
),
])

# ---- Dispatcher: system op parsing must see the same normalized text the
# router matched ("desktop, please" -> "desktop"). ----
patch('reflexApp/ReflexCore/Sources/ReflexCore/ActionDispatcher.swift', [
(
'''    public static func systemOperation(for transcript: String) -> SystemOperation? {
        let lower = transcript.lowercased()''',
'''    public static func systemOperation(for transcript: String) -> SystemOperation? {
        // Same filler stripping the router applies, so a phrase it matched
        // ("desktop, please") parses here too.
        let lower = PayloadExtractor.normalizeIntent(transcript).lowercased()'''
),
])

# ---- Engine: a marker word inside a real command is not silence.
# "silence it" is mute. ----
patch('reflexApp/ReflexCore/Sources/ReflexCore/ReflexSystemEngine.swift', [
(
'''        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = cleaned.lowercased()
        let bracketed = cleaned.hasPrefix("[") && cleaned.hasSuffix("]")
        let highSignal = ["silence", "no speech", "inaudible", "applause"]
            .contains { lowered.contains($0) }
        return bracketed || highSignal''',
'''        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = cleaned.lowercased()
        let bracketed = cleaned.hasPrefix("[") && cleaned.hasSuffix("]")
        // The utterance must *be* the marker: "silence it" is mute, not silence.
        let bare = lowered.trimmingCharacters(in: CharacterSet(charactersIn: " ().,!?;"))
        let highSignal = ["silence", "silent", "no speech", "inaudible", "applause"].contains(bare)
        return bracketed || highSignal'''
),
])

# ---- Harness scoring: the dispatcher's openApp checks looksLikeURL before
# AppResolver, so "go to google" opens google.com and not Chrome. ----
patch('ReflexCore/Sources/ReflexCLI/ReplayHarness.swift', [
(
'''    static func canonicalEntity(_ name: String) -> String {
        let lowered = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = AppResolver.url(for: lowered) {
            return url.deletingPathExtension().lastPathComponent.lowercased()
        }
        var e = lowered.replacingOccurrences(of: "www.", with: "")
        for tld in [".com", ".org", ".net", ".io", ".co"] where e.hasSuffix(tld) {
            e = String(e.dropLast(tld.count))
            break
        }
        return e
    }''',
'''    static func canonicalEntity(_ name: String) -> String {
        let lowered = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // The dispatcher's openApp checks looksLikeURL *before* AppResolver, so
        // "go to google" opens google.com, not Chrome. Score that.
        let domain = PayloadExtractor.normalizeSpokenDomain(lowered)
        if domain.contains("."), PayloadExtractor.isSiteToken(domain) {
            return stripTLD(domain)
        }
        if let url = AppResolver.url(for: lowered) {
            return url.deletingPathExtension().lastPathComponent.lowercased()
        }
        return stripTLD(lowered)
    }

    static func stripTLD(_ raw: String) -> String {
        var e = raw.replacingOccurrences(of: "www.", with: "")
        for tld in [".com", ".org", ".net", ".io", ".co"] where e.hasSuffix(tld) {
            e = String(e.dropLast(tld.count))
            break
        }
        return e
    }'''
),
])
print("patched 4 files")
