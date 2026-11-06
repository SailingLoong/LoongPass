import Cocoa
import WebKit

/// Public captcha configuration only. Account credentials stay in the Dart owner.
/// SDK flow adapted from LoongPort / pjpv zcode-switch (MIT).
final class ZcodeCaptchaWindow: NSObject, WKScriptMessageHandler, NSWindowDelegate, WKNavigationDelegate {
    private var window: NSWindow?
    private var web: WKWebView?
    private var completion: ((String?) -> Void)?
    enum Failure: Error { case unavailable }

    static func configuration(_ input: [String: Any]) throws -> [String: String] {
        var output: [String: String] = [:]
        for name in ["region", "prefix", "sceneId"] {
            guard let value = input[name] as? String,
                  value.range(of: "^[a-zA-Z0-9._-]{1,128}$", options: .regularExpression) != nil else {
                throw Failure.unavailable
            }
            output[name] = value
        }
        return output
    }

    func present(_ input: [String: Any], parent: NSWindow, done: @escaping (String?) -> Void) throws {
        guard window == nil else { throw Failure.unavailable }
        let data = try JSONSerialization.data(withJSONObject: Self.configuration(input), options: [.sortedKeys])
        guard let config = String(data: data, encoding: .utf8) else { throw Failure.unavailable }
        let settings = WKWebViewConfiguration()
        settings.websiteDataStore = .nonPersistent()
        settings.userContentController.add(self, name: "zcodeVerification")
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 580, height: 460), configuration: settings)
        view.navigationDelegate = self
        let dialog = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        dialog.title = "ZCode 活动验证"
        dialog.isReleasedWhenClosed = false
        dialog.contentView = view
        dialog.delegate = self
        web = view; window = dialog; completion = done
        view.loadHTMLString(Self.page(config), baseURL: URL(string: "https://zcode.z.ai/"))
        parent.beginSheet(dialog)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              let body = message.body as? [String: String] else { return }
        if body["type"] == "cancel" { finish(nil); return }
        guard body["type"] == "proof", let proof = body["param"],
              !proof.isEmpty, proof.utf8.count <= 16384,
              !proof.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }) else { return }
        finish(proof)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.navigationType == .other &&
                        Self.allowsNavigation(navigationAction.request.url,
                            mainFrame: navigationAction.targetFrame?.isMainFrame != false) ? .allow : .cancel)
    }
    static func allowsNavigation(_ url: URL?, mainFrame: Bool) -> Bool {
        guard let url else { return false }
        if url.absoluteString == "about:blank" { return true }
        if mainFrame { return url.absoluteString == "https://zcode.z.ai/" }
        guard url.scheme == "https", let host = url.host,
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return false }
        return host.hasSuffix(".alicdn.com") || host.hasSuffix(".aliyuncs.com")
    }
    func windowWillClose(_ notification: Notification) { finish(nil) }
    private func finish(_ proof: String?) {
        guard let done = completion else { return }
        completion = nil
        web?.stopLoading()
        web?.configuration.userContentController.removeScriptMessageHandler(forName: "zcodeVerification")
        if let dialog = window {
            dialog.sheetParent?.endSheet(dialog)
            dialog.orderOut(nil); dialog.close()
        }
        web = nil; window = nil
        done(proof)
    }

    private static func page(_ config: String) -> String {
        """
        <!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval' https://*.alicdn.com; style-src 'unsafe-inline' https://*.alicdn.com; font-src data:; img-src data: blob: https://*.alicdn.com https://*.aliyuncs.com; connect-src https://*.alicdn.com https://*.aliyuncs.com; frame-src https://*.alicdn.com https://*.aliyuncs.com; worker-src blob:; base-uri 'none'; form-action 'none'">
        <style>body{font:16px -apple-system,sans-serif;padding:28px;color:#202124;background:#f7f8fa}button{font:inherit;border:0;border-radius:8px;padding:12px 20px;margin:8px 8px 8px 0;cursor:pointer}#start{background:#2463eb;color:white}p{line-height:1.6}</style></head>
        <body><h2>ZCode 活动验证</h2><p id="status">请完成官方验证码。验证后，LoongPass 将核对并领取本次活动。</p>
        <div id="captcha"></div><button id="start">开始验证</button><button id="verify" hidden>验证</button><button id="cancel">取消</button>
        <script>
        const config=\(config), status=document.getElementById('status'), start=document.getElementById('start');
        let submitted=false;
        const post=body=>window.webkit.messageHandlers.zcodeVerification.postMessage(body);
        document.getElementById('cancel').onclick=()=>post({type:'cancel'});
        start.onclick=async()=>{
          start.disabled=true;status.textContent='正在加载官方验证组件…';
          try {
            window.AliyunCaptchaConfig={region:config.region,prefix:config.prefix};
            await new Promise((resolve,reject)=>{const script=document.createElement('script');script.src='https://o.alicdn.com/captcha-frontend/aliyunCaptcha/AliyunCaptcha.js';script.onload=resolve;script.onerror=reject;document.head.appendChild(script);});
            const retry=()=>{status.textContent='请重新完成验证码，或取消后稍后重试。';document.getElementById('verify').hidden=false;};
            window.initAliyunCaptcha({SceneId:config.sceneId,mode:'popup',language:'zh-CN',showErrorTip:false,element:'#captcha',button:'#verify',
              getInstance:()=>{status.textContent='请完成验证码。';document.getElementById('verify').hidden=false;},
              success:value=>{const param=typeof value==='string'?value:value?.captchaVerifyParam;if(submitted||!param)return;submitted=true;post({type:'proof',param});},fail:retry,onError:retry});
            start.hidden=true;
            document.getElementById('verify').click();
          } catch {status.textContent='验证组件暂不可用，请取消后稍后重试。';}
        };
        </script></body></html>
        """
    }
}
