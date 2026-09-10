import SwiftUI

/// Android GameHub / Steam Big Picture-style console game launcher for iOS.
public struct GameHubView: View {
    @ObservedObject private var manager = GameHubManager.shared
    @ObservedObject private var downloader = SteamDownloader.shared
    
    // Callback to trigger wine process launch from ContentView
    public var onLaunchGame: (GameItem) -> Void
    public var onSwitchToDiagnostic: () -> Void
    
    @State private var selectedGame: GameItem? = nil
    @State private var showDetailSheet = false
    @State private var showAddGameSheet = false
    @State private var showDownloadSheet = false
    @State private var featuredGame: GameItem? = nil
    @State private var isJitAttached: Bool = isDebuggerAttached()
    @State private var showJitDetailsAlert = false
    
    public init(
        onLaunchGame: @escaping (GameItem) -> Void,
        onSwitchToDiagnostic: @escaping () -> Void
    ) {
        self.onLaunchGame = onLaunchGame
        self.onSwitchToDiagnostic = onSwitchToDiagnostic
    }
    
    public var body: some View {
        ZStack {
            // Ambient dark gamer background
            Color(red: 0.08, green: 0.09, blue: 0.12)
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Top Navigation Bar
                headerBar
                
                // JIT status banner
                jitBanner
                
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {
                        // Featured Hero Game Banner
                        if let hero = featuredGame ?? manager.games.first {
                            heroBanner(for: hero)
                        }
                        
                        // Category Pills
                        categoryFilterBar
                        
                        // Game Grid
                        gameGridSection
                    }
                    .padding(.bottom, 60)
                }
            }
            
            // Floating Downloader Progress HUD if active
            if downloader.isDownloading {
                downloadProgressHUD
            }
        }
        .sheet(item: $selectedGame) { game in
            GameDetailModal(
                game: game,
                onPlay: { g in
                    selectedGame = nil
                    manager.recordPlay(for: g)
                    onLaunchGame(g)
                },
                onDelete: { g in
                    manager.deleteGame(g)
                    selectedGame = nil
                }
            )
        }
        .sheet(isPresented: $showAddGameSheet) {
            AddGameModal { newGame in
                manager.addGame(newGame)
                showAddGameSheet = false
            }
        }
        .sheet(isPresented: $showDownloadSheet) {
            SteamDownloadModal()
        }
        .alert("JIT (Just-In-Time) コンパイルについて", isPresented: $showJitDetailsAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("現在 JIT が有効化されていません。\nGameHub でのゲーム追加や設定は利用可能ですが、Windows ゲームを高速実行するには JIT の有効化が必要です。\n\n【JIT有効化方法】\n・AltStore: アプリ長押し → Enable JIT\n・SideStore: JIT メニューから有効化\n・Jitterbug / StikDebug を使用")
        }
        .onAppear {
            isJitAttached = isDebuggerAttached()
            if featuredGame == nil {
                featuredGame = manager.games.first(where: { $0.isFavorite }) ?? manager.games.first
            }
        }
    }
    
    // MARK: - JIT Banner
    @ViewBuilder
    private var jitBanner: some View {
        if !isJitAttached {
            Button {
                showJitDetailsAlert = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                    Text("JIT未接続: ゲーム起動には JIT が必要です")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Spacer()
                    Text("詳細")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.yellow.opacity(0.3))
                        .foregroundColor(.yellow)
                        .cornerRadius(4)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.25))
            }
        }
    }
    
    // MARK: - Header Bar
    private var headerBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "gamecontroller.fill")
                    .font(.title2)
                    .foregroundColor(.cyan)
                Text("WiniOS")
                    .font(.title2).fontWeight(.black)
                    .foregroundColor(.white)
                Text("GameHub")
                    .font(.caption).fontWeight(.bold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.cyan.opacity(0.3))
                    .foregroundColor(.cyan)
                    .cornerRadius(4)
            }
            
            Spacer()
            
            // Search Input
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.gray)
                TextField("Search games...", text: $manager.searchQuery)
                    .foregroundColor(.white)
                    .font(.subheadline)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.08))
            .cornerRadius(8)
            .frame(maxWidth: 220)
            
            // Download Button
            Button(action: { showDownloadSheet = true }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                    Text("Download")
                }
                .font(.subheadline).fontWeight(.semibold)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(8)
            }
            
            // Add Game Button
            Button(action: { showAddGameSheet = true }) {
                Image(systemName: "plus")
                    .font(.subheadline).fontWeight(.bold)
                    .padding(8)
                    .background(Color.white.opacity(0.12))
                    .foregroundColor(.white)
                    .clipShape(Circle())
            }
            
            // Switch to Diagnostic View
            Button(action: onSwitchToDiagnostic) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.subheadline)
                    .padding(8)
                    .background(Color.white.opacity(0.12))
                    .foregroundColor(.white)
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(red: 0.11, green: 0.13, blue: 0.17))
    }
    
    // MARK: - Hero Banner
    private func heroBanner(for game: GameItem) -> some View {
        ZStack(alignment: .bottomLeading) {
            // Background Artwork
            AsyncImage(url: game.resolvedCoverUrl) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    LinearGradient(
                        colors: [Color.blue.opacity(0.6), Color.purple.opacity(0.6), Color.black],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            }
            .frame(height: 240)
            .clipped()
            .overlay(
                LinearGradient(
                    colors: [Color.clear, Color(red: 0.08, green: 0.09, blue: 0.12).opacity(0.95)],
                    startPoint: .center,
                    endPoint: .bottom
                )
            )
            
            // Hero Content Info
            VStack(alignment: .leading, spacing: 8) {
                Text(game.category.uppercased())
                    .font(.caption).fontWeight(.heavy)
                    .foregroundColor(.cyan)
                    .tracking(2)
                
                Text(game.title)
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .foregroundColor(.white)
                    .shadow(radius: 4)
                
                HStack(spacing: 14) {
                    Button(action: {
                        manager.recordPlay(for: game)
                        onLaunchGame(game)
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "play.fill")
                            Text("PLAY NOW")
                        }
                        .font(.headline).fontWeight(.bold)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(Color.cyan)
                        .foregroundColor(.black)
                        .cornerRadius(10)
                        .shadow(color: .cyan.opacity(0.4), radius: 8, x: 0, y: 4)
                    }
                    
                    Button(action: { selectedGame = game }) {
                        HStack(spacing: 6) {
                            Image(systemName: "info.circle")
                            Text("Details")
                        }
                        .font(.subheadline).fontWeight(.semibold)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Color.white.opacity(0.15))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                }
            }
            .padding(20)
        }
        .cornerRadius(16)
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }
    
    // MARK: - Category Filter Bar
    private var categoryFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(manager.categories, id: \.self) { cat in
                    Button(action: { manager.selectedCategory = cat }) {
                        Text(cat)
                            .font(.subheadline).fontWeight(.semibold)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                manager.selectedCategory == cat
                                ? Color.cyan
                                : Color.white.opacity(0.08)
                            )
                            .foregroundColor(manager.selectedCategory == cat ? .black : .white)
                            .cornerRadius(20)
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }
    
    // MARK: - Game Grid
    private var gameGridSection: some View {
        let columns = [
            GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 16)
        ]
        
        return VStack(alignment: .leading, spacing: 12) {
            Text("Library (\(manager.filteredGames.count))")
                .font(.title3).fontWeight(.bold)
                .foregroundColor(.white)
                .padding(.horizontal, 20)
            
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(manager.filteredGames) { game in
                    GamePosterCard(game: game) {
                        selectedGame = game
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }
    
    // MARK: - Download Progress HUD
    private var downloadProgressHUD: some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                ProgressView(value: downloader.downloadProgress)
                    .progressViewStyle(LinearProgressViewStyle(tint: .cyan))
                    .frame(maxWidth: 160)
                
                Text(downloader.statusMessage)
                    .font(.caption).fontWeight(.medium)
                    .foregroundColor(.white)
                
                Spacer()
                
                Button("Cancel") {
                    downloader.cancelDownload()
                }
                .font(.caption).fontWeight(.bold)
                .foregroundColor(.red)
            }
            .padding()
            .background(Color(red: 0.15, green: 0.18, blue: 0.24))
            .cornerRadius(12)
            .shadow(radius: 10)
            .padding(20)
        }
    }
}

// MARK: - Game Poster Card Component
struct GamePosterCard: View {
    let game: GameItem
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    // Cover Poster
                    AsyncImage(url: game.resolvedCoverUrl) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            ZStack {
                                Color.gray.opacity(0.2)
                                Image(systemName: "gamecontroller")
                                    .font(.system(size: 36))
                                    .foregroundColor(.gray)
                            }
                        }
                    }
                    .frame(width: 150, height: 210)
                    .clipped()
                    .cornerRadius(12)
                    .shadow(color: .black.opacity(0.4), radius: 6, x: 0, y: 4)
                    
                    if game.isFavorite {
                        Image(systemName: "star.fill")
                            .foregroundColor(.yellow)
                            .padding(8)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                            .padding(6)
                    }
                }
                
                Text(game.title)
                    .font(.caption).fontWeight(.bold)
                    .foregroundColor(.white)
                    .lineLimit(1)
                
                Text(game.category)
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
            }
            .frame(width: 150)
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

// Scale effect button style
struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Game Detail Modal
struct GameDetailModal: View {
    @Environment(\.dismiss) var dismiss
    let game: GameItem
    let onPlay: (GameItem) -> Void
    let onDelete: (GameItem) -> Void
    
    var body: some View {
        NavigationView {
            ZStack {
                Color(red: 0.10, green: 0.11, blue: 0.15).ignoresSafeArea()
                
                ScrollView {
                    VStack(alignment: .center, spacing: 20) {
                        // Large Cover
                        AsyncImage(url: game.resolvedCoverUrl) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFit()
                            default:
                                Image(systemName: "gamecontroller")
                                    .font(.system(size: 64)).foregroundColor(.gray)
                            }
                        }
                        .frame(maxHeight: 240)
                        .cornerRadius(12)
                        
                        Text(game.title)
                            .font(.title2).fontWeight(.black)
                            .foregroundColor(.white)
                        
                        Text("EXE: \(game.exePath)")
                            .font(.caption).foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                        
                        // Play Button
                        Button(action: { onPlay(game) }) {
                            HStack {
                                Image(systemName: "play.fill")
                                Text("LAUNCH GAME")
                            }
                            .font(.headline).fontWeight(.bold)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.cyan)
                            .foregroundColor(.black)
                            .cornerRadius(12)
                        }
                        .padding(.horizontal, 20)
                        
                        // Danger actions
                        Button(role: .destructive, action: { onDelete(game) }) {
                            Text("Remove from Library")
                                .font(.subheadline)
                        }
                        .padding(.top, 10)
                    }
                    .padding(20)
                }
            }
            .navigationTitle(game.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Add Game Modal
struct AddGameModal: View {
    @Environment(\.dismiss) var dismiss
    @State private var title = ""
    @State private var exePath = "C:\\Program Files\\"
    @State private var steamAppId = ""
    @State private var category = "Action"
    
    let onSave: (GameItem) -> Void
    
    var body: some View {
        NavigationView {
            Form {
                Section("Game Info") {
                    TextField("Game Title", text: $title)
                    TextField("Wine EXE Path (e.g. C:\\...\\game.exe)", text: $exePath)
                    TextField("Steam AppID (Optional, for cover art)", text: $steamAppId)
                        .keyboardType(.numberPad)
                    TextField("Category", text: $category)
                }
            }
            .navigationTitle("Add Windows Game")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Add") {
                        let newG = GameItem(
                            title: title.isEmpty ? "New Game" : title,
                            exePath: exePath,
                            steamAppId: steamAppId.isEmpty ? nil : steamAppId,
                            category: category
                        )
                        onSave(newG)
                    }
                }
            }
        }
    }
}

// MARK: - Steam Download Modal
struct SteamDownloadModal: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var downloader = SteamDownloader.shared
    
    @State private var downloadType = 0 // 0: URL, 1: Steam AppID
    @State private var urlInput = ""
    @State private var gameTitle = ""
    @State private var appIdInput = ""
    
    var body: some View {
        NavigationView {
            Form {
                Section("Download Source") {
                    Picker("Type", selection: $downloadType) {
                        Text("Direct URL (ZIP)").tag(0)
                        Text("Steam AppID (Depot)").tag(1)
                    }
                    .pickerStyle(.segmented)
                }
                
                if downloadType == 0 {
                    Section("Game Package URL") {
                        TextField("Game Title", text: $gameTitle)
                        TextField("https://.../game.zip", text: $urlInput)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                        Text("Supports direct download links from Google Drive, Dropbox, or custom servers. Will be extracted directly to Wine's Program Files.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                } else {
                    Section("Steam Depot Downloader") {
                        TextField("Steam AppID (e.g. 1229490)", text: $appIdInput)
                            .keyboardType(.numberPad)
                        TextField("Game Title", text: $gameTitle)
                        Text("Downloads game content directly from Steam CDN into Wine container.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                
                Section {
                    Button("Start Download") {
                        if downloadType == 0 {
                            downloader.downloadAndInstallFromUrl(
                                urlStr: urlInput,
                                gameTitle: gameTitle.isEmpty ? "Imported Game" : gameTitle,
                                steamAppId: appIdInput.isEmpty ? nil : appIdInput
                            ) { _ in
                                dismiss()
                            }
                        } else {
                            // Steam AppID URL or Depot
                            let steamUrl = "https://steamcdn-a.akamaihd.net/steam/apps/\(appIdInput)/header.jpg"
                            downloader.downloadAndInstallFromUrl(
                                urlStr: urlInput.isEmpty ? steamUrl : urlInput,
                                gameTitle: gameTitle.isEmpty ? "Steam Game \(appIdInput)" : gameTitle,
                                steamAppId: appIdInput
                            ) { _ in
                                dismiss()
                            }
                        }
                    }
                    .disabled(downloader.isDownloading)
                }
            }
            .navigationTitle("Download Game")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
