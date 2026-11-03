import Foundation
@main struct DiagnosticsChecks {
    static func main() {
        var req = URLRequest(url: URL(string: "https://example.invalid/api/v1/fax")!)
        req.httpMethod = "POST"
        req.setValue("Bearer sfx_private123", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=SimuFax-test", forHTTPHeaderField: "Content-Type")
        let body = Data("--SimuFax-test\r\nContent-Disposition: form-data; name=\"sender\"\r\n\r\nO'Brien 中文\r\n--SimuFax-test\r\nContent-Disposition: form-data; name=\"file\"; filename=\"test.pdf\"\r\nContent-Type: application/octet-stream\r\n\r\nSECRET_FILE_BYTES\r\n--SimuFax-test--\r\n".utf8)
        var e = Exchange(request: req, body: body, fileName: "test.pdf", secret: "sfx_private123")
        precondition(!e.command.contains("sfx_private123") && !e.requestRaw.contains("sfx_private123"))
        precondition(!e.requestRaw.contains("SECRET_FILE_BYTES"))
        precondition(e.command.contains("--form-string") && e.command.contains("'\"'\"'"))
        precondition(e.requestRaw.contains("O'Brien 中文"))
        let response = HTTPURLResponse(url: req.url!, statusCode: 429, httpVersion: "HTTP/1.1", headerFields: ["Retry-After": "30", "Set-Cookie": "private-cookie"])!
        e.finish(Data("{\"ok\":false,\"error\":\"sfx_private123\"}".utf8), response, secret: "sfx_private123")
        precondition(e.status == 429 && e.duration != nil)
        precondition(!e.responseRaw.contains("sfx_private123") && !e.responseRaw.contains("private-cookie"))
        precondition(e.formattedResponse.contains("\n") && e.formattedResponse.contains("REDACTED"))
        var big = e
        big.finish(Data(repeating: 65, count: 300_000), response, secret: "")
        precondition(big.responseBody.utf8.count < 270_000)
        print("PASS: credential redaction, binary omission, multipart metadata, shell quoting, response status, JSON formatting, record size bound")
    }
}
