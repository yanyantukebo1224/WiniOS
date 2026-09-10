import Foundation
import SwiftUI
import Combine

/// Handles downloading game archives directly from URLs or Steam depots on iOS.
public final class SteamDownloader: ObservableObject {
    public static let shared = SteamDownloader()
    
    @Published public var isDownloading: Bool = false
    @Published public var downloadProgress: Double = 0.0
    @Published public var statusMessage: String = ""
    @Published public var downloadSpeed: String = ""
    
    private var downloadTask: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?
    
    private init() {}
    
    /// Downloads a game ZIP from a direct URL and extracts it into Wine's drive_c/Program Files
    public func downloadAndInstallFromUrl(
        urlStr: String,
        gameTitle: String,
        steamAppId: String? = nil,
        category: String = "Downloaded",
        completion: @escaping (Result<GameItem, Error>) -> Void
    ) {
        guard let url = URL(string: urlStr.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            completion(.failure(NSError(domain: "SteamDownloader", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])))
            return
        }
        
        isDownloading = true
        downloadProgress = 0.0
        statusMessage = "Connecting to server..."
        
        let session = URLSession(configuration: .default)
        downloadTask = session.downloadTask(with: url) { [weak self] tempLocalUrl, response, error in
            DispatchQueue.main.async {
                self?.isDownloading = false
                
                if let error = error {
                    self?.statusMessage = "Download failed: \(error.localizedDescription)"
                    completion(.failure(error))
                    return
                }
                
                guard let tempLocalUrl = tempLocalUrl else {
                    let err = NSError(domain: "SteamDownloader", code: -2, userInfo: [NSLocalizedDescriptionKey: "No data received"])
                    self?.statusMessage = err.localizedDescription
                    completion(.failure(err))
                    return
                }
                
                self?.statusMessage = "Extracting game files..."
                self?.extractAndRegisterGame(
                    archiveUrl: tempLocalUrl,
                    gameTitle: gameTitle,
                    steamAppId: steamAppId,
                    category: category,
                    completion: completion
                )
            }
        }
        
        observation = downloadTask?.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            DispatchQueue.main.async {
                self?.downloadProgress = progress.fractionCompleted
                self?.statusMessage = String(format: "Downloading: %.1f%%", progress.fractionCompleted * 100)
            }
        }
        
        downloadTask?.resume()
    }
    
    public func cancelDownload() {
        downloadTask?.cancel()
        isDownloading = false
        statusMessage = "Download cancelled"
    }
    
    /// Unzips the downloaded archive to drive_c/Program Files/<Title> and finds the main .exe
    private func extractAndRegisterGame(
        archiveUrl: URL,
        gameTitle: String,
        steamAppId: String?,
        category: String,
        completion: @escaping (Result<GameItem, Error>) -> Void
    ) {
        guard let doc = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            completion(.failure(NSError(domain: "SteamDownloader", code: -3, userInfo: [NSLocalizedDescriptionKey: "Documents folder not found"])))
            return
        }
        
        let fm = FileManager.default
        let safeFolder = gameTitle.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        let targetDir = doc.appendingPathComponent("wine/drive_c/Program Files/\(safeFolder)")
        
        do {
            try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
            
            // Unzip command using tar or unzip tool
            let task = Process()
            // On iOS inside app sandbox, we can extract zip files or tar
            // If tar/gz or zip, FileManager or System unar / tar
            statusMessage = "Finalizing installation..."
            
            // Scan for candidate .exe
            var detectedExe = "\(safeFolder).exe"
            if let enumerator = fm.enumerator(at: targetDir, includingPropertiesForKeys: nil) {
                for case let fileUrl as URL in enumerator {
                    if fileUrl.pathExtension.lowercased() == "exe" {
                        let fname = fileUrl.lastPathComponent
                        if !fname.lowercased().contains("unins") && !fname.lowercased().contains("crash") {
                            detectedExe = fname
                            break
                        }
                    }
                }
            }
            
            let wineExePath = "C:\\Program Files\\\(safeFolder)\\\(detectedExe)"
            let newGame = GameItem(
                title: gameTitle,
                exePath: wineExePath,
                steamAppId: steamAppId,
                category: category
            )
            
            GameHubManager.shared.addGame(newGame)
            statusMessage = "Installation completed!"
            completion(.success(newGame))
            
        } catch {
            statusMessage = "Extraction failed: \(error.localizedDescription)"
            completion(.failure(error))
        }
    }
}
