import UIKit
import Social
import MobileCoreServices
import Photos
import UniformTypeIdentifiers
import AVFoundation

/// Share Extension View Controller for iOS 18+ compatibility
/// Replaces deprecated SLComposeServiceViewController to fix navigation bar constraint crashes
@available(swift, introduced: 5.0)
open class RSIShareViewController: UIViewController {
    
    // MARK: - Properties
    
    /// Host application bundle identifier (e.g., "com.example.app")
    var hostAppBundleIdentifier = ""
    
    /// App Group identifier for shared container access
    var appGroupId = ""
    
    /// Array to store all processed shared media files
    var sharedMedia: [SharedMediaFile] = []
    
    /// Counter for tracking processed attachments (thread-safe when accessed from main queue)
    private var processedCount = 0
    
    /// Total number of attachments to process
    private var totalAttachments = 0
    
    // MARK: - Lifecycle
    
    /// Override this method to control automatic redirection behavior
    /// - Returns: true to automatically redirect to host app, false to stay in extension
    open func shouldAutoRedirect() -> Bool {
        return true
    }
    
    open override func viewDidLoad() {
        super.viewDidLoad()
        
        print("✅ RSIShareViewController.viewDidLoad() — loaded successfully")
        
        // Setup minimal UI (user sees system share sheet, not this view)
        view.backgroundColor = .systemBackground
        
        // Load App Group and Bundle IDs from configuration
        loadIds()
        
        // Start processing shared content asynchronously
        processSharedContent()
    }
    
    // MARK: - Content Processing
    
    /// Processes all shared content items from the extension context
    private func processSharedContent() {
        guard let extensionContext = extensionContext,
              let inputItems = extensionContext.inputItems as? [NSExtensionItem] else {
            dismissWithError()
            return
        }
        
        // Count total attachments across all input items
        for item in inputItems {
            if let attachments = item.attachments {
                totalAttachments += attachments.count
            }
        }
        
        // Validate we have attachments to process
        if totalAttachments == 0 {
            dismissWithError()
            return
        }
        
        // Process each attachment asynchronously
        for item in inputItems {
            guard let attachments = item.attachments else { continue }
            
            for attachment in attachments {
                processAttachment(attachment)
            }
        }
    }
    
    /// Processes a single attachment by identifying its type and loading its data
    /// - Parameter attachment: The NSItemProvider to process
    private func processAttachment(_ attachment: NSItemProvider) {
        // Check each media type in priority order (text, url, image, video, file)
        for type in SharedMediaType.allCases {
            if attachment.hasItemConformingToTypeIdentifier(type.toUTTypeIdentifier) {
                // Load item data asynchronously
                attachment.loadItem(forTypeIdentifier: type.toUTTypeIdentifier) { [weak self] data, error in
                    guard let this = self else { return }
                    
                    if let error = error {
                        print("Error loading item: \(error)")
                        DispatchQueue.main.async {
                            this.incrementProcessedCount()
                        }
                        return
                    }
                    
                    // Handle different data types based on media type
                    switch type {
                    case .text:
                        if let text = data as? String {
                            this.handleMedia(forLiteral: text, type: type)
                        } else if let url = data as? URL {
                            this.handleMedia(forFile: url, type: type)
                        } else {
                            DispatchQueue.main.async {
                                this.incrementProcessedCount()
                            }
                        }
                    case .url:
                        if let url = data as? URL {
                            this.handleMedia(forLiteral: url.absoluteString, type: type)
                        } else {
                            DispatchQueue.main.async {
                                this.incrementProcessedCount()
                            }
                        }
                    case .image, .video, .file:
                        if let url = data as? URL {
                            this.handleMedia(forFile: url, type: type)
                        } else if let image = data as? UIImage {
                            this.handleMedia(forUIImage: image, type: type)
                        } else {
                            DispatchQueue.main.async {
                                this.incrementProcessedCount()
                            }
                        }
                    }
                }
                return // Process only the first matching type for this attachment
            }
        }
        
        // No matching type found, increment counter to avoid blocking
        DispatchQueue.main.async {
            self.incrementProcessedCount()
        }
    }
    
    /// Increments the processed counter and triggers save/redirect when all items are done
    /// MUST be called on main queue to ensure thread safety
    private func incrementProcessedCount() {
        processedCount += 1
        if processedCount == totalAttachments {
            if shouldAutoRedirect() {
                saveAndRedirect()
            }
        }
    }
    
    // MARK: - Configuration
    
    /// Loads and configures App Group ID and host app bundle identifier
    private func loadIds() {
        // Extract host app bundle ID from share extension ID
        // e.g., "com.example.app.ShareExtension" -> "com.example.app"
        let shareExtensionAppBundleIdentifier = Bundle.main.bundleIdentifier!
        let lastIndexOfPoint = shareExtensionAppBundleIdentifier.lastIndex(of: ".")
        hostAppBundleIdentifier = String(shareExtensionAppBundleIdentifier[..<lastIndexOfPoint!])
        let defaultAppGroupId = "group.\(hostAppBundleIdentifier)"
        
        // Retrieve custom App Group ID from Info.plist
        let customAppGroupId = Bundle.main.object(forInfoDictionaryKey: kAppGroupIdKey) as? String
        
        // Use custom App Group ID only if it's not nil and not empty
        if let groupId = customAppGroupId, !groupId.trimmingCharacters(in: .whitespaces).isEmpty {
            appGroupId = groupId
        } else {
            appGroupId = defaultAppGroupId
        }

        print("Host App Bundle ID: \(hostAppBundleIdentifier)")
        print("App Group ID: \(appGroupId)")
    }

    // MARK: - Media Handlers
    
    /// Handles text or URL content (no file copying needed)
    /// - Parameters:
    ///   - item: The text or URL string
    ///   - type: The media type (text or url)
    private func handleMedia(forLiteral item: String, type: SharedMediaType) {
        DispatchQueue.main.async {
            self.sharedMedia.append(SharedMediaFile(
                path: item,
                mimeType: type == .text ? "text/plain": nil,
                type: type
            ))
            self.incrementProcessedCount()
        }
    }
    
    /// Handles UIImage content by saving to shared container
    /// - Parameters:
    ///   - image: The UIImage to save
    ///   - type: The media type (should be .image)
    private func handleMedia(forUIImage image: UIImage, type: SharedMediaType) {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            print("Error: Cannot access app group container")
            DispatchQueue.main.async {
                self.incrementProcessedCount()
            }
            return
        }
        
        // Generate unique filename to avoid collisions
        let tempPath = containerURL.appendingPathComponent("TempImage_\(UUID().uuidString).png")
        
        if self.writeTempFile(image, to: tempPath) {
            let newPathDecoded = tempPath.absoluteString.removingPercentEncoding ?? tempPath.absoluteString
            DispatchQueue.main.async {
                self.sharedMedia.append(SharedMediaFile(
                    path: newPathDecoded,
                    mimeType: "image/png",
                    type: .image
                ))
                self.incrementProcessedCount()
            }
        } else {
            DispatchQueue.main.async {
                self.incrementProcessedCount()
            }
        }
    }
    
    /// Handles file-based content (images, videos, PDFs, etc.)
    /// - Parameters:
    ///   - url: The source file URL
    ///   - type: The media type
    private func handleMedia(forFile url: URL, type: SharedMediaType) {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            print("Error: Cannot access app group container")
            DispatchQueue.main.async {
                self.incrementProcessedCount()
            }
            return
        }
        
        let fileName = getFileName(from: url, type: type)
        let newPath = containerURL.appendingPathComponent(fileName)
        
        if copyFile(at: url, to: newPath) {
            let newPathDecoded = newPath.absoluteString.removingPercentEncoding ?? newPath.absoluteString
            
            // Generate thumbnail and duration for video files
            if type == .video {
                if let videoInfo = getVideoInfo(from: newPath) {
                    let thumbnailPathDecoded = videoInfo.thumbnail?.removingPercentEncoding
                    DispatchQueue.main.async {
                        self.sharedMedia.append(SharedMediaFile(
                            path: newPathDecoded,
                            mimeType: newPath.mimeType(),
                            thumbnail: thumbnailPathDecoded,
                            duration: videoInfo.duration,
                            type: type
                        ))
                        self.incrementProcessedCount()
                    }
                } else {
                    // Failed to get video info, skip this item
                    DispatchQueue.main.async {
                        self.incrementProcessedCount()
                    }
                }
            } else {
                // Non-video file, add without thumbnail
                DispatchQueue.main.async {
                    self.sharedMedia.append(SharedMediaFile(
                        path: newPathDecoded,
                        mimeType: newPath.mimeType(),
                        type: type
                    ))
                    self.incrementProcessedCount()
                }
            }
        } else {
            // Failed to copy file, skip this item
            DispatchQueue.main.async {
                self.incrementProcessedCount()
            }
        }
    }
    
    // MARK: - Save & Redirect
    
    /// Saves all processed media to UserDefaults and redirects to host app
    /// - Parameter message: Optional message text (currently unused)
    private func saveAndRedirect(message: String? = nil) {
        guard let userDefaults = UserDefaults(suiteName: appGroupId) else {
            print("Error: Cannot access UserDefaults for app group: \(appGroupId)")
            dismissWithError()
            return
        }
        
        // Encode and save shared media to UserDefaults
        let encodedData = toData(data: sharedMedia)
        userDefaults.set(encodedData, forKey: kUserDefaultsKey)
        userDefaults.set(message, forKey: kUserDefaultsMessageKey)
        userDefaults.synchronize()
        
        print("Saved \(sharedMedia.count) items to UserDefaults")
        
        redirectToHostApp()
    }
    
    /// Redirects to the host application via custom URL scheme
    private func redirectToHostApp() {
        loadIds()
        let urlString = "\(kSchemePrefix)-\(hostAppBundleIdentifier):share"
        guard let url = URL(string: urlString) else {
            print("Error: Invalid URL: \(urlString)")
            extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            return
        }
        
        print("Redirecting to: \(urlString)")
        
        // Walk the responder chain to find UIApplication (iOS 18+ compatible)
        var responder: UIResponder? = self
        var foundApplication = false
        
        while responder != nil {
            if let application = responder as? UIApplication {
                application.open(url, options: [:]) { success in
                    print("URL open success: \(success)")
                }
                foundApplication = true
                break
            }
            responder = responder?.next
        }
        
        if !foundApplication {
            print("Warning: Could not find UIApplication in responder chain")
        }
        
        // Complete the extension request to dismiss the share sheet
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
    
    /// Shows an error alert and dismisses the extension
    private func dismissWithError() {
        print("[ERROR] Error loading data!")
        DispatchQueue.main.async {
            let alert = UIAlertController(title: "Error", message: "Error loading data", preferredStyle: .alert)
            let action = UIAlertAction(title: "OK", style: .cancel) { _ in
                self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            }
            alert.addAction(action)
            self.present(alert, animated: true, completion: nil)
        }
    }
    
    // MARK: - File Utilities
    
    /// Generates a filename from URL or creates a UUID-based name
    /// - Parameters:
    ///   - url: Source file URL
    ///   - type: Media type for default extension
    /// - Returns: Filename to use in shared container
    private func getFileName(from url: URL, type: SharedMediaType) -> String {
        var name = url.lastPathComponent
        if name.isEmpty {
            let ext: String
            switch type {
            case .image:
                ext = ".png"
            case .video:
                ext = ".mp4"
            case .file:
                ext = ".pdf"
            case .text:
                ext = ".txt"
            case .url:
                ext = ".txt"
            }
            name = UUID().uuidString + ext
        }
        return name
    }
    
    /// Writes UIImage to file as PNG
    /// - Parameters:
    ///   - image: The image to write
    ///   - dstURL: Destination file URL
    /// - Returns: true if successful, false otherwise
    private func writeTempFile(_ image: UIImage, to dstURL: URL) -> Bool {
        do {
            // Remove existing file if present
            if FileManager.default.fileExists(atPath: dstURL.path) {
                try FileManager.default.removeItem(at: dstURL)
            }
            guard let pngData = image.pngData() else {
                print("Error: Could not get PNG data from image")
                return false
            }
            try pngData.write(to: dstURL)
            return true
        } catch {
            print("Cannot write to temp file: \(error)")
            return false
        }
    }
    
    /// Copies file from source to destination with security-scoped resource access
    /// - Parameters:
    ///   - srcURL: Source file URL
    ///   - dstURL: Destination file URL
    /// - Returns: true if successful, false otherwise
    private func copyFile(at srcURL: URL, to dstURL: URL) -> Bool {
        do {
            // Remove existing file if present
            if FileManager.default.fileExists(atPath: dstURL.path) {
                try FileManager.default.removeItem(at: dstURL)
            }
            
            // Access security-scoped resource for files from other apps
            let accessing = srcURL.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    srcURL.stopAccessingSecurityScopedResource()
                }
            }
            
            try FileManager.default.copyItem(at: srcURL, to: dstURL)
            return true
        } catch {
            print("Cannot copy item at \(srcURL) to \(dstURL): \(error)")
            return false
        }
    }
    
    // MARK: - Video Processing
    
    /// Extracts video thumbnail and duration
    /// - Parameter url: Video file URL
    /// - Returns: Tuple with thumbnail path and duration in milliseconds, or nil if failed
    private func getVideoInfo(from url: URL) -> (thumbnail: String?, duration: Double)? {
        let asset = AVAsset(url: url)
        let duration = (CMTimeGetSeconds(asset.duration) * 1000).rounded()
        let thumbnailPath = getThumbnailPath(for: url)
        
        // Return cached thumbnail if it exists
        if FileManager.default.fileExists(atPath: thumbnailPath.path) {
            return (thumbnail: thumbnailPath.absoluteString, duration: duration)
        }
        
        // Generate new thumbnail
        let assetImgGenerate = AVAssetImageGenerator(asset: asset)
        assetImgGenerate.appliesPreferredTrackTransform = true
        assetImgGenerate.maximumSize = CGSize(width: 360, height: 360)
        
        do {
            let time = CMTimeMakeWithSeconds(1.0, preferredTimescale: 600)
            let img = try assetImgGenerate.copyCGImage(at: time, actualTime: nil)
            try UIImage(cgImage: img).pngData()?.write(to: thumbnailPath)
            return (thumbnail: thumbnailPath.absoluteString, duration: duration)
        } catch {
            print("Error generating video thumbnail: \(error)")
            return nil
        }
    }
    
    /// Generates thumbnail file path for a video
    /// - Parameter url: Video file URL
    /// - Returns: Thumbnail file path in shared container
    private func getThumbnailPath(for url: URL) -> URL {
        let fileName = Data(url.lastPathComponent.utf8).base64EncodedString().replacingOccurrences(of: "==", with: "")
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            fatalError("Cannot access app group container")
        }
        return containerURL.appendingPathComponent("\(fileName).jpg")
    }
    
    // MARK: - JSON Encoding
    
    /// Encodes SharedMediaFile array to JSON Data
    /// - Parameter data: Array of SharedMediaFile objects
    /// - Returns: JSON-encoded Data, or empty Data if encoding fails
    private func toData(data: [SharedMediaFile]) -> Data {
        guard let encodedData = try? JSONEncoder().encode(data) else {
            return Data()
        }
        return encodedData
    }
}

// MARK: - URL Extension

extension URL {
    /// Determines MIME type from file extension
    /// - Returns: MIME type string (e.g., "image/png", "video/mp4")
    public func mimeType() -> String {
        if #available(iOS 14.0, *) {
            if let mimeType = UTType(filenameExtension: self.pathExtension)?.preferredMIMEType {
                return mimeType
            }
        } else {
            // Fallback for iOS 13 and earlier
            if let uti = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, self.pathExtension as NSString, nil)?.takeRetainedValue() {
                if let mimetype = UTTypeCopyPreferredTagWithClass(uti, kUTTagClassMIMEType)?.takeRetainedValue() {
                    return mimetype as String
                }
            }
        }
        return "application/octet-stream"
    }
}
