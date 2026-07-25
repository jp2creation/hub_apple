import Capacitor
import CoreLocation
import CryptoKit
import LocalAuthentication
import Security
import UIKit
import WebKit

@objc(MartinSolsBridgeViewController)
class MartinSolsBridgeViewController: CAPBridgeViewController, WKScriptMessageHandlerWithReply, CLLocationManagerDelegate {
    private static let updateManifestUrl = URL(string: "https://raw.githubusercontent.com/jp2creation/hub_apple/main/releases/martin-sols-update.json")!
    private static let nativeMessageHandlerName = "martinSolsNativeApp"
    private static let updateCheckDelay: TimeInterval = 7
    private static let nativeLocationTimeout: TimeInterval = 15
    private static let keychainService = "fr.martinsols.crm.mobile-auth"
    private static let sessionAccount = "mobile-session"
    private static let appCodeHashKey = "jp2_creation_app_code_hash"
    private static let appCodeSaltKey = "jp2_creation_app_code_salt"
    private static let appCodeHashIterations = 60000
    private static let appCodeSaltBytes = 16

    private weak var crmWebView: WKWebView?
    private var updateCheckStarted = false
    private var pendingLocationRequest: NativeLocationRequest?
    private var locationTimeoutWorkItem: DispatchWorkItem?
    private lazy var locationManager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.delegate = self
        return manager
    }()

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }

    deinit {
        crmWebView?.configuration.userContentController.removeScriptMessageHandler(
            forName: Self.nativeMessageHandlerName,
            contentWorld: .page
        )
        cancelNativeLocationRequest()
        locationManager.delegate = nil
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        scheduleUpdateCheck()
    }

    override func webViewConfiguration(for instanceConfiguration: InstanceConfiguration) -> WKWebViewConfiguration {
        let configuration = super.webViewConfiguration(for: instanceConfiguration)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: Self.nativeMessageHandlerName)
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: nativeBridgeScript(),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )

        if #available(iOS 14.0, *) {
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        }

        return configuration
    }

    override func webView(with frame: CGRect, configuration: WKWebViewConfiguration) -> WKWebView {
        let crmWebView = super.webView(with: frame, configuration: configuration)
        self.crmWebView = crmWebView
        crmWebView.backgroundColor = UIColor(red: 245.0 / 255.0, green: 247.0 / 255.0, blue: 251.0 / 255.0, alpha: 1)
        crmWebView.allowsBackForwardNavigationGestures = true
        crmWebView.scrollView.keyboardDismissMode = .interactive
        crmWebView.scrollView.contentInsetAdjustmentBehavior = .automatic
        return crmWebView
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard message.name == Self.nativeMessageHandlerName, isTrustedCrmPage() else {
            replyHandler(Self.nativeActionResult(false, "Page HUB non autorisee."), nil)

            return
        }

        let body = Self.messageBody(message.body)
        let action = body["action"] as? String ?? message.body as? String ?? ""

        switch action {
        case "checkForUpdates":
            checkForAppUpdate(notifyWhenCurrent: true)
            replyHandler(Self.nativeActionResult(true, "Recherche de mise a jour lancee."), nil)
        case "getMobileAuthStatus":
            replyHandler(mobileAuthStatusDictionary(), nil)
        case "saveMobileSession":
            replyHandler(saveMobileSessionPayload(body["payload"] as? String ?? ""), nil)
        case "authenticateSavedMobileSession":
            authenticateSavedMobileSession(requestId: body["requestId"] as? String ?? "")
            replyHandler(Self.nativeActionResult(true, "Authentification lancee."), nil)
        case "clearMobileSession":
            clearSavedMobileSession()
            dispatchNativeAuthStatusChanged()
            replyHandler(Self.nativeActionResult(true, "Connexion rapide supprimee."), nil)
        case "requestLocation":
            replyHandler(
                requestNativeLocation(
                    requestId: body["requestId"] as? String ?? "",
                    highAccuracy: body["highAccuracy"] as? Bool ?? false
                ),
                nil
            )
        case "openDeviceSecuritySettings":
            openDeviceSecuritySettings()
            replyHandler(Self.nativeActionResult(true, "Ouverture des reglages iOS."), nil)
        case "setAppCode":
            showSetAppCodeDialog { result in
                replyHandler(result, nil)
            }
        case "clearAppCode":
            clearAppCode()
            replyHandler(Self.nativeActionResult(true, "Code app supprime."), nil)
        default:
            replyHandler(Self.nativeActionResult(false, "Action native inconnue."), nil)
        }
    }

    private func scheduleUpdateCheck() {
        if updateCheckStarted {
            return
        }

        updateCheckStarted = true

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.updateCheckDelay) { [weak self] in
            self?.checkForAppUpdate(notifyWhenCurrent: false)
        }
    }

    private func checkForAppUpdate(notifyWhenCurrent: Bool) {
        if !notifyWhenCurrent && !isTrustedCrmPage() {
            return
        }

        fetchAppUpdate { [weak self] update, errorMessage in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }

                if let errorMessage {
                    if notifyWhenCurrent {
                        self.showUpdateFailure(message: errorMessage)
                    }

                    return
                }

                guard let update, self.isUpdateNewer(update) else {
                    if notifyWhenCurrent {
                        self.showNoUpdateDialog()
                    }

                    return
                }

                self.showUpdateDialog(update)
            }
        }
    }

    private func fetchAppUpdate(completion: @escaping (IosAppUpdate?, String?) -> Void) {
        var components = URLComponents(url: Self.updateManifestUrl, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970)))]

        guard let url = components?.url else {
            completion(nil, "Adresse de mise a jour invalide.")

            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if error != nil {
                completion(nil, "Impossible de verifier les mises a jour pour le moment.")

                return
            }

            guard
                let httpResponse = response as? HTTPURLResponse,
                (200..<300).contains(httpResponse.statusCode),
                let data,
                let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let update = Self.iosUpdate(from: payload)
            else {
                completion(nil, nil)

                return
            }

            completion(update, nil)
        }.resume()
    }

    private func isUpdateNewer(_ update: IosAppUpdate) -> Bool {
        if update.buildNumber > appBuildNumber {
            return true
        }

        if update.buildNumber == 0 && !update.version.isEmpty {
            return update.version.compare(appVersionName, options: .numeric) == .orderedDescending
        }

        return false
    }

    private func showNoUpdateDialog() {
        let alert = UIAlertController(
            title: "Application a jour",
            message: "Aucune nouvelle version iPhone/iPad de Martin Sols n'est disponible pour le moment.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presentAlert(alert)
    }

    private func showUpdateFailure(message: String) {
        let alert = UIAlertController(
            title: "Mise a jour indisponible",
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presentAlert(alert)
    }

    private func showUpdateDialog(_ update: IosAppUpdate) {
        let versionLabel = update.version.isEmpty ? String(update.buildNumber) : update.version
        let notes = [
            "Une nouvelle version iPhone/iPad de Martin Sols est disponible : \(versionLabel).",
            update.releaseNotes,
            update.distribution.isEmpty ? "" : "Distribution : \(update.distribution).",
            update.installUrl == nil ? "L'installation iOS doit passer par App Store, TestFlight, MDM ou distribution entreprise." : "",
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")

        let alert = UIAlertController(
            title: "Mise a jour disponible",
            message: notes,
            preferredStyle: .alert
        )

        if let installUrl = update.installUrl {
            alert.addAction(
                UIAlertAction(title: "Ouvrir la mise a jour", style: .default) { _ in
                    UIApplication.shared.open(installUrl)
                }
            )
            alert.addAction(UIAlertAction(title: "Plus tard", style: .cancel))
        } else {
            alert.addAction(UIAlertAction(title: "OK", style: .default))
        }

        presentAlert(alert)
    }

    private func presentAlert(_ alert: UIAlertController) {
        var presenter: UIViewController? = self

        while let presentedViewController = presenter?.presentedViewController {
            presenter = presentedViewController
        }

        presenter?.present(alert, animated: true)
    }

    private func showNativeActionFailure(_ message: String) {
        let alert = UIAlertController(
            title: "Action impossible",
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presentAlert(alert)
    }

    private func openDeviceSecuritySettings() {
        guard let settingsUrl = URL(string: UIApplication.openSettingsURLString) else {
            showNativeActionFailure("Reglages iOS indisponibles sur cet appareil.")

            return
        }

        UIApplication.shared.open(settingsUrl)
    }

    private func mobileAuthStatusDictionary() -> [String: Any] {
        let deviceSecure = isDeviceSecure()
        let appCodeConfigured = isAppCodeConfigured()
        let protectedSessionAvailable = deviceSecure || appCodeConfigured
        var status: [String: Any] = [
            "ok": true,
            "available": protectedSessionAvailable,
            "configured": protectedSessionAvailable,
            "deviceSecure": deviceSecure,
            "appCodeConfigured": appCodeConfigured,
            "hasSession": hasSavedMobileSession(),
            "label": mobileAuthProtectionLabel(deviceSecure: deviceSecure, appCodeConfigured: appCodeConfigured),
        ]

        if !protectedSessionAvailable {
            status["message"] = "Configure un code app ou le verrouillage iOS."
        }

        return status
    }

    private func mobileAuthProtectionLabel(deviceSecure: Bool, appCodeConfigured: Bool) -> String {
        if deviceSecure && appCodeConfigured {
            return "Face ID, Touch ID, code appareil ou code app"
        }

        if deviceSecure {
            return "Face ID, Touch ID ou code appareil"
        }

        if appCodeConfigured {
            return "Code app"
        }

        return "Non configuree"
    }

    private func isDeviceSecure() -> Bool {
        let context = LAContext()
        var error: NSError?

        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    private func hasSavedMobileSession() -> Bool {
        return keychainString(account: Self.sessionAccount) != nil
    }

    private func canProtectMobileSession() -> Bool {
        return isDeviceSecure() || isAppCodeConfigured()
    }

    private func saveMobileSessionPayload(_ payload: String) -> [String: Any] {
        if !isTrustedCrmPage() {
            return Self.nativeActionResult(false, "Page HUB non autorisee.")
        }

        if !canProtectMobileSession() {
            return Self.nativeActionResult(false, "Configure un code app ou le verrouillage iOS.")
        }

        guard
            let data = payload.data(using: .utf8),
            let session = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let token = session["token"] as? String,
            let refreshToken = session["refreshToken"] as? String,
            !token.isEmpty,
            !refreshToken.isEmpty
        else {
            return Self.nativeActionResult(false, "Session mobile incomplete.")
        }

        guard storeKeychainString(payload, account: Self.sessionAccount) else {
            clearSavedMobileSession()

            return Self.nativeActionResult(false, "Connexion rapide indisponible sur cet appareil.")
        }

        dispatchNativeAuthStatusChanged()

        return Self.nativeActionResult(true, "Connexion rapide enregistree.")
    }

    private func authenticateSavedMobileSession(requestId: String) {
        if !isTrustedCrmPage() {
            dispatchNativeAuthResult(requestId: requestId, ok: false, sessionPayload: nil, error: "Page HUB non autorisee.")

            return
        }

        if !hasSavedMobileSession() {
            dispatchNativeAuthResult(requestId: requestId, ok: false, sessionPayload: nil, error: "Aucune connexion rapide n'est enregistree.")

            return
        }

        if !canProtectMobileSession() {
            dispatchNativeAuthResult(requestId: requestId, ok: false, sessionPayload: nil, error: "Configure un code app ou le verrouillage iOS.")

            return
        }

        if isDeviceSecure() {
            authenticateWithDeviceOwner(requestId: requestId)

            return
        }

        showAppCodePrompt(requestId: requestId)
    }

    private func authenticateWithDeviceOwner(requestId: String) {
        let context = LAContext()
        context.localizedCancelTitle = "Annuler"

        context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: "Confirme ton identite pour ouvrir Martin Sols."
        ) { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }

                if success {
                    self.deliverSavedMobileSession(requestId: requestId)

                    return
                }

                if self.isAppCodeConfigured() {
                    self.showAppCodePrompt(requestId: requestId)

                    return
                }

                self.dispatchNativeAuthResult(
                    requestId: requestId,
                    ok: false,
                    sessionPayload: nil,
                    error: error?.localizedDescription ?? "Authentification annulee."
                )
            }
        }
    }

    private func deliverSavedMobileSession(requestId: String) {
        guard
            let payload = keychainString(account: Self.sessionAccount),
            let data = payload.data(using: .utf8),
            (try? JSONSerialization.jsonObject(with: data)) != nil
        else {
            clearSavedMobileSession()
            dispatchNativeAuthResult(requestId: requestId, ok: false, sessionPayload: nil, error: "Connexion rapide expiree. Reconnecte-toi une fois.")

            return
        }

        dispatchNativeAuthResult(requestId: requestId, ok: true, sessionPayload: payload, error: "")
    }

    private func showSetAppCodeDialog(reply: @escaping ([String: Any]) -> Void) {
        let alert = UIAlertController(
            title: "Code de l'app",
            message: "Choisis un code de 4 a 8 chiffres. Il servira a proteger la connexion rapide.",
            preferredStyle: .alert
        )
        alert.addTextField { textField in
            textField.placeholder = "Code app"
            textField.keyboardType = .numberPad
            textField.isSecureTextEntry = true
        }
        alert.addTextField { textField in
            textField.placeholder = "Confirmer le code"
            textField.keyboardType = .numberPad
            textField.isSecureTextEntry = true
        }
        alert.addAction(
            UIAlertAction(title: "Enregistrer", style: .default) { [weak self, weak alert] _ in
                guard let self else {
                    reply(Self.nativeActionResult(false, "Code app impossible a enregistrer."))

                    return
                }

                let textFields = alert?.textFields ?? []
                let code = Self.normalizeAppCode(textFields.indices.contains(0) ? textFields[0].text : nil)
                let confirmation = Self.normalizeAppCode(textFields.indices.contains(1) ? textFields[1].text : nil)

                if !Self.isValidAppCode(code) {
                    self.showNativeActionFailure("Le code app doit contenir 4 a 8 chiffres.")
                    reply(Self.nativeActionResult(false, "Le code app doit contenir 4 a 8 chiffres."))

                    return
                }

                if code != confirmation {
                    self.showNativeActionFailure("Les deux codes ne correspondent pas.")
                    reply(Self.nativeActionResult(false, "Les deux codes ne correspondent pas."))

                    return
                }

                if self.storeAppCode(code) {
                    self.dispatchNativeAuthStatusChanged()
                    reply(Self.nativeActionResult(true, "Code app Martin Sols enregistre."))

                    return
                }

                self.showNativeActionFailure("Code impossible a enregistrer.")
                reply(Self.nativeActionResult(false, "Code impossible a enregistrer."))
            }
        )
        alert.addAction(
            UIAlertAction(title: "Annuler", style: .cancel) { _ in
                reply(Self.nativeActionResult(false, "Code app annule."))
            }
        )
        presentAlert(alert)
    }

    private func showAppCodePrompt(requestId: String) {
        let alert = UIAlertController(
            title: "Connexion Martin Sols",
            message: "Entre le code de l'app pour ouvrir le HUB.",
            preferredStyle: .alert
        )
        alert.addTextField { textField in
            textField.placeholder = "Code app"
            textField.keyboardType = .numberPad
            textField.isSecureTextEntry = true
        }
        alert.addAction(
            UIAlertAction(title: "Valider", style: .default) { [weak self, weak alert] _ in
                guard let self else {
                    return
                }

                let code = Self.normalizeAppCode(alert?.textFields?.first?.text)

                if self.verifyAppCode(code) {
                    self.deliverSavedMobileSession(requestId: requestId)

                    return
                }

                self.dispatchNativeAuthResult(requestId: requestId, ok: false, sessionPayload: nil, error: "Code incorrect.")
            }
        )
        alert.addAction(
            UIAlertAction(title: "Annuler", style: .cancel) { [weak self] _ in
                self?.dispatchNativeAuthResult(requestId: requestId, ok: false, sessionPayload: nil, error: "Authentification annulee.")
            }
        )
        presentAlert(alert)
    }

    private func isAppCodeConfigured() -> Bool {
        return !Self.storedString(Self.appCodeHashKey).isEmpty && !Self.storedString(Self.appCodeSaltKey).isEmpty
    }

    private func storeAppCode(_ code: String) -> Bool {
        let salt = Self.randomData(length: Self.appCodeSaltBytes)
        let hash = Self.deriveAppCodeHash(code, salt: salt)
        UserDefaults.standard.set(salt.base64EncodedString(), forKey: Self.appCodeSaltKey)
        UserDefaults.standard.set(hash.base64EncodedString(), forKey: Self.appCodeHashKey)

        return true
    }

    private func verifyAppCode(_ code: String) -> Bool {
        if !Self.isValidAppCode(code) {
            return false
        }

        guard
            let salt = Data(base64Encoded: Self.storedString(Self.appCodeSaltKey)),
            let expectedHash = Data(base64Encoded: Self.storedString(Self.appCodeHashKey))
        else {
            return false
        }

        return Self.constantTimeEquals(expectedHash, Self.deriveAppCodeHash(code, salt: salt))
    }

    private func clearAppCode() {
        UserDefaults.standard.removeObject(forKey: Self.appCodeHashKey)
        UserDefaults.standard.removeObject(forKey: Self.appCodeSaltKey)

        if !isDeviceSecure() {
            clearSavedMobileSession()
        }

        dispatchNativeAuthStatusChanged()
    }

    private func clearSavedMobileSession() {
        deleteKeychainItem(account: Self.sessionAccount)
    }

    private func requestNativeLocation(requestId: String, highAccuracy: Bool) -> [String: Any] {
        if requestId.isEmpty {
            dispatchNativeLocationResult(requestId: "", location: nil, error: "Demande GPS invalide.")

            return Self.nativeActionResult(false, "Demande GPS invalide.")
        }

        cancelNativeLocationRequest()
        pendingLocationRequest = NativeLocationRequest(requestId: requestId, highAccuracy: highAccuracy)
        locationManager.desiredAccuracy = highAccuracy ? kCLLocationAccuracyBest : kCLLocationAccuracyHundredMeters

        switch locationManager.authorizationStatus {
        case .notDetermined:
            startNativeLocationTimeout()
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            startNativeLocationResolution()
        case .denied, .restricted:
            cancelNativeLocationRequest()
            dispatchNativeLocationResult(requestId: requestId, location: nil, error: "Autorisation GPS refusee par iOS.")

            return Self.nativeActionResult(false, "Autorisation GPS refusee par iOS.")
        @unknown default:
            cancelNativeLocationRequest()
            dispatchNativeLocationResult(requestId: requestId, location: nil, error: "Localisation iOS indisponible.")

            return Self.nativeActionResult(false, "Localisation iOS indisponible.")
        }

        return Self.nativeActionResult(true, "Recherche de localisation lancee.")
    }

    private func startNativeLocationResolution() {
        guard pendingLocationRequest != nil else {
            return
        }

        startNativeLocationTimeout()
        locationManager.requestLocation()
    }

    private func startNativeLocationTimeout() {
        locationTimeoutWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let request = self.pendingLocationRequest else {
                return
            }

            self.cancelNativeLocationRequest()
            self.dispatchNativeLocationResult(
                requestId: request.requestId,
                location: nil,
                error: "Position GPS introuvable. Verifie que la localisation iOS est activee."
            )
        }

        locationTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.nativeLocationTimeout, execute: workItem)
    }

    private func cancelNativeLocationRequest() {
        locationTimeoutWorkItem?.cancel()
        locationTimeoutWorkItem = nil
        locationManager.stopUpdatingLocation()
        pendingLocationRequest = nil
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard let request = pendingLocationRequest else {
            return
        }

        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            startNativeLocationResolution()
        case .denied, .restricted:
            cancelNativeLocationRequest()
            dispatchNativeLocationResult(requestId: request.requestId, location: nil, error: "Autorisation GPS refusee par iOS.")
        case .notDetermined:
            return
        @unknown default:
            cancelNativeLocationRequest()
            dispatchNativeLocationResult(requestId: request.requestId, location: nil, error: "Localisation iOS indisponible.")
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let request = pendingLocationRequest else {
            return
        }

        let location = locations.max { left, right in
            if left.horizontalAccuracy == right.horizontalAccuracy {
                return left.timestamp < right.timestamp
            }

            return left.horizontalAccuracy > right.horizontalAccuracy
        }

        cancelNativeLocationRequest()
        dispatchNativeLocationResult(requestId: request.requestId, location: location, error: "")
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard let request = pendingLocationRequest else {
            return
        }

        cancelNativeLocationRequest()
        dispatchNativeLocationResult(requestId: request.requestId, location: nil, error: error.localizedDescription)
    }

    private func dispatchNativeLocationResult(requestId: String, location: CLLocation?, error: String) {
        var detail: [String: Any] = [
            "requestId": requestId,
            "ok": location != nil,
        ]

        if let location {
            detail["location"] = [
                "accuracy": max(location.horizontalAccuracy, 0),
                "latitude": location.coordinate.latitude,
                "longitude": location.coordinate.longitude,
                "timestamp": Int(location.timestamp.timeIntervalSince1970 * 1000),
            ]
        } else {
            detail["error"] = error.isEmpty ? "Localisation indisponible." : error
        }

        let script = "window.dispatchEvent(new CustomEvent('martin-sols:native-location-result',{detail:\(Self.javaScriptLiteral(detail))}));"
        evaluateCrmJavaScript(script)
    }

    private func dispatchNativeAuthResult(requestId: String, ok: Bool, sessionPayload: String?, error: String) {
        var detail: [String: Any] = [
            "requestId": requestId,
            "ok": ok,
        ]

        if ok, let sessionPayload, let data = sessionPayload.data(using: .utf8), let session = try? JSONSerialization.jsonObject(with: data) {
            detail["session"] = session
        } else if !ok {
            detail["error"] = error.isEmpty ? "Authentification impossible." : error
        }

        let script = "window.dispatchEvent(new CustomEvent('martin-sols:native-auth-result',{detail:\(Self.javaScriptLiteral(detail))}));"
        evaluateCrmJavaScript(script)
    }

    private func dispatchNativeAuthStatusChanged() {
        let status = mobileAuthStatusDictionary()
        let statusLiteral = Self.javaScriptLiteral(status)
        let script = """
        (() => {
          const legacyBrand = String.fromCharCode(77, 97, 114, 116, 105, 110, 83, 111, 108, 115);
          const legacyBrandLower = legacyBrand.charAt(0).toLowerCase() + legacyBrand.slice(1);
          window.__martinSolsNativeAuthStatus = \(statusLiteral);
          window['__' + legacyBrandLower + 'NativeAuthStatus'] = \(statusLiteral);
          window.dispatchEvent(new CustomEvent('martin-sols:native-auth-status-changed',{detail:\(statusLiteral)}));
        })();
        """
        evaluateCrmJavaScript(script)
    }

    private func evaluateCrmJavaScript(_ script: String) {
        DispatchQueue.main.async { [weak self] in
            self?.crmWebView?.evaluateJavaScript(script)
        }
    }

    private func isTrustedCrmPage() -> Bool {
        guard let url = crmWebView?.url, let host = url.host else {
            return false
        }

        if let configuredHost = Self.configuredHubHost {
            return host.caseInsensitiveCompare(configuredHost) == .orderedSame
        }

        return url.scheme?.caseInsensitiveCompare("https") == .orderedSame
    }

    private static var configuredHubHost: String? {
        return configuredHubUrl(source: "ios_app")?.host
    }

    private static func configuredHubUrl(source: String) -> URL? {
        let rawValue = Bundle.main.object(forInfoDictionaryKey: "JP2HubURL") as? String ?? ""
        var trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty || trimmed.contains("$(") {
            return nil
        }

        if !trimmed.lowercased().hasPrefix("http://") && !trimmed.lowercased().hasPrefix("https://") {
            trimmed = "https://\(trimmed)"
        }

        guard var components = URLComponents(string: trimmed), components.host?.isEmpty == false else {
            return nil
        }

        var queryItems = components.queryItems ?? []

        if !queryItems.contains(where: { $0.name == "mobile_app" }) {
            queryItems.append(URLQueryItem(name: "mobile_app", value: "1"))
        }

        if !queryItems.contains(where: { $0.name == "source" }) {
            queryItems.append(URLQueryItem(name: "source", value: source))
        }

        components.queryItems = queryItems

        return components.url
    }

    private var appVersionName: String {
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.38"
    }

    private var appVersionCode: String {
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "40"
    }

    private var appBuildNumber: Int {
        return Int(appVersionCode) ?? 0
    }

    private var platformName: String {
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    }

    private func nativeBridgeScript() -> String {
        let versionName = Self.javaScriptStringLiteral(appVersionName)
        let versionCode = Self.javaScriptStringLiteral(appVersionCode)
        let platformName = Self.javaScriptStringLiteral(platformName)
        let initialAuthStatus = Self.javaScriptLiteral(mobileAuthStatusDictionary())

        return """
        (() => {
          const versionName = \(versionName);
          const versionCode = \(versionCode);
          const platformName = \(platformName);
          const initialAuthStatus = \(initialAuthStatus);
          const legacyBrand = String.fromCharCode(77, 97, 114, 116, 105, 110, 83, 111, 108, 115);
          const legacyBrandLower = legacyBrand.charAt(0).toLowerCase() + legacyBrand.slice(1);
          const configKeys = ['MartinSolsCrmConfig', legacyBrand + 'CrmConfig'];
          const nativeAppKeys = ['MartinSolsNativeApp', legacyBrand + 'NativeApp'];
          const authStatusKeys = ['__martinSolsNativeAuthStatus', '__' + legacyBrandLower + 'NativeAuthStatus'];
          const nativeHandler = () => window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(Self.nativeMessageHandlerName);
          const readFirst = (keys) => {
            for (const key of keys) {
              if (window[key]) {
                return window[key];
              }
            }

            return undefined;
          };
          const writeAll = (keys, value) => {
            keys.forEach((key) => {
              window[key] = value;
            });
          };
          const normalizeNativeResult = (value) => {
            if (typeof value === 'string') {
              return value;
            }

            try {
              return JSON.stringify(value || { ok: true });
            } catch (_) {
              return JSON.stringify({ ok: false, message: 'Reponse native invalide.' });
            }
          };
          const postNativeMessage = (action, payload) => {
            const handler = nativeHandler();

            if (!handler) {
              return Promise.resolve({ ok: false, message: 'Action native indisponible.' });
            }

            try {
              const result = handler.postMessage(Object.assign({ action }, payload || {}));

              if (result && typeof result.then === 'function') {
                return result;
              }

              return Promise.resolve(result || { ok: true });
            } catch (error) {
              return Promise.resolve({
                ok: false,
                message: error && error.message ? error.message : 'Action native indisponible.',
              });
            }
          };
          const syncAuthStatus = (status) => {
            if (status && typeof status === 'object') {
              writeAll(authStatusKeys, status);
            }

            return readFirst(authStatusKeys) || initialAuthStatus;
          };
          const refreshAuthStatus = () => postNativeMessage('getMobileAuthStatus')
            .then(syncAuthStatus)
            .catch(() => readFirst(authStatusKeys) || initialAuthStatus);
          const markAsInstalledApp = () => {
            document.documentElement.classList.add('crm-ios-app');
            document.body?.classList.add('crm-mobile-app', 'crm-ios-app');
            const config = readFirst(configKeys);

            if (config) {
              config.mobile = Object.assign({}, config.mobile || {}, { app: true });
            }
          };
          let crmConfig = readFirst(configKeys);

          writeAll(authStatusKeys, initialAuthStatus);

          configKeys.forEach((configKey) => {
            try {
              Object.defineProperty(window, configKey, {
                configurable: true,
                get() {
                  return crmConfig;
                },
                set(value) {
                  crmConfig = value;
                  markAsInstalledApp();
                },
              });
            } catch (_) {}
          });

          const nativeApp = {
            getVersionName() {
              return versionName;
            },
            getVersionCode() {
              return versionCode;
            },
            getPlatformName() {
              return platformName;
            },
            checkForUpdates() {
              return postNativeMessage('checkForUpdates').then(normalizeNativeResult);
            },
            getMobileAuthStatus() {
              return JSON.stringify(readFirst(authStatusKeys) || initialAuthStatus);
            },
            saveMobileSession(payload) {
              return postNativeMessage('saveMobileSession', { payload }).then((result) => {
                refreshAuthStatus();

                return normalizeNativeResult(result);
              });
            },
            authenticateSavedMobileSession(requestId) {
              return postNativeMessage('authenticateSavedMobileSession', { requestId }).then(normalizeNativeResult);
            },
            clearMobileSession() {
              return postNativeMessage('clearMobileSession').then((result) => {
                refreshAuthStatus();

                return normalizeNativeResult(result);
              });
            },
            requestLocation(requestId, highAccuracy) {
              return postNativeMessage('requestLocation', { requestId, highAccuracy: Boolean(highAccuracy) }).then(normalizeNativeResult);
            },
            openDeviceSecuritySettings() {
              return postNativeMessage('openDeviceSecuritySettings').then(normalizeNativeResult);
            },
            setAppCode() {
              return postNativeMessage('setAppCode').then((result) => {
                refreshAuthStatus();

                return normalizeNativeResult(result);
              });
            },
            clearAppCode() {
              return postNativeMessage('clearAppCode').then((result) => {
                refreshAuthStatus();

                return normalizeNativeResult(result);
              });
            },
          };

          writeAll(nativeAppKeys, nativeApp);
          refreshAuthStatus();
          markAsInstalledApp();
          document.addEventListener('DOMContentLoaded', markAsInstalledApp);
        })();
        """
    }

    private func keychainString(account: String) -> String? {
        guard let data = keychainData(account: account) else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    private func keychainData(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?

        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }

        return result as? Data
    }

    private func storeKeychainString(_ value: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else {
            return false
        }

        deleteKeychainItem(account: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data,
        ]

        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private func deleteKeychainItem(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func messageBody(_ body: Any) -> [String: Any] {
        return body as? [String: Any] ?? [:]
    }

    private static func nativeActionResult(_ ok: Bool, _ message: String) -> [String: Any] {
        return [
            "ok": ok,
            "message": message,
        ]
    }

    private static func normalizeAppCode(_ code: String?) -> String {
        return code?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func isValidAppCode(_ code: String) -> Bool {
        return code.range(of: #"^[0-9]{4,8}$"#, options: .regularExpression) != nil
    }

    private static func randomData(length: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)

        return Data(bytes)
    }

    private static func deriveAppCodeHash(_ code: String, salt: Data) -> Data {
        let codeData = code.data(using: .utf8) ?? Data()
        var hashInput = Data()
        hashInput.append(salt)
        hashInput.append(codeData)
        var hash = Data(SHA256.hash(data: hashInput))

        for _ in 1..<Self.appCodeHashIterations {
            var iterationInput = Data()
            iterationInput.append(hash)
            iterationInput.append(salt)
            iterationInput.append(codeData)
            hash = Data(SHA256.hash(data: iterationInput))
        }

        return hash
    }

    private static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        if lhs.count != rhs.count {
            return false
        }

        var difference: UInt8 = 0

        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }

        return difference == 0
    }

    private static func storedString(_ key: String) -> String {
        return UserDefaults.standard.string(forKey: key) ?? ""
    }

    private static func javaScriptStringLiteral(_ value: String) -> String {
        guard
            let data = try? JSONEncoder().encode(value),
            let string = String(data: data, encoding: .utf8)
        else {
            return "\"\""
        }

        return string
    }

    private static func javaScriptLiteral(_ value: Any) -> String {
        guard
            JSONSerialization.isValidJSONObject(value),
            let data = try? JSONSerialization.data(withJSONObject: value),
            let string = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }

        return string
    }

    private static func iosUpdate(from payload: [String: Any]) -> IosAppUpdate? {
        guard
            let iosPayload = payload["ios"] as? [String: Any]
        else {
            return nil
        }

        let version = stringValue(iosPayload, keys: ["versionName", "version"])
        let buildNumber = intValue(iosPayload, keys: ["buildNumber", "versionCode", "build"])
        let installUrlString = stringValue(iosPayload, keys: ["installUrl", "appStoreUrl", "testFlightUrl", "url"])
        let installUrl = installUrlString.isEmpty ? nil : URL(string: installUrlString)
        let distribution = stringValue(iosPayload, keys: ["distribution"])
        let releaseNotes = stringValue(iosPayload, keys: ["releaseNotes", "notes"])

        if version.isEmpty && buildNumber == 0 && installUrl == nil {
            return nil
        }

        return IosAppUpdate(
            version: version,
            buildNumber: buildNumber,
            installUrl: installUrl,
            distribution: distribution,
            releaseNotes: releaseNotes
        )
    }

    private static func stringValue(_ payload: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let value = payload[key] as? String {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            if let value = payload[key] as? NSNumber {
                return value.stringValue
            }
        }

        return ""
    }

    private static func intValue(_ payload: [String: Any], keys: [String]) -> Int {
        for key in keys {
            if let value = payload[key] as? Int {
                return value
            }

            if let value = payload[key] as? NSNumber {
                return value.intValue
            }

            if let value = payload[key] as? String, let intValue = Int(value) {
                return intValue
            }
        }

        return 0
    }

    private struct NativeLocationRequest {
        let requestId: String
        let highAccuracy: Bool
    }

    private struct IosAppUpdate {
        let version: String
        let buildNumber: Int
        let installUrl: URL?
        let distribution: String
        let releaseNotes: String
    }
}
