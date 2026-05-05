//
//  CameraSession.swift
//  EPaperNFCDemo
//

@preconcurrency import AVFoundation
import CoreImage
import CoreMedia
import OSLog
import UIKit

private nonisolated let logger = Logger(
    subsystem: "EPaperNFCDemo",
    category: "CameraSession"
)

@MainActor
@Observable
final class CameraSession {
    enum State {
        case idle
        case denied
        case running
        case failed(any Error)
    }

    private(set) var state: State = .idle
    private(set) var latestImage: CIImage?
    private(set) var position: AVCaptureDevice.Position = .back
    private(set) var zoomFactor: CGFloat = 1.0
    private(set) var minZoomFactor: CGFloat = 1.0
    private(set) var maxZoomFactor: CGFloat = 1.0
    private(set) var lensSwitchFactors: [CGFloat] = []  // raw zoom factors at which the virtual camera switches physical lenses

    // AVFoundation objects are thread-safe by design but not Sendable. They
    // are touched from `queue` (background) for start/stop/configure and from
    // the main actor for property reads, so we mark them unsafe-nonisolated.
    nonisolated(unsafe) private let session = AVCaptureSession()
    nonisolated(unsafe) private let output = AVCaptureVideoDataOutput()
    nonisolated(unsafe) private let photoOutput = AVCapturePhotoOutput()
    private var device: AVCaptureDevice?
    private var input: AVCaptureDeviceInput?

    private let queue = DispatchQueue(label: "EPaperNFCDemo.CameraSession", qos: .userInitiated)
    private var delegate: SampleBufferDelegate?
    private var activePhotoDelegate: PhotoCaptureDelegate?

    func start() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else { state = .denied; return }
        case .denied, .restricted:
            state = .denied
            return
        @unknown default:
            state = .denied
            return
        }

        do {
            try configureIfNeeded()
            await startSessionOffMain()
            state = .running
        } catch {
            logger.error(error)
            state = .failed(error)
        }
    }

    func stop() {
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func switchCamera() {
        let newPosition: AVCaptureDevice.Position = (position == .back) ? .front : .back
        guard let newDevice = Self.preferredDevice(for: newPosition) else { return }
        do {
            let newInput = try AVCaptureDeviceInput(device: newDevice)
            session.beginConfiguration()
            if let input { session.removeInput(input) }
            guard session.canAddInput(newInput) else {
                session.commitConfiguration()
                return
            }
            session.addInput(newInput)
            applyVideoRotation()
            applyMirroring(for: newPosition)
            session.commitConfiguration()
            self.input = newInput
            self.device = newDevice
            self.position = newPosition
            updateZoomCapabilities()
        } catch {
            logger.error(error)
        }
    }

    // Smooth zoom across virtual-camera lenses. AVFoundation handles the
    // physical-lens crossover internally based on the device's
    // virtualDeviceSwitchOverVideoZoomFactors.
    func setZoom(_ factor: CGFloat) {
        guard let device else { return }
        let clamped = max(minZoomFactor, min(maxZoomFactor, factor))
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.videoZoomFactor = clamped
            zoomFactor = clamped
        } catch {
            logger.error(error)
        }
    }

    private func updateZoomCapabilities() {
        guard let device else { return }
        minZoomFactor = device.minAvailableVideoZoomFactor
        maxZoomFactor = min(device.maxAvailableVideoZoomFactor, 8.0)  // cap digital zoom for usability
        lensSwitchFactors = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        zoomFactor = device.videoZoomFactor
    }

    // Prefer multi-lens virtual cameras so videoZoomFactor smoothly ramps
    // across the physical lenses. Falls back to single wide on devices
    // that lack the virtual cameras (e.g. iPhone SE).
    private static func preferredDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        if position == .back {
            if let triple = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back) {
                return triple
            }
            if let dualWide = AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back) {
                return dualWide
            }
            if let dual = AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back) {
                return dual
            }
        } else if position == .front {
            // TrueDepth front camera ships on iPhone X+ and offers a wider
            // field of view than the regular front wide-angle, matching
            // iOS Camera's "wide selfie" framing.
            if let trueDepth = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front) {
                return trueDepth
            }
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }

    func setVideoRotationAngle(_ angle: CGFloat) {
        guard let connection = output.connection(with: .video),
              connection.isVideoRotationAngleSupported(angle)
        else { return }
        connection.videoRotationAngle = angle
    }

    func focus(atNormalized point: CGPoint) {
        guard let device else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = point
                if device.isFocusModeSupported(.autoFocus) {
                    device.focusMode = .autoFocus
                }
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = point
                if device.isExposureModeSupported(.autoExpose) {
                    device.exposureMode = .autoExpose
                }
            }
        } catch {
            logger.error(error)
        }
    }

    private func startSessionOffMain() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [session] in
                if !session.isRunning { session.startRunning() }
                continuation.resume()
            }
        }
    }

    private func configureIfNeeded() throws {
        guard session.inputs.isEmpty else { return }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // .photo preset feeds 12MP (4032×3024) frames into the video data
        // output, which OOMs the live dither pipeline (~50MB per frame
        // allocation). Use 1080p for the preview stream. AVCapturePhotoOutput
        // still captures stills at the device's full sensor resolution
        // independently.
        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        } else {
            session.sessionPreset = .high
        }

        guard let device = Self.preferredDevice(for: .back) else {
            throw NSError(domain: "EPaperNFCDemo.CameraSession", code: 1, userInfo: [NSLocalizedDescriptionKey: "Back camera unavailable"])
        }
        self.device = device

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw NSError(domain: "EPaperNFCDemo.CameraSession", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot add camera input"])
        }
        session.addInput(input)
        self.input = input

        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        let delegate = SampleBufferDelegate { [weak self] image in
            Task { @MainActor [weak self] in
                self?.latestImage = image
            }
        }
        self.delegate = delegate
        output.setSampleBufferDelegate(delegate, queue: queue)

        guard session.canAddOutput(output) else {
            throw NSError(domain: "EPaperNFCDemo.CameraSession", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cannot add video output"])
        }
        session.addOutput(output)

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }
        // Required in iOS 17+ for the photo output to deliver full-resolution
        // stills. Without this, photos come back at the format's default
        // (small) dimensions.
        if let maxDim = device.activeFormat.supportedMaxPhotoDimensions.last {
            photoOutput.maxPhotoDimensions = maxDim
        }

        applyVideoRotation()
        applyMirroring(for: .back)
        updateZoomCapabilities()
    }

    // Captures a still photo through AVCapturePhotoOutput. Returns JPEG/HEIF
    // data with EXIF orientation baked in.
    func capturePhoto() async -> Data? {
        guard photoOutput.connection(with: .video) != nil else {
            logger.error("photoOutput has no video connection")
            return nil
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            let settings = AVCapturePhotoSettings()
            // Match the output's max dimensions so the request isn't rejected.
            settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
            let delegate = PhotoCaptureDelegate { [weak self] data in
                continuation.resume(returning: data)
                Task { @MainActor [weak self] in
                    self?.activePhotoDelegate = nil
                }
            }
            self.activePhotoDelegate = delegate
            photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }

    private func applyVideoRotation() {
        let portrait: CGFloat = 90
        if let connection = output.connection(with: .video),
           connection.isVideoRotationAngleSupported(portrait) {
            connection.videoRotationAngle = portrait
        }
        if let connection = photoOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(portrait) {
            connection.videoRotationAngle = portrait
        }
    }

    private func applyMirroring(for position: AVCaptureDevice.Position) {
        for connection in [output.connection(with: .video), photoOutput.connection(with: .video)] {
            guard let connection, connection.isVideoMirroringSupported else { continue }
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = (position == .front)
        }
    }
}

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let completion: @Sendable (Data?) -> Void

    init(completion: @escaping @Sendable (Data?) -> Void) {
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            logger.error(error)
            completion(nil)
            return
        }
        completion(photo.fileDataRepresentation())
    }
}

private final class SampleBufferDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let onImage: @Sendable (CIImage) -> Void

    init(onImage: @escaping @Sendable (CIImage) -> Void) {
        self.onImage = onImage
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        onImage(image)
    }
}
