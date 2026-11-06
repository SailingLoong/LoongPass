import Foundation

@main struct ZcodeCaptchaChecks {
    static func main() throws {
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
        print("ZCode captcha configuration and navigation checks passed")
    }
}
