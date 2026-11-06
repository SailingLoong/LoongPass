import Foundation
import JavaScriptCore

@main struct ZcodeCaptchaChecks {
    static func main() throws {
        if CommandLine.arguments.contains("--page") {
            print(ZcodeCaptchaWindow.page("{\"region\":\"cn\",\"prefix\":\"example\",\"sceneId\":\"scene-1\"}"))
            return
        }
        let good: [String: Any] = ["region": "cn", "prefix": "example", "sceneId": "scene-1"]
        let config = try ZcodeCaptchaWindow.configuration(good)
        precondition(config.count == 3 && config["region"] == "cn")
        for invalid in ["</script>", "https://example.test", "", String(repeating: "a", count: 129)] {
            var value = good; value["prefix"] = invalid
            do { _ = try ZcodeCaptchaWindow.configuration(value); fatalError("invalid public config accepted") }
            catch ZcodeCaptchaWindow.Failure.unavailable {}
        }
        precondition(ZcodeCaptchaWindow.allowsNavigation(URL(string: "https://o.alicdn.com/captcha"), mainFrame: false))
        precondition(!ZcodeCaptchaWindow.allowsNavigation(URL(string: "https://o.alicdn.com/captcha"), mainFrame: true))
        for invalid in ["http://o.alicdn.com/captcha", "https://evilalicdn.com", "file:///tmp/private", "https://user@a.aliyuncs.com/"] {
            precondition(!ZcodeCaptchaWindow.allowsNavigation(URL(string: invalid), mainFrame: false))
        }
        let page = ZcodeCaptchaWindow.page("{\"region\":\"cn\",\"prefix\":\"example\",\"sceneId\":\"scene-1\"}")
        let source = page.components(separatedBy: "<script>")[1].components(separatedBy: "</script>")[0]
        let encoded = String(data: try JSONSerialization.data(withJSONObject: [source]), encoding: .utf8)!
        let context = JSContext()!
        context.exceptionHandler = { _, error in fatalError(error?.toString() ?? "JavaScript check failed") }
        context.evaluateScript("const source=\(encoded)[0];")
        context.evaluateScript(try String(contentsOfFile: "tool/zcode_captcha_page_checks.js", encoding: .utf8))
        let until = Date().addingTimeInterval(5)
        while !context.objectForKeyedSubscript("completed").toBool() && Date() < until {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(context.objectForKeyedSubscript("completed").toBool(), "SDK checks timed out")
        let failure = context.objectForKeyedSubscript("failure")!
        precondition(failure.isNull, failure.toString() ?? "SDK check failed")
        print("ZCode SDK auto verification and human continuation checks passed")
        print("ZCode captcha configuration and navigation checks passed")
    }
}
