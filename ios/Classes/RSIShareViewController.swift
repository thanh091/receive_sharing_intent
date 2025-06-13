//
//  RSIShareViewController.swift
//  receive_sharing_intent
//
//  Created by Kasem Mohamed on 2024-01-25.
//

import UIKit
import Social
import MobileCoreServices
import Photos

@available(swift, introduced: 5.0)
open class RSIShareViewController: UIViewController {
    var hostAppBundleIdentifier = ""
    var appGroupId = ""
    var sharedMedia: [SharedMediaFile] = []
    var processedItemsCount = 0
    var totalItemsCount = 0

    /// Override this method to return false if you don't want to redirect to host app automatically
    /// Default is true
    open func shouldAutoRedirect() -> Bool {
        return true
    }
    
    open override func viewDidLoad() {
        super.viewDidLoad()
        
        // Hide the view since we don't want to show any UI
        view.isHidden = true
        
        // Load group and app id from build info
        loadIds()
        
        // Start processing files immediately
        processSharedContent()
    }
    
    private func processSharedContent() {
        guard let extensionContext = extensionContext,
              let inputItems = extensionContext.inputItems as? [NSExtensionItem] else {
            dismissWithError()
            return
        }
        
        // Handle case where there are no input items
        guard !inputItems.isEmpty else {
            saveAndRedirect()
            return
        }
        
        // Count total attachments to track completion
        totalItemsCount = inputItems.compactMap { $0.attachments }.flatMap { $0 }.count
        
        // If no attachments, just redirect
        guard totalItemsCount > 0 else {
            saveAndRedirect()
            return
        }
        
        // Process all input items
        for inputItem in inputItems {
            processInputItem(inputItem)
        }
    }
    
    private func processInputItem(_ inputItem: NSExtensionItem) {
        guard let attachments = inputItem.attachments else { return }
        
        for (index, attachment) in attachments.enumerated() {
            processAttachment(attachment, itemIndex: index, inputItem: inputItem)
        }
    }
    
    private func processAttachment(_ attachment: NSItemProvider, itemIndex: Int, inputItem: NSExtensionItem) {
        // Find the first matching type
        for type in SharedMediaType.allCases {
            if attachment.hasItemConformingToTypeIdentifier(type.toUTTypeIdentifier) {
                attachment.loadItem(forTypeIdentifier: type.toUTTypeIdentifier) { [weak self] data, error in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        
                        if let error = error {
                            print("Error loading attachment: \(error)")
                            self.handleProcessingComplete()
                            return
                        }
                        
                        self.handleLoadedData(data, type: type, inputItem: inputItem)
                    }
                }
                break // Only process the first matching type
            }
        }
    }
    
    private func handleLoadedData(_ data: NSSecureCoding?, type: SharedMediaType, inputItem: NSExtensionItem) {
        switch type {
        case .text:
            if let text = data as? String {
                handleMedia(forLiteral: text, type: type, inputItem: inputItem)
            }
        case .url:
            if let url = data as? URL {
                handleMedia(forLiteral: url.absoluteString, type: type, inputItem: inputItem)
            }
        default:
            if let url = data as? URL {
                handleMedia(forFile: url, type: type, inputItem: inputItem)
            } else if let image = data as? UIImage {
                handleMedia(forUIImage: image, type: type, inputItem: inputItem)
            }
        }
        
        handleProcessingComplete()
    }
    
    private func handleProcessingComplete() {
        processedItemsCount += 1
        
        // Check if all items have been processed
        if processedItemsCount >= totalItemsCount {
            if shouldAutoRedirect() {
                saveAndRedirect()
            }
        }
    }
    
    private func loadIds() {
        // loading Share extension App Id
        let shareExtensionAppBundleIdentifier = Bundle.main.bundleIdentifier!
        
        
        // extract host app bundle id from ShareExtension id
        // by default it's <hostAppBundleIdentifier>.<ShareExtension>
        // for example: "com.kasem.sharing.Share-Extension" -> com.kasem.sharing
        let lastIndexOfPoint = shareExtensionAppBundleIdentifier.lastIndex(of: ".")
        hostAppBundleIdentifier = String(shareExtensionAppBundleIdentifier[..<lastIndexOfPoint!])
        let defaultAppGroupId = "group.\(hostAppBundleIdentifier)"
        
        
        // loading custom AppGroupId from Build Settings or use group.<hostAppBundleIdentifier>
        let customAppGroupId = Bundle.main.object(forInfoDictionaryKey: kAppGroupIdKey) as? String
        
        appGroupId = customAppGroupId ?? defaultAppGroupId
    }
    
    
    private func handleMedia(forLiteral item: String, type: SharedMediaType, inputItem: NSExtensionItem) {
        sharedMedia.append(SharedMediaFile(
            path: item,
            mimeType: type == .text ? "text/plain": nil,
            type: type
        ))
    }

    private func handleMedia(forUIImage image: UIImage, type: SharedMediaType, inputItem: NSExtensionItem){
        let tempPath = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId)!.appendingPathComponent("TempImage.png")
        if self.writeTempFile(image, to: tempPath) {
            let newPathDecoded = tempPath.absoluteString.removingPercentEncoding!
            sharedMedia.append(SharedMediaFile(
                path: newPathDecoded,
                mimeType: type == .image ? "image/png": nil,
                type: type
            ))
        }
    }
    
    private func handleMedia(forFile url: URL, type: SharedMediaType, inputItem: NSExtensionItem) {
        let fileName = getFileName(from: url, type: type)
        let newPath = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId)!.appendingPathComponent(fileName)
        
        if copyFile(at: url, to: newPath) {
            // The path should be decoded because Flutter is not expecting url encoded file names
            let newPathDecoded = newPath.absoluteString.removingPercentEncoding!;
            if type == .video {
                // Get video thumbnail and duration
                if let videoInfo = getVideoInfo(from: url) {
                    let thumbnailPathDecoded = videoInfo.thumbnail?.removingPercentEncoding;
                    sharedMedia.append(SharedMediaFile(
                        path: newPathDecoded,
                        mimeType: url.mimeType(),
                        thumbnail: thumbnailPathDecoded,
                        duration: videoInfo.duration,
                        type: type
                    ))
                } else {
                    // Fallback if video info extraction fails
                    sharedMedia.append(SharedMediaFile(
                        path: newPathDecoded,
                        mimeType: url.mimeType(),
                        type: type
                    ))
                }
            } else {
                sharedMedia.append(SharedMediaFile(
                    path: newPathDecoded,
                    mimeType: url.mimeType(),
                    type: type
                ))
            }
        }
    }
    
    
    // Save shared media and redirect to host app
    private func saveAndRedirect(message: String? = nil) {
        let userDefaults = UserDefaults(suiteName: appGroupId)
        userDefaults?.set(toData(data: sharedMedia), forKey: kUserDefaultsKey)
        userDefaults?.set(message, forKey: kUserDefaultsMessageKey)
        userDefaults?.synchronize()
        completeRequest()
    }

    private func completeRequest() {
        DispatchQueue.main.async {
            self.extensionContext?.completeRequest(returningItems: nil, completionHandler: { _ in 
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.redirectToHostApp()
                }
            })
        }
    }
    
    private func redirectToHostApp() {
        // ids may not loaded yet so we need loadIds here too
        loadIds()
        let url = URL(string: "\(kSchemePrefix)-\(hostAppBundleIdentifier):share")
        var responder = self as UIResponder?
        
        if #available(iOS 18.0, *) {
            while responder != nil {
                if let application = responder as? UIApplication {
                    application.open(url!, options: [:], completionHandler: nil)
                    break
                }
                responder = responder?.next
            }
        } else {
            let selectorOpenURL = sel_registerName("openURL:")
            
            while (responder != nil) {
                if (responder?.responds(to: selectorOpenURL))! {
                    _ = responder?.perform(selectorOpenURL, with: url)
                    break
                }
                responder = responder!.next
            }

        }
    }
    
    private func dismissWithError() {
        print("[ERROR] Error loading data!")
        DispatchQueue.main.async {
            self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }
    
    private func getFileName(from url: URL, type: SharedMediaType) -> String {
        var name = url.lastPathComponent
        if name.isEmpty {
            switch type {
            case .image:
                name = UUID().uuidString + ".png"
            case .video:
                name = UUID().uuidString + ".mp4"
            case .text:
                name = UUID().uuidString + ".txt"
            default:
                name = UUID().uuidString
            }
        }
        return name
    }

    private func writeTempFile(_ image: UIImage, to dstURL: URL) -> Bool {
        do {
            if FileManager.default.fileExists(atPath: dstURL.path) {
                try FileManager.default.removeItem(at: dstURL)
            }
            let pngData = image.pngData();
            try pngData?.write(to: dstURL);
            return true;
        } catch (let error){
            print("Cannot write to temp file: \(error)");
            return false;
        }
    }
    
    private func copyFile(at srcURL: URL, to dstURL: URL) -> Bool {
        do {
            if FileManager.default.fileExists(atPath: dstURL.path) {
                try FileManager.default.removeItem(at: dstURL)
            }
            try FileManager.default.copyItem(at: srcURL, to: dstURL)
        } catch (let error) {
            print("Cannot copy item at \(srcURL) to \(dstURL): \(error)")
            return false
        }
        return true
    }
    
    private func getVideoInfo(from url: URL) -> (thumbnail: String?, duration: Double)? {
        let asset = AVAsset(url: url)
        let duration = (CMTimeGetSeconds(asset.duration) * 1000).rounded()
        let thumbnailPath = getThumbnailPath(for: url)
        
        if FileManager.default.fileExists(atPath: thumbnailPath.path) {
            return (thumbnail: thumbnailPath.absoluteString, duration: duration)
        }
        
        var saved = false
        let assetImgGenerate = AVAssetImageGenerator(asset: asset)
        assetImgGenerate.appliesPreferredTrackTransform = true
        //        let scale = UIScreen.main.scale
        assetImgGenerate.maximumSize =  CGSize(width: 360, height: 360)
        do {
            let img = try assetImgGenerate.copyCGImage(at: CMTimeMakeWithSeconds(600, preferredTimescale: 1), actualTime: nil)
            try UIImage(cgImage: img).pngData()?.write(to: thumbnailPath)
            saved = true
        } catch {
            saved = false
        }
        
        return saved ? (thumbnail: thumbnailPath.absoluteString, duration: duration): nil
    }
    
    private func getThumbnailPath(for url: URL) -> URL {
        let fileName = Data(url.lastPathComponent.utf8).base64EncodedString().replacingOccurrences(of: "==", with: "")
        let path = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupId)!
            .appendingPathComponent("\(fileName).jpg")
        return path
    }
    
    private func toData(data: [SharedMediaFile]) -> Data {
        let encodedData = try? JSONEncoder().encode(data)
        return encodedData!
    }
}

extension URL {
    public func mimeType() -> String {
        if #available(iOS 14.0, *) {
            if let mimeType = UTType(filenameExtension: self.pathExtension)?.preferredMIMEType {
                return mimeType
            }
        } else {
            if let uti = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, self.pathExtension as NSString, nil)?.takeRetainedValue() {
                if let mimetype = UTTypeCopyPreferredTagWithClass(uti, kUTTagClassMIMEType)?.takeRetainedValue() {
                    return mimetype as String
                }
            }
        }
        
        return "application/octet-stream"
    }
}

