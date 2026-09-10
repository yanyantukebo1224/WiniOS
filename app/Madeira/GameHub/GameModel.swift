import Foundation
import SwiftUI

/// Represents a game entry in the GameHub launcher.
public struct GameItem: Identifiable, Codable, Equatable, Hashable {
    public var id: UUID
    public var title: String
    public var exePath: String             // e.g. "C:\\Program Files\\Thumper\\THUMPER_win10.exe" or "cube-x64.exe"
    public var arguments: String           // e.g. "-force-d3d11"
    public var coverArtUrl: String?        // Custom URL or Steam cover
    public var localCoverImageName: String? // Saved in app documents
    public var steamAppId: String?         // Steam AppID for metadata / cover fetch
    public var category: String            // "Action", "RPG", "Indie", "Benchmarks"
    public var playTimeMinutes: Int
    public var lastPlayed: Date?
    public var isFavorite: Bool
    
    public init(
        id: UUID = UUID(),
        title: String,
        exePath: String,
        arguments: String = "",
        coverArtUrl: String? = nil,
        localCoverImageName: String? = nil,
        steamAppId: String? = nil,
        category: String = "All",
        playTimeMinutes: Int = 0,
        lastPlayed: Date? = nil,
        isFavorite: Bool = false
    ) {
        self.id = id
        self.title = title
        self.exePath = exePath
        self.arguments = arguments
        self.coverArtUrl = coverArtUrl
        self.localCoverImageName = localCoverImageName
        self.steamAppId = steamAppId
        self.category = category
        self.playTimeMinutes = playTimeMinutes
        self.lastPlayed = lastPlayed
        self.isFavorite = isFavorite
    }
    
    /// Auto-generates Steam cover URL if AppID is present and no custom URL
    public var resolvedCoverUrl: URL? {
        if let custom = coverArtUrl, let url = URL(string: custom) {
            return url
        }
        if let appId = steamAppId, !appId.isEmpty {
            // Steam vertical library art (600x900)
            return URL(string: "https://steamcdn-a.akamaihd.net/steam/apps/\(appId)/library_600x900_2x.jpg")
                ?? URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/\(appId)/header.jpg")
        }
        return nil
    }
}

/// Manages game library persistence and filesystem scanning.
public final class GameHubManager: ObservableObject {
    public static let shared = GameHubManager()
    
    @Published public var games: [GameItem] = []
    @Published public var selectedCategory: String = "All"
    @Published public var searchQuery: String = ""
    
    private let gamesJsonFileName = "winios_games.json"
    
    private init() {
        loadGames()
        if games.isEmpty {
            setupDefaultGames()
        }
        scanInstalledGames()
    }
    
    private var gamesJsonUrl: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(gamesJsonFileName)
    }
    
    public func loadGames() {
        guard let url = gamesJsonUrl, let data = try? Data(contentsOf: url) else { return }
        if let loaded = try? JSONDecoder().decode([GameItem].self, from: data) {
            self.games = loaded
        }
    }
    
    public func saveGames() {
        guard let url = gamesJsonUrl, let data = try? JSONEncoder().encode(games) else { return }
        try? data.write(to: url, options: .atomic)
    }
    
    public func addGame(_ game: GameItem) {
        games.append(game)
        saveGames()
    }
    
    public func updateGame(_ game: GameItem) {
        if let idx = games.firstIndex(where: { $0.id == game.id }) {
            games[idx] = game
            saveGames()
        }
    }
    
    public func deleteGame(_ game: GameItem) {
        games.removeAll { $0.id == game.id }
        saveGames()
    }
    
    public func recordPlay(for game: GameItem) {
        if let idx = games.firstIndex(where: { $0.id == game.id }) {
            games[idx].lastPlayed = Date()
            saveGames()
        }
    }
    
    public var categories: [String] {
        var set = Set(["All", "Favorites"])
        for g in games {
            if !g.category.isEmpty { set.insert(g.category) }
        }
        return Array(set).sorted()
    }
    
    public var filteredGames: [GameItem] {
        games.filter { game in
            let matchesCategory: Bool
            if selectedCategory == "All" {
                matchesCategory = true
            } else if selectedCategory == "Favorites" {
                matchesCategory = game.isFavorite
            } else {
                matchesCategory = game.category == selectedCategory
            }
            
            let matchesSearch = searchQuery.isEmpty || game.title.localizedCaseInsensitiveContains(searchQuery)
            return matchesCategory && matchesSearch
        }
    }
    
    /// Default presets to show out-of-the-box
    private func setupDefaultGames() {
        let defaults: [GameItem] = [
            GameItem(
                title: "Direct3D 11 Rotating Cube",
                exePath: "cube-x64.exe",
                category: "Benchmarks",
                isFavorite: true
            ),
            GameItem(
                title: "Thumper",
                exePath: "C:\\Program Files\\Thumper\\THUMPER_win10.exe",
                steamAppId: "356400",
                category: "Action",
                isFavorite: true
            ),
            GameItem(
                title: "ULTRAKILL",
                exePath: "C:\\Program Files\\ULTRAKILL\\ULTRAKILL.exe",
                arguments: "-force-d3d11",
                steamAppId: "1229490",
                category: "Action",
                isFavorite: true
            ),
            GameItem(
                title: "Hollow Knight",
                exePath: "C:\\Program Files\\Hollow Knight\\hollow_knight.exe",
                steamAppId: "367520",
                category: "Indie"
            ),
            GameItem(
                title: "Vampire Survivors",
                exePath: "C:\\Program Files\\Vampire Survivors\\VampireSurvivors.exe",
                steamAppId: "1794680",
                category: "Indie"
            )
        ]
        self.games = defaults
        saveGames()
    }
    
    /// Auto-scan Program Files for installed exes
    public func scanInstalledGames() {
        guard let doc = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let progFiles = doc.appendingPathComponent("wine/drive_c/Program Files")
        guard let enumerator = FileManager.default.enumerator(at: progFiles, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
        
        for case let fileUrl as URL in enumerator {
            if fileUrl.pathExtension.lowercased() == "exe" {
                let filename = fileUrl.deletingPathExtension().lastPathComponent
                // Skip uninstaller or helpers
                if filename.lowercased().contains("unins") || filename.lowercased().contains("crash") || filename.lowercased().contains("helper") {
                    continue
                }
                let relativePath = fileUrl.path.replacingOccurrences(of: progFiles.path, with: "C:\\Program Files")
                    .replacingOccurrences(of: "/", with: "\\")
                
                if !games.contains(where: { $0.exePath.lowercased() == relativePath.lowercased() }) {
                    let newGame = GameItem(
                        title: filename.replacingOccurrences(of: "_", with: " "),
                        exePath: relativePath,
                        category: "Scanned"
                    )
                    games.append(newGame)
                }
            }
        }
        saveGames()
    }
}
