import AVFoundation
import Foundation

/// Takes one still photo from the default camera after a failed unlock. The caller decides whether
/// to keep it; nothing is written to disk here.
final class IntruderCamera: NSObject {
    private var session: AVCaptureSession?
    private var output: AVCapturePhotoOutput?
    private var completion: ((Data?) -> Void)?
    private var timeout: DispatchWorkItem?
    private let lock = NSLock()

    func capture(completion: @escaping (Data?) -> Void) {
        guard AVCaptureDevice.default(for: .video) != nil else {
            completion(nil)
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            start(completion)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { self.start(completion) } else { completion(nil) }
                }
            }
        default:
            completion(nil)
        }
    }

    private func start(_ completion: @escaping (Data?) -> Void) {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            completion(nil)
            return
        }
        let session = AVCaptureSession()
        session.sessionPreset = .low
        guard session.canAddInput(input) else { completion(nil); return }
        session.addInput(input)
        let output = AVCapturePhotoOutput()
        guard session.canAddOutput(output) else { completion(nil); return }
        session.addOutput(output)

        self.session = session
        self.output = output
        self.completion = completion

        session.startRunning()
        output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)

        let timeout = DispatchWorkItem { [weak self] in self?.finish(nil) }
        self.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: timeout)
    }

    private func finish(_ data: Data?) {
        lock.lock()
        let work = timeout
        let callback = completion
        let runningSession = session
        timeout = nil
        completion = nil
        session = nil
        output = nil
        lock.unlock()

        work?.cancel()
        runningSession?.stopRunning()
        DispatchQueue.main.async { callback?(data) }
    }
}

extension IntruderCamera: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        guard error == nil else {
            finish(nil)
            return
        }
        finish(photo.fileDataRepresentation())
    }
}
