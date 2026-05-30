//
//  QRScannerView.swift
//  Columba-iOS
//
//  AVFoundation-based QR code scanner for scanning lxma:// contact URIs.
//  Wraps AVCaptureSession in a UIViewControllerRepresentable for SwiftUI.
//

#if os(iOS)
import SwiftUI
import RNSAPI
import AVFoundation

/// Callback with parsed destination hash and public key from scanned QR code.
typealias QRScanCallback = (_ destinationHash: Data, _ publicKey: Data) -> Void

/// AVFoundation-based QR scanner with camera preview and scan overlay.
@available(iOS 17.0, *)
struct QRScannerView: UIViewControllerRepresentable {
    let onScanned: QRScanCallback
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let vc = QRScannerViewController()
        vc.onScanned = onScanned
        vc.onCancel = onCancel
        return vc
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}
}

/// View controller managing AVCaptureSession for QR code scanning.
final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScanned: QRScanCallback?
    var onCancel: (() -> Void)?

    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var lastScanTime: Date = .distantPast

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        checkCameraPermission()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopSession()
    }

    // MARK: - Camera Permission

    private func checkCameraPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupCaptureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.setupCaptureSession()
                    } else {
                        self?.showPermissionDenied()
                    }
                }
            }
        default:
            showPermissionDenied()
        }
    }

    private func showPermissionDenied() {
        let label = UILabel()
        label.text = "Camera access is required to scan QR codes.\nEnable it in Settings > Columba."
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 0
        label.font = .systemFont(ofSize: 16)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
        ])

        addCancelButton()
    }

    // MARK: - Capture Session

    private func setupCaptureSession() {
        let session = AVCaptureSession()

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            return
        }

        if session.canAddInput(input) {
            session.addInput(input)
        }

        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
        }

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        self.previewLayer = preview

        addOverlay()
        addCancelButton()

        self.captureSession = session
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    private func stopSession() {
        captureSession?.stopRunning()
    }

    // MARK: - Overlay

    private func addOverlay() {
        let overlayView = QRScannerOverlayView()
        overlayView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlayView)

        NSLayoutConstraint.activate([
            overlayView.topAnchor.constraint(equalTo: view.topAnchor),
            overlayView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            overlayView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlayView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        let titleLabel = UILabel()
        titleLabel.text = "Scan Contact QR Code"
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
        ])
    }

    private func addCancelButton() {
        let button = UIButton(type: .system)
        button.setTitle("Cancel", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = UIColor.white.withAlphaComponent(0.2)
        button.layer.cornerRadius = 12
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        view.addSubview(button)

        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            button.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            button.widthAnchor.constraint(equalToConstant: 200),
            button.heightAnchor.constraint(equalToConstant: 48),
        ])
    }

    @objc private func cancelTapped() {
        onCancel?()
    }

    // MARK: - AVCaptureMetadataOutputObjectsDelegate

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        // 2-second cooldown between scans
        guard Date().timeIntervalSince(lastScanTime) > 2.0 else { return }

        guard let readableObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let stringValue = readableObject.stringValue else {
            return
        }

        if let parsed = ContactsViewModel.parseLXMA(stringValue) {
            lastScanTime = Date()
            stopSession()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onScanned?(parsed.destinationHash, parsed.publicKey)
        }
    }
}

// MARK: - Scanner Overlay

/// Semi-transparent overlay with centered cutout square for QR scanning.
private final class QRScannerOverlayView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        let cutoutSize: CGFloat = min(rect.width, rect.height) * 0.65
        let cutoutRect = CGRect(
            x: (rect.width - cutoutSize) / 2,
            y: (rect.height - cutoutSize) / 2,
            width: cutoutSize,
            height: cutoutSize
        )

        // Dim background
        ctx.setFillColor(UIColor.black.withAlphaComponent(0.5).cgColor)
        ctx.fill(rect)

        // Clear cutout
        ctx.clear(cutoutRect)

        // Corner brackets
        let bracketLength: CGFloat = 30
        let bracketWidth: CGFloat = 3
        let color = UIColor(red: 0.612, green: 0.153, blue: 0.690, alpha: 1.0) // Theme.accentColor

        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(bracketWidth)

        // Top-left
        ctx.move(to: CGPoint(x: cutoutRect.minX, y: cutoutRect.minY + bracketLength))
        ctx.addLine(to: CGPoint(x: cutoutRect.minX, y: cutoutRect.minY))
        ctx.addLine(to: CGPoint(x: cutoutRect.minX + bracketLength, y: cutoutRect.minY))
        ctx.strokePath()

        // Top-right
        ctx.move(to: CGPoint(x: cutoutRect.maxX - bracketLength, y: cutoutRect.minY))
        ctx.addLine(to: CGPoint(x: cutoutRect.maxX, y: cutoutRect.minY))
        ctx.addLine(to: CGPoint(x: cutoutRect.maxX, y: cutoutRect.minY + bracketLength))
        ctx.strokePath()

        // Bottom-left
        ctx.move(to: CGPoint(x: cutoutRect.minX, y: cutoutRect.maxY - bracketLength))
        ctx.addLine(to: CGPoint(x: cutoutRect.minX, y: cutoutRect.maxY))
        ctx.addLine(to: CGPoint(x: cutoutRect.minX + bracketLength, y: cutoutRect.maxY))
        ctx.strokePath()

        // Bottom-right
        ctx.move(to: CGPoint(x: cutoutRect.maxX - bracketLength, y: cutoutRect.maxY))
        ctx.addLine(to: CGPoint(x: cutoutRect.maxX, y: cutoutRect.maxY))
        ctx.addLine(to: CGPoint(x: cutoutRect.maxX, y: cutoutRect.maxY - bracketLength))
        ctx.strokePath()
    }
}
#endif
