import Foundation

@main
enum DiagnosticsChecks {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("Diagnostic check failed: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        let scrubbed = Exchange.scrub("secret=sfx_ABC-123 token=topsecret", secret: "topsecret")
        expect(!scrubbed.contains("sfx_ABC-123"), "should redact SimuFax token-like values")
        expect(!scrubbed.contains("topsecret"), "should redact explicit secret value")
        expect(scrubbed.contains("<REDACTED>"), "should include redaction marker")

        let quoted = Exchange.quote("a'b")
        expect(quoted == "'a'\"'\"'b'", "single-quote escaping should match shell-safe format")

        var request = URLRequest(url: URL(string: "https://example.com/upload")!)
        request.httpMethod = "POST"
        request.setValue("******", forHTTPHeaderField: "Authorization")
        request.setValue("value", forHTTPHeaderField: "X-Custom")

        let exchange = Exchange(request: request, body: nil, fileName: nil, secret: "topsecret")
        expect(exchange.requestRaw.contains("Authorization: <REDACTED>"), "authorization header should be redacted")
        expect(!exchange.requestRaw.contains("topsecret"), "request dump should not expose secret")
        expect(exchange.command.contains("curl --request POST"), "command should include request method")
    }
}
