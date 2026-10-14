import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

@MainActor
public struct QRView: View {
    @ObservedObject private var model: QRModel
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .body) private var cameraHeight = 280.0
    private let navigation: QRNavigationActions
    @SessionViewState private var requestingCamera = false

    public init(model: QRModel, navigation: QRNavigationActions) {
        self.model = model; self.navigation = navigation
    }

    public var body: some View {
        EncounterScreen {
            modePicker
            SessionCard {
                VStack(spacing: 20) {
                    if model.segment == .show { showCode } else { scanCode }
                    Text(SessionStrings.text(.confirmed)).font(.footnote).foregroundStyle(EncounterPalette.inkSecondary)
                }.multilineTextAlignment(.center).frame(maxWidth: .infinity)
            }
            if let error = model.error {
                SessionCard {
                    EncounterInlineError(message: SessionStrings.text(SessionStrings.error(error)),
                                         retryLabel: SessionStrings.text(.retry),
                                         disabled: model.isIssuing || model.isRedeeming) {
                        Task { await model.retry() }
                    }
                    .multilineTextAlignment(.leading)
                }
            }
        }
        .navigationTitle(SessionStrings.text(.qrExchange))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                EncounterBackButton(label: SessionStrings.text(.back), action: navigation.close)
            }
        }
        .background {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Color.clear.onChange(of: context.date) {
                    if scenePhase == .active { Task { await model.tick() } }
                }
            }
        }
        .task {
            model.receiveCameraPermission(QRCameraAccess.current)
            await model.appear()
        }
        .onDisappear { model.disappear() }
        .onChange(of: scenePhase) { _, phase in
            model.receiveCameraPermission(QRCameraAccess.current)
            if phase == .active { Task { await model.tick() } }
        }
    }

    private var modePicker: some View {
        EncounterSegmentedControl(segments: [
            .init(QRSegment.show, label: SessionStrings.text(.showCode)),
            .init(QRSegment.scan, label: SessionStrings.text(.scanCode), symbol: "camera")
        ], selection: Binding(get: { model.segment }, set: { value in
            guard value != model.segment else { return }
            model.select(value)
            Task { await model.tick() }
        }), label: SessionStrings.text(.codeMode))
    }

    @ViewBuilder private var showCode: some View {
        if model.isIssuing { EncounterProgress(SessionStrings.text(.loading)) }
        if let code = model.code, model.isCodeValid {
            QRImageView(payload: code.payload)
            Text(SessionStrings.remaining(model.remainingSeconds)).font(.headline).monospacedDigit()
                .foregroundStyle(EncounterPalette.accent)
        }
        Text(SessionStrings.text(.validity)).font(.callout).foregroundStyle(EncounterPalette.inkSecondary)
        Button { Task { await model.refreshCode() } } label: {
            Label { Text(SessionStrings.text(.refreshCode)) } icon: {
                Image(systemName: "arrow.clockwise").accessibilityHidden(true)
            }
        }.buttonStyle(EncounterButtonStyle(.secondary))
            .disabled(model.isIssuing || model.isRedeeming || model.hasConfirmed)
        Text(SessionStrings.text(.invalidatesPrevious)).font(.footnote).foregroundStyle(EncounterPalette.inkSecondary)
    }

    @ViewBuilder private var scanCode: some View {
        if model.isRedeeming { EncounterProgress(SessionStrings.text(.confirming)) }
        switch model.cameraPermission {
        case .notDetermined:
            Button(SessionStrings.text(.allowCamera)) {
                requestingCamera = true
                Task {
                    model.receiveCameraPermission(await QRCameraAccess.request())
                    requestingCamera = false
                }
            }.buttonStyle(EncounterButtonStyle(.primary)).disabled(requestingCamera)
        case .denied:
            EncounterNotice(SessionStrings.text(.cameraDenied), kind: .warning)
                .multilineTextAlignment(.leading)
            Button(SessionStrings.text(.openSettings), action: navigation.openIOSSettings)
                .buttonStyle(EncounterButtonStyle(.secondary))
        case .restricted:
            EncounterNotice(SessionStrings.text(.cameraRestricted), kind: .warning)
                .multilineTextAlignment(.leading)
        case .authorized:
            if scenePhase == .active {
                QRScannerView(isScanning: !model.isRedeeming && model.error == nil && !model.hasConfirmed,
                              onScan: { text in Task { await model.scan(text) } },
                              onFailure: { model.cameraFailed() })
                    .frame(height: min(cameraHeight, 320))
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(EncounterPalette.border, lineWidth: 1))
                    .accessibilityLabel(SessionStrings.text(.cameraPreview))
            }
        }
    }
}

@MainActor
struct QRImageView: View {
    let payload: QRPayload
    // Resolve the shared border explicitly so it stays subtle around the white quiet zone.
    private let tileBorder = Color(uiColor: EncounterPalette.borderUIColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)))

    var body: some View {
        if let image = image {
            Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                .padding(24)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(tileBorder, lineWidth: 1))
                .frame(maxWidth: 320)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(SessionStrings.text(.qrImage))
                .accessibilityIgnoresInvertColors()
        } else { Text(SessionStrings.text(.unreadable)).foregroundStyle(EncounterPalette.destructive) }
    }

    private var image: UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let result = CIContext().createCGImage(output.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
                                                     from: output.extent.applying(CGAffineTransform(scaleX: 8, y: 8))) else { return nil }
        return UIImage(cgImage: result)
    }
}
