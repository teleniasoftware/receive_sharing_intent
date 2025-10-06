import Flutter
import UIKit
import Photos

// MARK: - Constants

/// Prefix used for URL schemes to open the host app.
public let kSchemePrefix = "ShareMedia"

/// UserDefaults key used to store shared media data.
public let kUserDefaultsKey = "ShareKey"

/// UserDefaults key used to store any shared message text.
public let kUserDefaultsMessageKey = "ShareMessageKey"

/// Info.plist key for retrieving a custom App Group identifier.
public let kAppGroupIdKey = "AppGroupId"

// MARK: - Plugin Implementation

/// A Flutter plugin that handles receiving content from iOS Share Extensions.
/// This class manages both method calls and event streams for sharing data between the extension and the Flutter app.
public class SwiftReceiveSharingIntentPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    
    // MARK: - Channel Identifiers
    
    static let kMessagesChannel = "receive_sharing_intent/messages"
    static let kEventsChannelMedia = "receive_sharing_intent/events-media"
    
    // MARK: - Properties
    
    /// Media received when the app launches from a cold start.
    private var initialMedia: [SharedMediaFile]?
    
    /// The most recent batch of shared media received while the app is active.
    private var latestMedia: [SharedMediaFile]?
    
    /// Sink used for sending media updates to the Flutter layer.
    private var eventSinkMedia: FlutterEventSink?
    
    // MARK: - Singleton Instance
    
    /// A singleton instance, required to call functions directly from the AppDelegate.
    /// This avoids conflicts with other libraries that also implement `application(_:open:options:)`.
    public static let instance = SwiftReceiveSharingIntentPlugin()
    
    // MARK: - Registration
    
    /// Registers this plugin with the Flutter engine.
    /// - Parameter registrar: The Flutter registrar used for channel communication.
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: kMessagesChannel, binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: channel)
        
        let eventChannelMedia = FlutterEventChannel(name: kEventsChannelMedia, binaryMessenger: registrar.messenger())
        eventChannelMedia.setStreamHandler(instance)
        
        registrar.addApplicationDelegate(instance)
    }
    
    // MARK: - Flutter Method Handling
    
    /// Handles incoming method calls from the Flutter side.
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getInitialMedia":
            result(toJson(data: self.initialMedia))
        case "reset":
            self.initialMedia = nil
            self.latestMedia = nil
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    // MARK: - URL Scheme Verification
    
    /// Validates if a given URL matches this app’s custom scheme.
    /// - Parameter url: The incoming URL to verify.
    /// - Returns: `true` if the URL starts with `"ShareMedia-<bundleId>"`, otherwise `false`.
    public func hasMatchingSchemePrefix(url: URL?) -> Bool {
        if let url = url, let appDomain = Bundle.main.bundleIdentifier {
            return url.absoluteString.hasPrefix("\(kSchemePrefix)-\(appDomain)")
        }
        return false
    }
    
    // MARK: - App Lifecycle Handlers
    
    /// Called when the app is launched via a shared URL while closed.
    public func application(_ application: UIApplication,
                            didFinishLaunchingWithOptions launchOptions: [AnyHashable: Any] = [:]) -> Bool {
        if let url = launchOptions[UIApplication.LaunchOptionsKey.url] as? URL {
            if hasMatchingSchemePrefix(url: url) {
                return handleUrl(url: url, setInitialData: true)
            }
            return true
        } else if let activityDict = launchOptions[UIApplication.LaunchOptionsKey.userActivityDictionary] as? [AnyHashable: Any] {
            for key in activityDict.keys {
                if let userActivity = activityDict[key] as? NSUserActivity,
                   let url = userActivity.webpageURL,
                   hasMatchingSchemePrefix(url: url) {
                    return handleUrl(url: url, setInitialData: true)
                }
            }
        }
        return true
    }
    
    /// Handles incoming URLs when the app is already running.
    public func application(_ application: UIApplication,
                            open url: URL,
                            options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        if hasMatchingSchemePrefix(url: url) {
            return handleUrl(url: url, setInitialData: false)
        }
        return false
    }
    
    /// Handles activity continuation (used by systems like Firebase Dynamic Links).
    public func application(_ application: UIApplication,
                            continue userActivity: NSUserActivity,
                            restorationHandler: @escaping ([Any]) -> Void) -> Bool {
        if let url = userActivity.webpageURL, hasMatchingSchemePrefix(url: url) {
            return handleUrl(url: url, setInitialData: true)
        }
        return false
    }
    
    // MARK: - URL Handling
    
    /// Handles incoming shared URLs, reads data from the app group container,
    /// decodes the shared content, and forwards it to Flutter.
    private func handleUrl(url: URL?, setInitialData: Bool) -> Bool {
        let appGroupId = Bundle.main.object(forInfoDictionaryKey: kAppGroupIdKey) as? String
        let defaultGroupId = "group.\(Bundle.main.bundleIdentifier!)"
        
        guard let userDefaults = UserDefaults(suiteName: appGroupId ?? defaultGroupId) else {
            print("Error: Cannot access UserDefaults for app group")
            return false
        }
        
        let message = userDefaults.string(forKey: kUserDefaultsMessageKey)
        
        guard let json = waitForSharedData(userDefaults, key: kUserDefaultsKey) else {
            print("No shared data found in UserDefaults after retry")
            return true
        }
        
        guard let sharedArray = decode(data: json) else {
            print("Error: Cannot decode shared data")
            return false
        }
        
        let sharedMediaFiles: [SharedMediaFile] = sharedArray.compactMap {
            guard let path = $0.type == .text || $0.type == .url ? $0.path
                    : getAbsolutePath(for: $0.path) else {
                return nil
            }
            
            return SharedMediaFile(
                path: path,
                mimeType: $0.mimeType,
                thumbnail: getAbsolutePath(for: $0.thumbnail),
                duration: $0.duration,
                message: message,
                type: $0.type
            )
        }
        
        latestMedia = sharedMediaFiles
        if setInitialData { initialMedia = latestMedia }
        eventSinkMedia?(toJson(data: latestMedia))
        
        // Clean up UserDefaults after processing
        userDefaults.removeObject(forKey: kUserDefaultsKey)
        userDefaults.removeObject(forKey: kUserDefaultsMessageKey)
        userDefaults.synchronize()
        
        return true
    }
    
    // MARK: - Shared Data Handling
    
    /// Waits for shared data to appear in `UserDefaults`.
    private func waitForSharedData(_ userDefaults: UserDefaults,
                                   key: String,
                                   retries: Int = 5,
                                   delay: UInt32 = 100_000) -> Data? {
        for _ in 0..<retries {
            if let data = userDefaults.object(forKey: key) as? Data {
                return data
            }
            usleep(delay)
        }
        return nil
    }
    
    // MARK: - Flutter Event Handling
    
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSinkMedia = events
        return nil
    }
    
    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSinkMedia = nil
        return nil
    }
    
    // MARK: - File Path Helpers
    
    /// Resolves a local identifier or URL to an absolute file path.
    private func getAbsolutePath(for identifier: String?) -> String? {
        guard let identifier else { return nil }
        
        if identifier.starts(with: "file://") || identifier.starts(with: "/var/mobile/Media") || identifier.starts(with: "/private/var/mobile") {
            return identifier.replacingOccurrences(of: "file://", with: "")
        }
        
        guard let phAsset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            return nil
        }
        
        let (url, _) = getFullSizeImageURLAndOrientation(for: phAsset)
        return url
    }
    
    /// Retrieves full-size file path and orientation for a given `PHAsset`.
    private func getFullSizeImageURLAndOrientation(for asset: PHAsset) -> (String?, Int) {
        var url: String? = nil
        var orientation: Int = 0
        let semaphore = DispatchSemaphore(value: 0)
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true
        asset.requestContentEditingInput(with: options) { input, _ in
            orientation = Int(input?.fullSizeImageOrientation ?? 0)
            url = input?.fullSizeImageURL?.path
            semaphore.signal()
        }
        semaphore.wait()
        return (url, orientation)
    }
    
    // MARK: - JSON Decoding
    
    struct SharedMediaPayload: Codable {
        let attachments: [SharedMediaFile]
        let content: String
    }

    /// Decodes shared media data from JSON using multiple fallback strategies.
    private func decode(data: Data) -> [SharedMediaFile]? {
        let preprocessedData = preprocessJson(data)
        
        if let payload = try? JSONDecoder().decode(SharedMediaPayload.self, from: preprocessedData) {
            return payload.attachments
        }
        if let array = try? JSONDecoder().decode([SharedMediaFile].self, from: preprocessedData) {
            return array
        }
        if let single = try? JSONDecoder().decode(SharedMediaFile.self, from: preprocessedData) {
            return [single]
        }
        
        print("Error: Could not decode SharedMediaFile")
        return nil
    }

    /// Converts legacy JSON format (integer-based type) into string-based.
    private func preprocessJson(_ data: Data) -> Data {
        do {
            guard var jsonDict = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  var attachments = jsonDict["attachments"] as? [[String: Any]] else {
                return data
            }
            
            for i in 0..<attachments.count {
                if let typeInt = attachments[i]["type"] as? Int {
                    let typeStr: String
                    switch typeInt {
                    case 0: typeStr = "image"
                    case 1: typeStr = "video"
                    case 2: typeStr = "text"
                    case 3: typeStr = "file"
                    case 4: typeStr = "url"
                    default: typeStr = "file"
                    }
                    attachments[i]["type"] = typeStr
                }
            }
            
            jsonDict["attachments"] = attachments
            return try JSONSerialization.data(withJSONObject: jsonDict, options: [])
        } catch {
            print("Error preprocessing JSON: \(error)")
            return data
        }
    }
    
    // MARK: - JSON Encoding
    
    /// Converts an array of `SharedMediaFile` objects into a JSON string.
    private func toJson(data: [SharedMediaFile]?) -> String? {
        guard let data else { return nil }
        do {
            let encoded = try JSONEncoder().encode(data)
            return String(data: encoded, encoding: .utf8)
        } catch {
            print("Error encoding to JSON: \(error)")
            return nil
        }
    }
}

// MARK: - SharedMediaFile Model

/// Represents a single shared media item (image, video, text, file, or URL).
public class SharedMediaFile: Codable {
    var path: String
    var mimeType: String?
    var thumbnail: String?
    var duration: Double?
    var message: String?
    var type: SharedMediaType
    
    public init(path: String,
                mimeType: String? = nil,
                thumbnail: String? = nil,
                duration: Double? = nil,
                message: String? = nil,
                type: SharedMediaType) {
        self.path = path
        self.mimeType = mimeType
        self.thumbnail = thumbnail
        self.duration = duration
        self.message = message
        self.type = type
    }
}

// MARK: - Media Type Enum

/// Supported media types that can be shared from the iOS Share Extension.
public enum SharedMediaType: String, Codable, CaseIterable {
    case image
    case video
    case text
    case file
    case url
    
    /// Returns the UTType identifier string for each media type.
    public var toUTTypeIdentifier: String {
        if #available(iOS 14.0, *) {
            switch self {
            case .image: return UTType.image.identifier
            case .video: return UTType.movie.identifier
            case .text: return UTType.text.identifier
            case .file: return UTType.fileURL.identifier
            case .url: return UTType.url.identifier
            }
        }
        switch self {
        case .image: return "public.image"
        case .video: return "public.movie"
        case .text: return "public.text"
        case .file: return "public.file-url"
        case .url: return "public.url"
        }
    }
}
