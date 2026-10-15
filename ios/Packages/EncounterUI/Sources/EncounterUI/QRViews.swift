import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

@MainActor
public struct QRView: View {
    @ObservedObject private var model: QRModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let navigation: QRNavigationActions
    @SessionViewState private var requestingCamera = false

    public init(model: QRModel, navigation: QRNavigationActions) {
        self.model = model; self.navigation = navigation
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if dynamicTypeSize.isAccessibilitySize { modePicker.pickerStyle(.inline) }
                else { modePicker.pickerStyle(.segmented) }
                SessionCard {
                    if model.segment == .show { showCode } else { scanCode }
                }
                if let error = model.error {
                    SessionCard {
                        Text(SessionStrings.text(SessionStrings.error(error)))
                        Button(SessionStrings.text(.retry)) { Task { await model.retry() } }
                            .disabled(model.isIssuing || model.isRedeeming)
                    }
                }
                Text(SessionStrings.text(.confirmed)).foregroundStyle(.secondary)
            }.padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(SessionStrings.text(.qrExchange))
        .navigationBarTitleDisplayMode(.large)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button(SessionStrings.text(.back), action: navigation.close) }
        }
        .tint(.teal)
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
        Picker(SessionStrings.text(.codeMode), selection: Binding(get: { model.segment }, set: { value in
            model.select(value)
            Task { await model.tick() }
        })) {
            Text(SessionStrings.text(.showCode)).tag(QRSegment.show)
            Text(SessionStrings.text(.scanCode)).tag(QRSegment.scan)
        }
    }

    @ViewBuilder private var showCode: some View {
        if model.isIssuing { ProgressView(SessionStrings.text(.loading)) }
        if let code = model.code, model.isCodeValid {
            QRImageView(payload: code.payload)
            Text(SessionStrings.remaining(model.remainingSeconds)).monospacedDigit()
        }
        Text(SessionStrings.text(.validity))
        Button(SessionStrings.text(.refreshCode)) { Task { await model.refreshCode() } }
            .disabled(model.isIssuing || model.isRedeeming || model.hasConfirmed)
        Text(SessionStrings.text(.invalidatesPrevious)).font(.footnote).foregroundStyle(.secondary)
    }

    @ViewBuilder private var scanCode: some View {
        if model.isRedeeming { ProgressView(SessionStrings.text(.confirming)) }
        switch model.cameraPermission {
        case .notDetermined:
            Button(SessionStrings.text(.allowCamera)) {
                requestingCamera = true
                Task {
                    model.receiveCameraPermission(await QRCameraAccess.request())
                    requestingCamera = false
                }
            }.disabled(requestingCamera)
        case .denied:
            Text(SessionStrings.text(.cameraDenied))
            Button(SessionStrings.text(.openSettings), action: navigation.openIOSSettings)
        case .restricted:
            Text(SessionStrings.text(.cameraRestricted))
        case .authorized:
            if scenePhase == .active {
                QRScannerView(isScanning: !model.isRedeeming && model.error == nil && !model.hasConfirmed,
                              onScan: { text in Task { await model.scan(text) } },
                              onFailure: { model.cameraFailed() })
                    .frame(height: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel(SessionStrings.text(.cameraPreview))
            }
        }
    }
}

@MainActor
struct QRImageView: View {
    let payload: QRPayload
    var body: some View {
        if let image = image {
            Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                .padding(24).background(.white)
                .frame(maxWidth: 320)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(SessionStrings.text(.qrImage))
        } else { Text(SessionStrings.text(.unreadable)) }
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
