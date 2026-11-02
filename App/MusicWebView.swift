import SwiftUI
import WebKit

enum Config {
    static let startURL = URL(string: "https://music.youtube.com/")!

    /// User agent do Safari no iOS. O UA padrão do WKWebView não tem "Safari/...",
    /// e é por isso que o Google bloqueia o login ("este navegador pode não ser seguro").
    /// Se der problema, troque por `desktopUserAgent`.
    static var userAgent: String {
        let v = UIDevice.current.systemVersion            // ex.: "18.1"
        let osToken = v.replacingOccurrences(of: ".", with: "_")
        let major = v.split(separator: ".").first.map(String.init) ?? "18"
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(osToken) like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(major).0 Mobile/15E148 Safari/604.1"
    }

    static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
}

struct MusicWebView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Armazenamento persistente: cookies/login sobrevivem entre aberturas do app.
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = true

        let content = config.userContentController
        content.addUserScript(WKUserScript(source: Scripts.keepAlive,
                                           injectionTime: .atDocumentStart,
                                           forMainFrameOnly: true))
        if let css = Scripts.load("custom", "css") {
            content.addUserScript(WKUserScript(source: Scripts.styleInjector(css),
                                               injectionTime: .atDocumentStart,
                                               forMainFrameOnly: true))
        }
        if let js = Scripts.load("custom", "js") {
            content.addUserScript(WKUserScript(source: js,
                                               injectionTime: .atDocumentEnd,
                                               forMainFrameOnly: true))
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = Config.userAgent
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.load(URLRequest(url: Config.startURL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        // Bloqueia esquemas que abririam o app oficial (youtubemusic://, intent://, itms-apps:// ...).
        func webView(_ webView: WKWebView,
                     decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let scheme = action.request.url?.scheme?.lowercased() ?? ""
            let allowed = ["http", "https", "about", "blob", "data", "javascript"]
            guard allowed.contains(scheme) else {
                print("Navegação bloqueada: \(action.request.url?.absoluteString ?? "")")
                decisionHandler(.cancel)
                return
            }
            // Links com target=_blank abrem na mesma view.
            if action.targetFrame == nil {
                webView.load(action.request)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        // Popups (window.open, usados em alguns fluxos de login) abrem na mesma view.
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            webView.load(action.request)
            return nil
        }

        // Se o processo da página morrer em segundo plano, recarrega.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webView.reload()
        }
    }
}

enum Scripts {
    static func load(_ name: String, _ ext: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Inject"),
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }

    static func styleInjector(_ css: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [css])
        let literal = String(data: data, encoding: .utf8)!   // ["..."] já escapado
        return """
        (function () {
          var css = \(literal)[0];
          function add() {
            if (document.getElementById('bytm-custom-css')) return;
            var s = document.createElement('style');
            s.id = 'bytm-custom-css';
            s.textContent = css;
            (document.head || document.documentElement).appendChild(s);
          }
          if (document.documentElement) add();
          else document.addEventListener('DOMContentLoaded', add);
        })();
        """
    }

    /// Faz o site achar que continua visível, para não pausar a música
    /// quando o app vai para segundo plano ou a tela é bloqueada.
    static let keepAlive = """
    (function () {
      try {
        Object.defineProperty(document, 'hidden', { get: function () { return false; } });
        Object.defineProperty(document, 'visibilityState', { get: function () { return 'visible'; } });
        Object.defineProperty(document, 'webkitVisibilityState', { get: function () { return 'visible'; } });
      } catch (e) {}
      ['visibilitychange', 'webkitvisibilitychange'].forEach(function (t) {
        document.addEventListener(t, function (e) { e.stopImmediatePropagation(); }, true);
      });
    })();
    """
}
