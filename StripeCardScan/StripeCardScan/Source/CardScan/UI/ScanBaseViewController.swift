import AVKit
import UIKit
import Vision

public protocol TestingImageDataSource: AnyObject {
    func nextSquareAndFullImage() -> CGImage?
}

open class ScanBaseViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate,
    AfterPermissions, OcrMainLoopDelegate
{

    public lazy var testingImageDataSource: TestingImageDataSource? = {
        var result: TestingImageDataSource?
        #if targetEnvironment(simulator)
            if ProcessInfo.processInfo.environment["UITesting"] != nil {
                result = EndToEndTestingImageDataSource()
            }
        #endif  // targetEnvironment(simulator)
        return result
    }()

    public var includeCardImage = false
    public var showDebugImageView = false

    public var scanEventsDelegate: ScanEvents?

    public static var isAppearing = false
    public static var isPadAndFormsheet: Bool = false
    public static let machineLearningQueue = DispatchQueue(label: "CardScanMlQueue")
    private let machineLearningSemaphore = DispatchSemaphore(value: 1)

    private weak var debugImageView: UIImageView?
    private weak var previewView: PreviewView?
    private weak var regionOfInterestLabel: UIView?
    private weak var blurView: BlurView?
    private weak var cornerView: CornerView?
    private var regionOfInterestLabelFrame: CGRect?
    private var previewViewFrame: CGRect?

    var videoFeed = VideoFeed()
    open var initialVideoOrientation: AVCaptureVideoOrientation {
        if ScanBaseViewController.isPadAndFormsheet {
            return AVCaptureVideoOrientation(interfaceOrientation: UIWindow.interfaceOrientation)
                ?? .portrait
        } else {
            return .portrait
        }
    }

    public private(set) var scannedCardImage: UIImage?
    private var isNavigationBarHidden: Bool?
    public var hideNavigationBar: Bool?
    public var regionOfInterestCornerRadius = CGFloat(10.0)
    private var calledOnScannedCard = false

    /// Flag to keep track of first time pan is observed
    private var firstPanObserved: Bool = false
    /// Flag to keep track of first time frame is processed
    private var firstImageProcessed: Bool = false

    var mainLoop: MachineLearningLoop?
    private func ocrMainLoop() -> OcrMainLoop? {
        mainLoop.flatMap { $0 as? OcrMainLoop }
    }
    // this is a hack to avoid changing our  interface
    var predictedName: String?

    // Child classes should override these functions
    public func onScannedCard(
        number: String,
        expiryYear: String?,
        expiryMonth: String?,
        scannedImage: UIImage?
    ) {}
    open func showCardNumber(_ number: String, expiry: String?) {}
    open func showWrongCard(number: String?, expiry: String?, name: String?) {}
    open func showNoCard() {}
    open func onCameraPermissionDenied(showedPrompt: Bool) {}
    open func useCurrentFrameNumber(errorCorrectedNumber: String?, currentFrameNumber: String) -> Bool {
        return true
    }

    // MARK: Inits
    public init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required public init?(
        coder: NSCoder
    ) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Torch Logic
    open func toggleTorch() {
        self.ocrMainLoop()?.scanStats.torchOn = !(self.ocrMainLoop()?.scanStats.torchOn ?? false)
        self.videoFeed.toggleTorch()
    }

    open func isTorchOn() -> Bool {
        return self.videoFeed.isTorchOn()
    }

    open func hasTorchAndIsAvailable() -> Bool {
        return self.videoFeed.hasTorchAndIsAvailable()
    }

    open func setTorchLevel(level: Float) {
        if 0.0...1.0 ~= level {
            self.videoFeed.setTorchLevel(level: level)
        }
    }

    public static func configure(apiKey: String? = nil) {
        // TODO: remove this and just use stripe's main configuration path
    }

    public static func supportedOrientationMaskOrDefault() -> UIInterfaceOrientationMask {
        guard ScanBaseViewController.isAppearing else {
            // If the ScanBaseViewController isn't appearing then fall back
            // to getting the orientation mask from the infoDictionary, just like
            // the system would do if the user didn't override the
            // supportedInterfaceOrientationsFor method
            let supportedOrientations =
                (Bundle.main.infoDictionary?["UISupportedInterfaceOrientations"] as? [String]) ?? [
                    "UIInterfaceOrientationPortrait"
                ]

            let maskArray = supportedOrientations.map { option -> UIInterfaceOrientationMask in
                switch option {
                case "UIInterfaceOrientationPortrait":
                    return UIInterfaceOrientationMask.portrait
                case "UIInterfaceOrientationPortraitUpsideDown":
                    return UIInterfaceOrientationMask.portraitUpsideDown
                case "UIInterfaceOrientationLandscapeLeft":
                    return UIInterfaceOrientationMask.landscapeLeft
                case "UIInterfaceOrientationLandscapeRight":
                    return UIInterfaceOrientationMask.landscapeRight
                default:
                    return UIInterfaceOrientationMask.portrait
                }
            }

            let mask: UIInterfaceOrientationMask = maskArray.reduce(
                UIInterfaceOrientationMask.portrait
            ) { result, element in
                return UIInterfaceOrientationMask(rawValue: result.rawValue | element.rawValue)
            }

            return mask
        }
        return ScanBaseViewController.isPadAndFormsheet ? .allButUpsideDown : .portrait
    }

    public static func isCompatible() -> Bool {
        return self.isCompatible(configuration: ScanConfiguration())
    }

    public static func isCompatible(configuration: ScanConfiguration) -> Bool {
        // check to see if the user has already denined camera permission
        let authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        if authorizationStatus != .authorized && authorizationStatus != .notDetermined
            && configuration.setPreviouslyDeniedDevicesAsIncompatible
        {
            return false
        }

        // make sure that we don't run on iPhone 6 / 6plus or older
        if configuration.runOnOldDevices {
            return true
        }

        return true
    }

    open func cancelScan() {
        guard let ocrMainLoop = ocrMainLoop() else {
            return
        }
        ocrMainLoop.userCancelled()
    }

    open func setupMask() {
        guard let roi = self.regionOfInterestLabel else { return }
        guard let blurView = self.blurView else { return }
        blurView.maskToRoi(roi: roi)
    }

    open func setUpCorners() {
        guard let roi = self.regionOfInterestLabel else { return }
        guard let corners = self.cornerView else { return }
        corners.setFrameSize(roi: roi)
        corners.drawCorners()
    }

    open func permissionDidComplete(granted: Bool, showedPrompt: Bool) {
        self.ocrMainLoop()?.scanStats.permissionGranted = granted
        if !granted {
            self.onCameraPermissionDenied(showedPrompt: showedPrompt)
        }
        ScanAnalyticsManager.shared.logCameraPermissionsTask(success: granted)
    }

    // you must call setupOnViewDidLoad before calling this function and you have to call
    // this function to get the camera going
    open func startCameraPreview() {
        self.videoFeed.requestCameraAccess(permissionDelegate: self)
    }

    internal func invokeFakeLoop() {
        guard let dataSource = testingImageDataSource else {
            return
        }

        guard let fullTestingImage = dataSource.nextSquareAndFullImage() else {
            return
        }

        guard let roiFrame = self.regionOfInterestLabelFrame,
            let previewViewFrame = self.previewViewFrame,
            let roiRectInPixels = ScannedCardImageData.convertToPreviewLayerRect(
                captureDeviceImage: fullTestingImage,
                viewfinderRect: roiFrame,
                previewViewRect: previewViewFrame
            )
        else {
            return
        }

        mainLoop?.push(
            imageData: ScannedCardImageData(
                previewLayerImage: fullTestingImage,
                previewLayerViewfinderRect: roiRectInPixels
            )
        )
    }

    internal func startFakeCameraLoop() {
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.invokeFakeLoop()
        }
        RunLoop.main.add(timer, forMode: .default)
    }

    func isSimulator() -> Bool {
        #if targetEnvironment(simulator)
            return true
        #else
            return false
        #endif
    }

    open func setupOnViewDidLoad(
        regionOfInterestLabel: UIView,
        blurView: BlurView,
        previewView: PreviewView,
        cornerView: CornerView?,
        debugImageView: UIImageView?,
        torchLevel: Float?
    ) {

        self.regionOfInterestLabel = regionOfInterestLabel
        self.blurView = blurView
        self.previewView = previewView
        self.debugImageView = debugImageView
        self.debugImageView?.contentMode = .scaleAspectFit
        self.cornerView = cornerView
        ScanBaseViewController.isPadAndFormsheet =
            UIDevice.current.userInterfaceIdiom == .pad && self.modalPresentationStyle == .formSheet

        setNeedsStatusBarAppearanceUpdate()
        regionOfInterestLabel.layer.masksToBounds = true
        regionOfInterestLabel.layer.cornerRadius = self.regionOfInterestCornerRadius
        regionOfInterestLabel.layer.borderColor = UIColor.white.cgColor
        regionOfInterestLabel.layer.borderWidth = 2.0

        if !ScanBaseViewController.isPadAndFormsheet {
            UIDevice.current.setValue(UIDeviceOrientation.portrait.rawValue, forKey: "orientation")
        }

        mainLoop = createOcrMainLoop()

        if testingImageDataSource != nil {
            self.ocrMainLoop()?.imageQueueSize = 20
        }

        self.ocrMainLoop()?.mainLoopDelegate = self
        self.previewView?.videoPreviewLayer.session = self.videoFeed.session

        self.videoFeed.pauseSession()
        // Apple example app sets up in viewDidLoad: https://developer.apple.com/documentation/avfoundation/cameras_and_media_capture/avcam_building_a_camera_app
        self.videoFeed.setup(
            captureDelegate: self,
            initialVideoOrientation: self.initialVideoOrientation,
            completion: { success in
                if self.previewView?.videoPreviewLayer.connection?.isVideoOrientationSupported
                    ?? false
                {
                    self.previewView?.videoPreviewLayer.connection?.videoOrientation =
                        self.initialVideoOrientation
                }
                if let level = torchLevel {
                    self.setTorchLevel(level: level)
                }

                if !success && self.testingImageDataSource != nil && self.isSimulator() {
                    self.startFakeCameraLoop()
                }
            }
        )
    }

    func createOcrMainLoop() -> OcrMainLoop? {
        OcrMainLoop()
    }

    open override var shouldAutorotate: Bool {
        return true
    }

    open override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return ScanBaseViewController.isPadAndFormsheet ? .allButUpsideDown : .portrait
    }

    open override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        return ScanBaseViewController.isPadAndFormsheet ? UIWindow.interfaceOrientation : .portrait
    }

    open override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }

    open override func viewWillTransition(
        to size: CGSize,
        with coordinator: UIViewControllerTransitionCoordinator
    ) {
        super.viewWillTransition(to: size, with: coordinator)

        if let videoFeedConnection = self.videoFeed.videoDeviceConnection,
            videoFeedConnection.isVideoOrientationSupported
        {
            videoFeedConnection.videoOrientation =
                AVCaptureVideoOrientation(deviceOrientation: UIDevice.current.orientation)
                ?? .portrait
        }
        if let previewViewConnection = self.previewView?.videoPreviewLayer.connection,
            previewViewConnection.isVideoOrientationSupported
        {
            previewViewConnection.videoOrientation =
                AVCaptureVideoOrientation(deviceOrientation: UIDevice.current.orientation)
                ?? .portrait
        }
    }

    open override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        ScanBaseViewController.isAppearing = true
        // Set beginning of scan session
        ScanAnalyticsManager.shared.setScanSessionStartTime(time: Date())
        // Check and log torch availability
        ScanAnalyticsManager.shared.logTorchSupportTask(
            supported: videoFeed.hasTorchAndIsAvailable()
        )
        self.ocrMainLoop()?.reset()
        self.calledOnScannedCard = false
        self.videoFeed.willAppear()
        self.isNavigationBarHidden = self.navigationController?.isNavigationBarHidden ?? true
        let hideNavigationBar = self.hideNavigationBar ?? true
        self.navigationController?.setNavigationBarHidden(hideNavigationBar, animated: animated)
    }

    open override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        self.view.layoutIfNeeded()
        guard let roiFrame = self.regionOfInterestLabel?.frame,
            let previewViewFrame = self.previewView?.frame
        else { return }
        // store .frame to avoid accessing UI APIs in the machineLearningQueue
        self.regionOfInterestLabelFrame = roiFrame
        self.previewViewFrame = previewViewFrame
        self.setUpCorners()
        self.setupMask()
    }

    open override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.ocrMainLoop()?.scanStats.orientation = UIWindow.interfaceOrientationToString
    }

    open override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        self.videoFeed.willDisappear()
        self.navigationController?.setNavigationBarHidden(
            self.isNavigationBarHidden ?? false,
            animated: animated
        )
    }

    open override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        ScanBaseViewController.isAppearing = false
    }

    public func getScanStats() -> ScanStats {
        return self.ocrMainLoop()?.scanStats ?? ScanStats()
    }

    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if self.machineLearningSemaphore.wait(timeout: .now()) == .success {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
                  let fullCameraImage = pixelBuffer.cgImage() else {
                self.machineLearningSemaphore.signal()
                return
            }

            ScanBaseViewController.machineLearningQueue.async { [weak self] in
                self?.captureOutputWork(fullCameraImage: fullCameraImage)
                self?.machineLearningSemaphore.signal()
            }
        }
    }

    func captureOutputWork(fullCameraImage: CGImage) {
        // confirm videoGravity settings in previewView. Calculations based on .resizeAspectFill
        DispatchQueue.main.async {
            assert(self.previewView?.videoPreviewLayer.videoGravity == .resizeAspectFill)
        }

        guard let roiFrame = self.regionOfInterestLabelFrame,
            let previewViewFrame = self.previewViewFrame,
            let scannedImageData = ScannedCardImageData(
                captureDeviceImage: fullCameraImage,
                viewfinderRect: roiFrame,
                previewViewRect: previewViewFrame
            )
        else {
            return
        }

        // we allow apps that integrate to supply their own sequence of images
        // for use in testing
        if let dataSource = testingImageDataSource {
            guard let fullTestingImage = dataSource.nextSquareAndFullImage() else {
                return
            }
            mainLoop?.push(
                imageData: ScannedCardImageData(
                    previewLayerImage: fullTestingImage,
                    previewLayerViewfinderRect: roiFrame
                )
            )
        } else {
            mainLoop?.push(imageData: scannedImageData)
        }
    }

    open func updateDebugImageView(image: UIImage) {
        self.debugImageView?.image = image
        if self.debugImageView?.isHidden ?? false {
            self.debugImageView?.isHidden = false
        }
    }

    // MARK: - OcrMainLoopComplete logic
    open func complete(creditCardOcrResult: CreditCardOcrResult) {
        ocrMainLoop()?.mainLoopDelegate = nil
        // Stop the previewing when we are done
        self.previewView?.videoPreviewLayer.session?.stopRunning()
        // Log total frames processed
        ScanAnalyticsManager.shared.logMainLoopImageProcessedRepeatingTask(
            .init(executions: self.getScanStats().scans)
        )
        ScanAnalyticsManager.shared.logScanActivityTaskFromStartTime(event: .cardScanned)

        ScanBaseViewController.machineLearningQueue.async {
            self.scanEventsDelegate?.onScanComplete(scanStats: self.getScanStats())
        }

        // hack to work around having to change our  interface
        predictedName = creditCardOcrResult.name
        self.onScannedCard(
            number: creditCardOcrResult.number,
            expiryYear: creditCardOcrResult.expiryYear,
            expiryMonth: creditCardOcrResult.expiryMonth,
            scannedImage: scannedCardImage
        )
    }

    open func prediction(
        prediction: CreditCardOcrPrediction,
        imageData: ScannedCardImageData,
        state: MainLoopState
    ) {
        if !firstImageProcessed {
            ScanAnalyticsManager.shared.logScanActivityTaskFromStartTime(
                event: .firstImageProcessed
            )
            firstImageProcessed = true
        }

        if self.showDebugImageView {
            let numberBoxes = prediction.numberBoxes?.map { (UIColor.blue, $0) } ?? []
            let expiryBoxes = prediction.expiryBoxes?.map { (UIColor.red, $0) } ?? []
            let nameBoxes = prediction.nameBoxes?.map { (UIColor.green, $0) } ?? []

            if self.debugImageView?.isHidden ?? false {
                self.debugImageView?.isHidden = false
            }

            self.debugImageView?.image = prediction.image.drawBoundingBoxesOnImage(
                boxes: numberBoxes + expiryBoxes + nameBoxes
            )
        }

        if prediction.number != nil && self.includeCardImage {
            self.scannedCardImage = UIImage(cgImage: prediction.image)
        }

        let isFlashForcedOn: Bool
        switch state {
        case .ocrForceFlash: isFlashForcedOn = true
        default: isFlashForcedOn = false
        }

        if let number = prediction.number {
            if !firstPanObserved {
                ScanAnalyticsManager.shared.logScanActivityTaskFromStartTime(event: .ocrPanObserved)
                firstPanObserved = true
            }

            let expiry = prediction.expiryObject()

            ScanBaseViewController.machineLearningQueue.async {
                self.scanEventsDelegate?.onNumberRecognized(
                    number: number,
                    expiry: expiry,
                    imageData: imageData,
                    centeredCardState: prediction.centeredCardState,
                    flashForcedOn: isFlashForcedOn
                )
            }
        } else {
            ScanBaseViewController.machineLearningQueue.async {
                self.scanEventsDelegate?.onFrameDetected(
                    imageData: imageData,
                    centeredCardState: prediction.centeredCardState,
                    flashForcedOn: isFlashForcedOn
                )
            }
        }
    }

    open func showCardDetails(number: String?, expiry: String?, name: String?) {
        guard let number = number else { return }
        showCardNumber(number, expiry: expiry)
    }

    open func showCardDetailsWithFlash(number: String?, expiry: String?, name: String?) {
        if !isTorchOn() { toggleTorch() }
        guard let number = number else { return }
        showCardNumber(number, expiry: expiry)
    }

    open func shouldUsePrediction(
        errorCorrectedNumber: String?,
        prediction: CreditCardOcrPrediction
    ) -> Bool {
        guard let predictedNumber = prediction.number else { return true }
        return useCurrentFrameNumber(
            errorCorrectedNumber: errorCorrectedNumber,
            currentFrameNumber: predictedNumber
        )
    }
}
