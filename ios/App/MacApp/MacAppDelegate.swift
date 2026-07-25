import Cocoa
import CoreLocation
import CryptoKit
import LocalAuthentication
import Security
import WebKit

@main
enum MartinSolsMacMain {
    private static var appDelegate: MacAppDelegate?

    static func main() {
        let application = NSApplication.shared

        appDelegate = MacAppDelegate()
        application.delegate = appDelegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}

final class MacAppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply, CLLocationManagerDelegate {
    private static let crmUrl = URL(string: "https://crm.jp2.fr/?mobile_app=1&source=mac_app")!
    private static let updateManifestUrl = URL(string: "https://raw.githubusercontent.com/jp2creation/hub_apple/main/releases/martin-sols-update.json")!
    private static let nativeMessageHandlerName = "martinSolsNativeApp"
    private static let splashDuration: TimeInterval = 5.5
    private static let updateCheckDelay: TimeInterval = 1.5
    private static let nativeLocationTimeout: TimeInterval = 15
    private static let titleBarHeight: CGFloat = 46
    private static let keychainService = "fr.martinsols.crm.mac.mobile-auth"
    private static let sessionAccount = "mobile-session"
    private static let appCodeHashKey = "martin_sols_mac_app_code_hash"
    private static let appCodeSaltKey = "martin_sols_mac_app_code_salt"
    private static let appCodeHashIterations = 60000
    private static let appCodeSaltBytes = 16

    private var window: NSWindow!
    private var rootView: NSView!
    private var titleBarView: NSView!
    private var contentView: NSView!
    private var settingsButton: NSButton!
    private var webView: WKWebView!
    private var splashView: NSView?
    private var splashWebView: WKWebView?
    private var updateCheckStarted = false
    private var pendingLocationRequest: NativeLocationRequest?
    private var locationTimeoutWorkItem: DispatchWorkItem?
    private lazy var locationManager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.delegate = self
        return manager
    }()

    deinit {
        webView?.configuration.userContentController.removeScriptMessageHandler(
            forName: Self.nativeMessageHandlerName,
            contentWorld: .page
        )
        cancelNativeLocationRequest()
        locationManager.delegate = nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMainMenu()
        configureWindow()
        configureWebView()
        showSplash()
        webView.load(URLRequest(url: Self.crmUrl))

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.splashDuration) { [weak self] in
            self?.hideSplash()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
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
            replyHandler(Self.nativeActionResult(true, "Ouverture des reglages de securite macOS."), nil)
        case "setAppCode":
            replyHandler(showSetAppCodeDialog(), nil)
        case "clearAppCode":
            clearAppCode()
            replyHandler(Self.nativeActionResult(true, "Code app supprime."), nil)
        default:
            replyHandler(Self.nativeActionResult(false, "Action native inconnue."), nil)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let scheme = navigationAction.request.url?.scheme?.lowercased() else {
            decisionHandler(.cancel)

            return
        }

        decisionHandler((scheme == "http" || scheme == "https") ? .allow : .cancel)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }

        return nil
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let editMenuItem = NSMenuItem()

        mainMenu.addItem(appMenuItem)
        mainMenu.addItem(editMenuItem)

        let appMenu = NSMenu()
        let appSettingsItem = NSMenuItem(
            title: "Paramètres de l’app...",
            action: #selector(openAppSettings),
            keyEquivalent: ","
        )
        appSettingsItem.target = self
        appMenu.addItem(appSettingsItem)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            NSMenuItem(
                title: "Quit Martin Sols",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )
        appMenuItem.submenu = appMenu

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    private func configureWindow() {
        let initialFrame = NSRect(x: 0, y: 0, width: 1180, height: 780)
        window = NSWindow(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Martin Sols"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Self.martinSolsRed
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 900, height: 640)
        window.isReleasedWhenClosed = false
        rootView = NSView(frame: initialFrame)
        rootView.translatesAutoresizingMaskIntoConstraints = false
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = Self.splashBackground.cgColor
        window.contentView = rootView
        configureWindowChrome()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
    }

    private func configureWindowChrome() {
        titleBarView = NSView()
        titleBarView.translatesAutoresizingMaskIntoConstraints = false
        titleBarView.wantsLayer = true
        titleBarView.layer?.backgroundColor = Self.martinSolsRed.cgColor

        let titleLabel = NSTextField(labelWithString: "Martin Sols")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .white

        settingsButton = NSButton()
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.bezelStyle = .regularSquare
        settingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Paramètres de l’app")
        settingsButton.imagePosition = .imageOnly
        settingsButton.isBordered = false
        settingsButton.contentTintColor = .white
        settingsButton.toolTip = "Paramètres de l’app"
        settingsButton.target = self
        settingsButton.action = #selector(openAppSettings)
        settingsButton.wantsLayer = true
        settingsButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        settingsButton.layer?.cornerRadius = 9

        contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = Self.splashBackground.cgColor

        rootView.addSubview(titleBarView)
        titleBarView.addSubview(titleLabel)
        titleBarView.addSubview(settingsButton)
        rootView.addSubview(contentView)

        NSLayoutConstraint.activate([
            titleBarView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            titleBarView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            titleBarView.topAnchor.constraint(equalTo: rootView.topAnchor),
            titleBarView.heightAnchor.constraint(equalToConstant: Self.titleBarHeight),

            titleLabel.leadingAnchor.constraint(equalTo: titleBarView.leadingAnchor, constant: 104),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: settingsButton.leadingAnchor, constant: -12),
            titleLabel.centerYAnchor.constraint(equalTo: titleBarView.centerYAnchor, constant: 2),

            settingsButton.trailingAnchor.constraint(equalTo: titleBarView.trailingAnchor, constant: -16),
            settingsButton.centerYAnchor.constraint(equalTo: titleBarView.centerYAnchor, constant: 2),
            settingsButton.widthAnchor.constraint(equalToConstant: 32),
            settingsButton.heightAnchor.constraint(equalToConstant: 32),

            contentView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: titleBarView.bottomAnchor),
            contentView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
        ])
    }

    private func configureWebView() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        let userContentController = WKUserContentController()
        userContentController.addScriptMessageHandler(self, contentWorld: .page, name: Self.nativeMessageHandlerName)
        userContentController.addUserScript(
            WKUserScript(
                source: nativeBridgeScript(),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        configuration.userContentController = userContentController

        if #available(macOS 11.0, *) {
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        }

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.setValue(false, forKey: "drawsBackground")
        webView.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(webView)

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            webView.topAnchor.constraint(equalTo: contentView.topAnchor),
            webView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    private func showSplash() {
        let container = NSView(frame: contentView.bounds)
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        container.layer?.backgroundColor = Self.splashBackground.cgColor

        let splashWebView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        splashWebView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(splashWebView)
        contentView.addSubview(container)
        splashView = container
        self.splashWebView = splashWebView

        NSLayoutConstraint.activate([
            splashWebView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            splashWebView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            splashWebView.topAnchor.constraint(equalTo: container.topAnchor),
            splashWebView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        splashWebView.loadHTMLString(splashHTML(), baseURL: Bundle.main.resourceURL)
    }

    private func hideSplash() {
        guard let splashView else {
            return
        }

        self.splashView = nil
        splashWebView = nil

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            splashView.animator().alphaValue = 0
        } completionHandler: {
            splashView.removeFromSuperview()
            self.scheduleUpdateCheck()
        }
    }

    @objc private func openAppSettings() {
        let script = """
        (() => {
          document.body?.classList.add('crm-mobile-app', 'crm-mac-app');
          const config = window.MartinSolsCrmConfig;
          if (config) {
            config.mobile = { ...(config.mobile || {}), app: true };
          }
          if (window.MartinSolsMobileApp && typeof window.MartinSolsMobileApp.openSettings === 'function') {
            window.MartinSolsMobileApp.openSettings();
            return true;
          }
          return false;
        })();
        """

        webView.evaluateJavaScript(script) { [weak self] result, _ in
            if (result as? Bool) != true {
                self?.showNativeAppSettingsDialog()
            }
        }
    }

    private func showNativeAppSettingsDialog() {
        let alert = NSAlert()
        alert.messageText = "Paramètres de l’app"
        alert.informativeText = "Version \(appVersionLabel)\n\nMises à jour et futurs réglages de Martin Sols."
        alert.addButton(withTitle: "Rechercher une mise à jour")
        alert.addButton(withTitle: "Fermer")

        if alert.runModal() == .alertFirstButtonReturn {
            checkForAppUpdate(notifyWhenCurrent: true)
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

    private func fetchAppUpdate(completion: @escaping (MacAppUpdate?, String?) -> Void) {
        var components = URLComponents(url: Self.updateManifestUrl, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970)))]

        guard let url = components?.url else {
            completion(nil, "Adresse de mise à jour invalide.")

            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if error != nil {
                completion(nil, "Impossible de vérifier les mises à jour pour le moment.")

                return
            }

            guard
                let httpResponse = response as? HTTPURLResponse,
                (200..<300).contains(httpResponse.statusCode),
                let data,
                let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let update = Self.macUpdate(from: payload)
            else {
                completion(nil, nil)

                return
            }

            completion(update, nil)
        }.resume()
    }

    private func isUpdateNewer(_ update: MacAppUpdate) -> Bool {
        if update.buildNumber > appBuildNumber {
            return true
        }

        if update.buildNumber == 0 && !update.version.isEmpty {
            return update.version.compare(appVersionName, options: .numeric) == .orderedDescending
        }

        return false
    }

    private func showNoUpdateDialog() {
        let alert = NSAlert()
        alert.messageText = "Application à jour"
        alert.informativeText = "Aucune nouvelle version Mac de Martin Sols n’est disponible pour le moment."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showUpdateFailure(message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Mise à jour indisponible"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showUpdateDialog(_ update: MacAppUpdate) {
        let versionLabel = update.version.isEmpty ? String(update.buildNumber) : update.version
        let alert = NSAlert()
        alert.messageText = "Mise à jour disponible"
        alert.informativeText = [
            "Une nouvelle version de Martin Sols est disponible : \(versionLabel).",
            update.releaseNotes,
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
        alert.addButton(withTitle: update.installUrl == nil ? "OK" : "Ouvrir la mise à jour")
        alert.addButton(withTitle: "Plus tard")

        if alert.runModal() == .alertFirstButtonReturn, let installUrl = update.installUrl {
            NSWorkspace.shared.open(installUrl)
        }
    }

    private func showNativeActionFailure(message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Action impossible"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func openDeviceSecuritySettings() {
        let settingsUrls = [
            "x-apple.systempreferences:com.apple.Touch-ID-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.security",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
        ]

        for value in settingsUrls {
            if let url = URL(string: value), NSWorkspace.shared.open(url) {
                return
            }
        }

        let appUrls = [
            "/System/Applications/System Settings.app",
            "/Applications/System Preferences.app",
        ]

        for path in appUrls {
            if FileManager.default.fileExists(atPath: path), NSWorkspace.shared.open(URL(fileURLWithPath: path)) {
                return
            }
        }

        showNativeActionFailure(message: "Réglages de sécurité macOS indisponibles sur ce Mac.")
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
            status["message"] = "Configure un code app ou le verrouillage macOS."
        }

        return status
    }

    private func mobileAuthProtectionLabel(deviceSecure: Bool, appCodeConfigured: Bool) -> String {
        if deviceSecure && appCodeConfigured {
            return "Touch ID, mot de passe Mac ou code app"
        }

        if deviceSecure {
            return "Touch ID ou mot de passe Mac"
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
            return Self.nativeActionResult(false, "Configure un code app ou le verrouillage macOS.")
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

            return Self.nativeActionResult(false, "Connexion rapide indisponible sur ce Mac.")
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
            dispatchNativeAuthResult(requestId: requestId, ok: false, sessionPayload: nil, error: "Configure un code app ou le verrouillage macOS.")

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

    private func showSetAppCodeDialog() -> [String: Any] {
        let codeField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        codeField.placeholderString = "Code app"

        let confirmationField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        confirmationField.placeholderString = "Confirmer le code"

        let stack = NSStackView(views: [
            NSTextField(labelWithString: "Code app"),
            codeField,
            NSTextField(labelWithString: "Confirmation"),
            confirmationField,
        ])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 0, right: 0)

        let alert = NSAlert()
        alert.messageText = "Code de l'app"
        alert.informativeText = "Choisis un code de 4 a 8 chiffres. Il servira a proteger la connexion rapide."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Enregistrer")
        alert.addButton(withTitle: "Annuler")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return Self.nativeActionResult(false, "Code app annule.")
        }

        let code = Self.normalizeAppCode(codeField.stringValue)
        let confirmation = Self.normalizeAppCode(confirmationField.stringValue)

        if !Self.isValidAppCode(code) {
            showNativeActionFailure(message: "Le code app doit contenir 4 a 8 chiffres.")

            return Self.nativeActionResult(false, "Le code app doit contenir 4 a 8 chiffres.")
        }

        if code != confirmation {
            showNativeActionFailure(message: "Les deux codes ne correspondent pas.")

            return Self.nativeActionResult(false, "Les deux codes ne correspondent pas.")
        }

        if storeAppCode(code) {
            dispatchNativeAuthStatusChanged()

            return Self.nativeActionResult(true, "Code app Martin Sols enregistre.")
        }

        showNativeActionFailure(message: "Code impossible a enregistrer.")

        return Self.nativeActionResult(false, "Code impossible a enregistrer.")
    }

    private func showAppCodePrompt(requestId: String) {
        let codeField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        codeField.placeholderString = "Code app"

        let alert = NSAlert()
        alert.messageText = "Connexion Martin Sols"
        alert.informativeText = "Entre le code de l'app pour ouvrir le HUB."
        alert.accessoryView = codeField
        alert.addButton(withTitle: "Valider")
        alert.addButton(withTitle: "Annuler")

        guard alert.runModal() == .alertFirstButtonReturn else {
            dispatchNativeAuthResult(requestId: requestId, ok: false, sessionPayload: nil, error: "Authentification annulee.")

            return
        }

        let code = Self.normalizeAppCode(codeField.stringValue)

        if verifyAppCode(code) {
            deliverSavedMobileSession(requestId: requestId)

            return
        }

        dispatchNativeAuthResult(requestId: requestId, ok: false, sessionPayload: nil, error: "Code incorrect.")
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
            dispatchNativeLocationResult(requestId: requestId, location: nil, error: "Autorisation GPS refusee par macOS.")

            return Self.nativeActionResult(false, "Autorisation GPS refusee par macOS.")
        @unknown default:
            cancelNativeLocationRequest()
            dispatchNativeLocationResult(requestId: requestId, location: nil, error: "Localisation macOS indisponible.")

            return Self.nativeActionResult(false, "Localisation macOS indisponible.")
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
                error: "Position GPS introuvable. Verifie que la localisation macOS est activee."
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
            dispatchNativeLocationResult(requestId: request.requestId, location: nil, error: "Autorisation GPS refusee par macOS.")
        case .notDetermined:
            return
        @unknown default:
            cancelNativeLocationRequest()
            dispatchNativeLocationResult(requestId: request.requestId, location: nil, error: "Localisation macOS indisponible.")
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
        window.__martinSolsNativeAuthStatus = \(statusLiteral);
        window.dispatchEvent(new CustomEvent('martin-sols:native-auth-status-changed',{detail:\(statusLiteral)}));
        """
        evaluateCrmJavaScript(script)
    }

    private func evaluateCrmJavaScript(_ script: String) {
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(script)
        }
    }

    private func isTrustedCrmPage() -> Bool {
        return webView?.url?.host?.caseInsensitiveCompare("crm.jp2.fr") == .orderedSame
    }

    private static var splashBackground: NSColor {
        return NSColor(red: 1, green: 250.0 / 255.0, blue: 247.0 / 255.0, alpha: 1)
    }

    private static var martinSolsRed: NSColor {
        return NSColor(red: 149.0 / 255.0, green: 0, blue: 46.0 / 255.0, alpha: 1)
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

    private var appVersionLabel: String {
        return "\(appVersionName) (\(appVersionCode))"
    }

    private func nativeBridgeScript() -> String {
        let versionName = Self.javaScriptStringLiteral(appVersionName)
        let versionCode = Self.javaScriptStringLiteral(appVersionCode)
        let platformName = Self.javaScriptStringLiteral("macOS")
        let initialAuthStatus = Self.javaScriptLiteral(mobileAuthStatusDictionary())

        return """
        (() => {
          const versionName = \(versionName);
          const versionCode = \(versionCode);
          const platformName = \(platformName);
          const initialAuthStatus = \(initialAuthStatus);
          const nativeHandler = () => window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(Self.nativeMessageHandlerName);
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
              window.__martinSolsNativeAuthStatus = status;
            }

            return window.__martinSolsNativeAuthStatus || initialAuthStatus;
          };
          const refreshAuthStatus = () => postNativeMessage('getMobileAuthStatus')
            .then(syncAuthStatus)
            .catch(() => window.__martinSolsNativeAuthStatus || initialAuthStatus);
          const markAsInstalledApp = () => {
            document.documentElement.classList.add('crm-mac-app');
            document.body?.classList.add('crm-mobile-app', 'crm-mac-app');
            const config = window.MartinSolsCrmConfig;
            if (config) {
              config.mobile = { ...(config.mobile || {}), app: true };
            }
          };
          let crmConfig = window.MartinSolsCrmConfig;

          try {
            Object.defineProperty(window, 'MartinSolsCrmConfig', {
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

          window.__martinSolsNativeAuthStatus = initialAuthStatus;

          window.MartinSolsNativeApp = {
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
              return JSON.stringify(window.__martinSolsNativeAuthStatus || initialAuthStatus);
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

          refreshAuthStatus();
          markAsInstalledApp();
          document.addEventListener('DOMContentLoaded', markAsInstalledApp);
        })();
        """
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

    private static func macUpdate(from payload: [String: Any]) -> MacAppUpdate? {
        guard
            let macPayload = payload["macos"] as? [String: Any] ?? payload["mac"] as? [String: Any]
        else {
            return nil
        }

        let version = stringValue(macPayload, keys: ["versionName", "version"])
        let buildNumber = intValue(macPayload, keys: ["buildNumber", "versionCode", "build"])
        let installUrlString = stringValue(macPayload, keys: ["pkgUrl", "installUrl", "url"])
        let installUrl = installUrlString.isEmpty ? nil : URL(string: installUrlString)
        let releaseNotes = stringValue(macPayload, keys: ["releaseNotes", "notes"])

        if version.isEmpty && buildNumber == 0 && installUrl == nil {
            return nil
        }

        return MacAppUpdate(
            version: version,
            buildNumber: buildNumber,
            installUrl: installUrl,
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

    private func splashHTML() -> String {
        return """
        <!doctype html>
        <html lang="fr">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
            html,
            body {
              width: 100%;
              height: 100%;
              margin: 0;
              overflow: hidden;
              background: #fffaf7;
            }

            body {
              display: grid;
              place-items: center;
            }

            img {
              display: block;
              width: min(26vw, 340px);
              max-width: 340px;
              max-height: 70vh;
              object-fit: contain;
            }
          </style>
        </head>
        <body>
          <img src="opening-animation.gif" alt="">
        </body>
        </html>
        """
    }

    private struct NativeLocationRequest {
        let requestId: String
        let highAccuracy: Bool
    }

    private struct MacAppUpdate {
        let version: String
        let buildNumber: Int
        let installUrl: URL?
        let releaseNotes: String
    }
}
