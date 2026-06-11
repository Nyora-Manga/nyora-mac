import Foundation

struct CharacterProfile: Codable {
    let originalName: String
    let targetName: String
    let gender: String
    let tone: String
}

struct ChapterNarrative: Codable {
    let summary: String
    let characters: [CharacterProfile]
}

actor StoryBrain {
    private var currentNarrative: ChapterNarrative?

    func narrativeContext() -> String {
        guard let n = currentNarrative else { return "Initial pages of the chapter." }
        let chars = n.characters
            .map { "- \($0.originalName) (\($0.targetName)): \($0.gender), \($0.tone) style" }
            .joined(separator: "\n")
        return "Chapter Context: \(n.summary)\nCharacters Identified:\n\(chars)"
    }

    func update(_ narrative: ChapterNarrative) {
        currentNarrative = narrative
    }

    func clear() {
        currentNarrative = nil
    }
}
