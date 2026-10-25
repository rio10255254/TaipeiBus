import SwiftUI
import AVFoundation
import VisionKit
import TransitCore

struct BoardingPlateScanner: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var model: TransitAppModel
    let ride: TransitRide
    let choose: (BusVehicle) -> Void
    @State private var authorized = false
    @State private var text: [String] = []
    @State private var message: String?

    private func matches(at date: Date) -> [BusVehicle] {
        let vehicles = model.snapshot.vehicles.filter {
            $0.hasReliablePosition(at: date) && ["0", "3"].contains($0.status) && model.metadata.canServe(ride, vehicle: $0)
        }
        let point = model.location.usableCoordinate ?? ride.boarding.coordinate
        let candidates = vehicles.map { PlateCandidate(id: $0.id, plate: $0.plate, observedAt: $0.observedAt,
            distance: $0.rawCoordinate.distance(to: point)) }
        let ids = Set(PlateRecognition.matches(text: text, candidates: candidates, at: date).map(\.id))
        return vehicles.filter { ids.contains($0.id) }.sorted { $0.plate < $1.plate }
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if authorized, message == nil {
                    PlateCamera(active: scenePhase == .active, recognized: { text = $0 }, failed: {
                        message = AppText.text("相機目前無法使用，請手動選擇車牌。")
                    }).frame(maxHeight: 280).clipShape(MapChrome.shape(.row))
                        .accessibilityLabel(AppText.text("將車牌放入相機畫面"))
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        let candidates = matches(at: timeline.date)
                        List {
                            Section {
                                if candidates.isEmpty {
                                    Text(AppText.text("尚未找到符合的近期車輛，請對準完整車牌，或返回手動選車。"))
                                        .foregroundStyle(.secondary).accessibilityIdentifier("plate-no-match")
                                }
                                ForEach(candidates) { bus in
                                    Button {
                                        guard let current = matches(at: Date()).first(where: { $0.id == bus.id }) else {
                                            message = AppText.text("車輛資料已更新，請返回重新確認車牌。"); return
                                        }
                                        choose(current); dismiss()
                                    } label: {
                                        Label(AppText.text("確認使用車牌 %@", bus.plate), systemImage: "bus.fill")
                                    }.accessibilityIdentifier("plate-confirm-" + bus.plate)
                                }
                            } footer: {
                                Text(AppText.text("只比對此路線、同方向、附近 300 公尺內的近期車輛。請核對車身或車內車牌後再確認。"))
                            }
                        }.listStyle(.insetGrouped)
                    }
                } else {
                    ContentUnavailableView {
                        Label(AppText.text("手動選擇車牌"), systemImage: "camera")
                    } description: {
                        Text(message ?? AppText.text("正在確認相機權限"))
                    } actions: {
                        Button(AppText.text("返回選車")) { dismiss() }.accessibilityIdentifier("plate-manual-fallback")
                        if AVCaptureDevice.authorizationStatus(for: .video) == .denied {
                            Button(AppText.text("開啟系統設定")) {
                                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            }
                        }
                    }
                }
                Text(AppText.text("影像只在手機上辨識，不儲存照片或上傳車牌影像。"))
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
            }.padding(.top)
                .navigationTitle(AppText.text("掃描車牌")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(AppText.text("取消")) { dismiss() } } }
        }.presentationDetents([.large]).task {
            guard DataScannerViewController.isSupported else {
                message = AppText.text("此裝置不支援即時文字辨識，請手動選擇車牌。"); return
            }
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            var allowed = status == .authorized
            if status == .notDetermined { allowed = await AVCaptureDevice.requestAccess(for: .video) }
            guard !Task.isCancelled else { return }
            guard allowed, DataScannerViewController.isAvailable else {
                message = AppText.text("相機目前無法使用，請手動選擇車牌。"); return
            }
            authorized = true
        }
    }
}

private struct PlateCamera: UIViewControllerRepresentable {
    let active: Bool
    let recognized: ([String]) -> Void
    let failed: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(recognized: recognized, failed: failed) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(recognizedDataTypes: [.text(languages: ["en-US"])],
            qualityLevel: .accurate, recognizesMultipleItems: true, isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true)
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        if active && !controller.isScanning {
            do { try controller.startScanning() }
            catch { DispatchQueue.main.async { failed() } }
        } else if !active { controller.stopScanning() }
    }
    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) { controller.stopScanning() }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let recognized: ([String]) -> Void
        let failed: () -> Void
        init(recognized: @escaping ([String]) -> Void, failed: @escaping () -> Void) { self.recognized = recognized; self.failed = failed }
        private func update(_ items: [RecognizedItem]) {
            recognized(items.compactMap { if case .text(let value) = $0 { return value.transcript }; return nil })
        }
        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) { update(allItems) }
        func dataScanner(_ scanner: DataScannerViewController, didUpdate items: [RecognizedItem], allItems: [RecognizedItem]) { update(allItems) }
        func dataScanner(_ scanner: DataScannerViewController, didRemove items: [RecognizedItem], allItems: [RecognizedItem]) { update(allItems) }
        func dataScanner(_ scanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) { failed() }
    }
}
