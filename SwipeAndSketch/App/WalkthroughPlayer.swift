import SwiftUI
import WebKit

/// How the walkthrough in the help card is doing, as its web view reports it.
@MainActor final class WalkthroughPlayback: ObservableObject {
    enum Phase: Equatable { case loading, ready, failed }

    @Published fileprivate(set) var phase = Phase.loading
    /// Bumped to load the lesson again after a failure.
    @Published private(set) var attempt = 0

    func retry() {
        phase = .loading
        attempt += 1
    }
}

/// The compact website player for one lesson: the canvas simulation with its own playback bar.
/// Only the release's player pages load here; other links open outside the app. Playback pauses
/// when the app leaves the foreground and the page goes away with the card.
struct WalkthroughPlayer: UIViewRepresentable {
    let lesson: WalkthroughLesson
    let release: String
    @ObservedObject var playback: WalkthroughPlayback

    /// How long the page may take to say it's ready before the card offers Retry.
    static let readyTimeout: Duration = .seconds(20)

    func makeCoordinator() -> Coordinator { Coordinator(release: release, playback: playback) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(WeakMessageHandler(context.coordinator), contentWorld: .page,
                                                name: Walkthroughs.messageHandler)
        configuration.allowsInlineMediaPlayback = true
        configuration.dataDetectorTypes = []
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.allowsLinkPreview = false
        web.allowsBackForwardNavigationGestures = false
        web.scrollView.bounces = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.isOpaque = false
        web.backgroundColor = .clear
        web.accessibilityIdentifier = "help.walkthrough.web"
        #if DEBUG
        web.isInspectable = true
        #endif
        context.coordinator.web = web
        context.coordinator.load(lesson, attempt: playback.attempt)
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.load(lesson, attempt: playback.attempt)
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.pause()
        coordinator.timeout?.cancel()
        web.stopLoading()
        web.configuration.userContentController.removeScriptMessageHandler(forName: Walkthroughs.messageHandler, contentWorld: .page)
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let release: String
        let playback: WalkthroughPlayback
        weak var web: WKWebView?
        fileprivate var timeout: Task<Void, Never>?
        private var loaded: (id: String, attempt: Int)?
        private var ready = false
        /// The lesson the page now loading or showing plays; it follows the player's own moves too.
        private var expected: String?

        init(release: String, playback: WalkthroughPlayback) {
            self.release = release
            self.playback = playback
            super.init()
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(leavingForeground), name: UIApplication.willResignActiveNotification, object: nil)
            center.addObserver(self, selector: #selector(leavingForeground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        }

        @objc private func leavingForeground() { pause() }

        func load(_ lesson: WalkthroughLesson, attempt: Int) {
            guard let web, loaded?.id != lesson.id || loaded?.attempt != attempt else { return }
            pause()
            loaded = (lesson.id, attempt)
            expected = lesson.id
            ready = false
            // Called while SwiftUI updates the view, so the card hears about it just after.
            if playback.phase != .loading { Task { self.playback.phase = .loading } }
            web.load(URLRequest(url: lesson.embed))
            timeout?.cancel()
            timeout = Task { [weak self] in
                try? await Task.sleep(for: WalkthroughPlayer.readyTimeout)
                guard let self, !Task.isCancelled, !self.ready else { return }
                self.fail()
            }
        }

        /// Sends `pause`; harmless before the page is ready or after it ended.
        func pause() { send(["action": "pause"]) }

        private func send(_ command: [String: Any]) {
            guard ready, let web else { return }
            var message = command
            message["protocol"] = Walkthroughs.protocolName
            web.callAsyncJavaScript("return window.SwipeSketchWalkthrough.command(message);", arguments: ["message": message],
                                    in: nil, in: .page, completionHandler: nil)
        }

        private func fail() {
            timeout?.cancel()
            ready = false
            web?.stopLoading()
            playback.phase = .failed
        }

        fileprivate func received(_ message: WKScriptMessage) {
            // Only the website's own top-level page speaks for the player.
            let origin = message.frameInfo.securityOrigin
            guard message.frameInfo.isMainFrame, message.webView === web, origin.protocol == "https",
                  origin.host == Walkthroughs.host, origin.port == 0 || origin.port == 443,
                  let event = WalkthroughEvent(body: message.body) else { return }
            switch event {
            case .loadFailed:
                fail()
            case let .state(lesson, _, _, _, _):
                // The page being replaced still reports as it pauses; only the one now loading counts.
                guard lesson == expected else { return }
                ready = true
                timeout?.cancel()
                if playback.phase != .ready { playback.phase = .ready }
            }
        }

        // MARK: Navigation

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            let url = action.request.url
            if action.targetFrame?.isMainFrame == true, let url, Walkthroughs.isPlayerURL(url, release: release) {
                expected = Walkthroughs.lesson(in: url)
                return .allow
            }
            if let frame = action.targetFrame, !frame.isMainFrame, let url, url.scheme == "https", url.host == Walkthroughs.host {
                return .allow
            }
            // Any other link the user follows leaves the card for the browser.
            if action.navigationType == .linkActivated, let url, url.scheme == "https" { _ = await UIApplication.shared.open(url) }
            return .cancel
        }

        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            guard response.isForMainFrame else { return .allow }
            guard let http = response.response as? HTTPURLResponse, http.statusCode == 200 else {
                fail()
                return .cancel
            }
            return .allow
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            failed(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { failed(error) }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fail() }

        private func failed(_ error: any Error) {
            // A navigation this card turned away isn't a failure of the lesson.
            if (error as NSError).domain == NSURLErrorDomain, (error as NSError).code == NSURLErrorCancelled { return }
            if (error as NSError).domain == WKError.errorDomain, (error as NSError).code == 102 { return } // frame load interrupted
            fail()
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url, url.scheme == "https" { UIApplication.shared.open(url) }
            return nil
        }
    }
}

/// Lets the user content controller hold the coordinator without keeping it alive.
@MainActor private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WalkthroughPlayer.Coordinator?
    init(_ target: WalkthroughPlayer.Coordinator) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.received(message)
    }
}
