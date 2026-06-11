import Foundation

// HighScore.java port: top-3 track/score table. UserDefaults replaces the
// Android .mvmdata file.
enum HighScore {

    static let trackCount = 3
    static let maxViewLength = 22    // MAX_VIEW_TRACK

    private static let tracksKey = "HighScoreTracks"
    private static let scoresKey = "HighScoreScores"

    private(set) static var tracks = [String](repeating: "", count: trackCount)
    private(set) static var scores = [Int](repeating: 0, count: trackCount)

    static func load() {
        let defaults = UserDefaults.standard
        if let saved = defaults.stringArray(forKey: tracksKey), saved.count == trackCount {
            tracks = saved
        }
        if let saved = defaults.array(forKey: scoresKey) as? [Int], saved.count == trackCount {
            scores = saved
        }
    }

    private static func save() {
        UserDefaults.standard.set(tracks, forKey: tracksKey)
        UserDefaults.standard.set(scores, forKey: scoresKey)
    }

    static func viewTrack(at index: Int) -> String {
        String(tracks[index].prefix(maxViewLength))
    }

    // FlyingActivity.gameOverData insertion, verbatim.
    static func submit(title: String, score: Int) {
        if score >= scores[0] {
            tracks[2] = tracks[1]; scores[2] = scores[1]
            tracks[1] = tracks[0]; scores[1] = scores[0]
            tracks[0] = title; scores[0] = score
            save()
        } else if score >= scores[1] {
            tracks[2] = tracks[1]; scores[2] = scores[1]
            tracks[1] = title; scores[1] = score
            save()
        } else if score >= scores[2] {
            tracks[2] = title; scores[2] = score
            save()
        }
    }
}
