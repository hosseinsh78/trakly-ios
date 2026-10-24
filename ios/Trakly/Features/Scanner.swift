import SwiftUI
import TraklyCore
import UIKit
import Vision
import VisionKit

/// The barcode scanner (S11, docs/specs/phase10-apps-and-stores.md §B4.1 `scan`, §E9): VisionKit's
/// `DataScannerViewController` for the requested symbologies (every iOS 17 iPhone has an A12 or newer); when it is not
/// supported or not available (the Simulator, a denied camera) the sheet says «دوربین این گوشی بارکد را نمی خواند.» and
/// answers `unavailable` when closed; the first code answers with the success haptic; «لغو» answers `cancelled`.
@MainActor
final class Scanner: NSObject {
    private var reply: BridgeReply?
    private weak var sheet: UINavigationController?

    static func symbologies(_ formats: [String]) -> [VNBarcodeSymbology] {
        var out: [VNBarcodeSymbology] = []
        for format in formats.map({ $0.lowercased().replacingOccurrences(of: "_", with: "") }) {
            switch format {
            case "ean13": out.append(.ean13)
            case "ean8": out.append(.ean8)
            case "upca", "upce": out.append(.upce)
            case "code128": out.append(.code128)
            case "code39": out.append(.code39)
            case "code93": out.append(.code93)
            case "itf", "itf14": out.append(.itf14)
            case "qr", "qrcode": out.append(.qr)
            case "datamatrix": out.append(.dataMatrix)
            case "pdf417": out.append(.pdf417)
            case "aztec": out.append(.aztec)
            case "codabar": out.append(.codabar)
            default: break
            }
        }
        return out.isEmpty ? [.ean13, .ean8, .upce, .code128, .code39, .qr] : out
    }

    static func format(of symbology: VNBarcodeSymbology?) -> String {
        switch symbology {
        case .ean13?: return "ean13"
        case .ean8?: return "ean8"
        case .upce?: return "upce"
        case .code128?: return "code128"
        case .code39?: return "code39"
        case .code93?: return "code93"
        case .itf14?: return "itf"
        case .qr?: return "qr"
        case .dataMatrix?: return "datamatrix"
        case .pdf417?: return "pdf417"
        case .aztec?: return "aztec"
        case .codabar?: return "codabar"
        default: return "unknown"
        }
    }

    /// Whether the device can scan now.
    static var ready: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func scan(formats: [String], from presenter: UIViewController?, reply: BridgeReply) {
        guard let presenter else {
            reply.error("unavailable")
            return
        }
        self.reply?.error("cancelled")
        self.reply = reply
        let content: UIViewController
        if Scanner.ready {
            let scanner = DataScannerViewController(
                recognizedDataTypes: [.barcode(symbologies: Scanner.symbologies(formats))],
                qualityLevel: .balanced,
                recognizesMultipleItems: false,
                isHighFrameRateTrackingEnabled: false,
                isPinchToZoomEnabled: true,
                isGuidanceEnabled: true,
                isHighlightingEnabled: true
            )
            scanner.delegate = self
            content = scanner
        } else {
            content = UIHostingController(rootView: ScannerUnavailable())
            content.view.backgroundColor = Theme.canvas
        }
        content.title = L.s("scan_title")
        let cancelItem = UIBarButtonItem(title: L.s("cancel"), style: .plain, target: self, action: #selector(cancelTapped))
        cancelItem.accessibilityIdentifier = "scan.cancel"
        content.navigationItem.leftBarButtonItem = cancelItem
        let navigation = UINavigationController(rootViewController: content)
        navigation.view.semanticContentAttribute = .forceRightToLeft
        navigation.navigationBar.semanticContentAttribute = .forceRightToLeft
        navigation.modalPresentationStyle = .pageSheet
        navigation.presentationController?.delegate = self
        sheet = navigation
        presenter.present(navigation, animated: true) {
            if let scanner = content as? DataScannerViewController {
                try? scanner.startScanning()
            }
        }
    }

    @objc private func cancelTapped() {
        finish(code: nil, format: nil)
    }

    private func finish(code: String?, format: String?) {
        let pending = reply
        reply = nil
        (sheet?.viewControllers.first as? DataScannerViewController)?.stopScanning()
        sheet?.dismiss(animated: true)
        guard let pending else { return }
        if let code {
            Haptics.play("success")
            pending.ok(JSONObject([("code", .string(code)), ("format", .string(format ?? "unknown"))]))
        } else {
            pending.error(Scanner.ready ? "cancelled" : "unavailable")
        }
    }
}

extension Scanner: DataScannerViewControllerDelegate {
    func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
        for item in addedItems {
            if case let .barcode(barcode) = item, let value = barcode.payloadStringValue, !value.isEmpty {
                finish(code: value, format: Scanner.format(of: barcode.observation.symbology))
                return
            }
        }
    }
}

extension Scanner: UIAdaptivePresentationControllerDelegate {
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        finish(code: nil, format: nil)
    }
}

/// The scanner's state without a usable camera.
struct ScannerUnavailable: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "barcode.viewfinder")
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(Color(Theme.ink3))
                .accessibilityHidden(true)
            Text(L.s("scan_unavailable"))
                .font(Theme.swiftUIFont(16, bold: true, relativeTo: .headline))
                .foregroundStyle(Color(Theme.ink))
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("scan.unavailable")
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(Theme.canvas))
        .environment(\.layoutDirection, .rightToLeft)
    }
}
