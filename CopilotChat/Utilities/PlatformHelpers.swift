import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum PlatformHelpers {
    static func copyToClipboard(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    static func clipboardString() -> String? {
        #if canImport(UIKit)
        return UIPasteboard.general.string
        #elseif canImport(AppKit)
        return NSPasteboard.general.string(forType: .string)
        #else
        return nil
        #endif
    }

    static func clipboardHasImages() -> Bool {
        #if canImport(UIKit)
        return UIPasteboard.general.hasImages
        #elseif canImport(AppKit)
        return NSPasteboard.general.canReadObject(forClasses: [NSImage.self])
        #else
        return false
        #endif
    }

    static func clipboardImage() -> Data? {
        #if canImport(UIKit)
        return UIPasteboard.general.image?.pngData()
        #elseif canImport(AppKit)
        guard let nsImage = NSPasteboard.general.readObjects(forClasses: [NSImage.self])?.first as? NSImage else { return nil }
        guard let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return png
        #else
        return nil
        #endif
    }

    @MainActor static func openURL(_ url: URL) async {
        #if canImport(UIKit)
        await UIApplication.shared.open(url)
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }

    static var deviceId: String {
        #if canImport(UIKit)
        return UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
        #elseif canImport(AppKit)
        return Host.current().localizedName ?? "mac"
        #else
        return "unknown"
        #endif
    }

    static var systemVersion: String {
        #if canImport(UIKit)
        return UIDevice.current.systemVersion
        #elseif canImport(AppKit)
        return ProcessInfo.processInfo.operatingSystemVersionString
        #else
        return "unknown"
        #endif
    }

    static var deviceModel: String {
        #if canImport(UIKit)
        return UIDevice.current.model
        #elseif canImport(AppKit)
        return "Mac"
        #else
        return "unknown"
        #endif
    }

    static var deviceName: String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #elseif canImport(AppKit)
        return Host.current().localizedName ?? "Mac"
        #else
        return "unknown"
        #endif
    }

    static var platformId: String {
        #if canImport(UIKit)
        return "ios"
        #elseif canImport(AppKit)
        return "macos"
        #else
        return "unknown"
        #endif
    }
}