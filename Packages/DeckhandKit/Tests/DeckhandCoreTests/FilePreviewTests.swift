import Foundation
import Testing
@testable import DeckhandCore

@Suite struct FilePreviewTests {
    @Test func kinds() {
        #expect(FilePreview.kind(forFileName: "logo.PNG") == .image)
        #expect(FilePreview.kind(forFileName: "photo.jpeg") == .image)
        #expect(FilePreview.kind(forFileName: "invoice.pdf") == .pdf)
        #expect(FilePreview.kind(forFileName: "access.log") == .log)
        #expect(FilePreview.kind(forFileName: "error.log.1") == .log)
        #expect(FilePreview.kind(forFileName: "app.log.2026-11-13") == .log)
        #expect(FilePreview.kind(forFileName: "syslog") == .log)
        #expect(FilePreview.kind(forFileName: "syslog.1") == .log)
        #expect(FilePreview.kind(forFileName: "syslog.2.gz") == .text)
        #expect(FilePreview.kind(forFileName: "nginx.conf") == .text)
        #expect(FilePreview.kind(forFileName: "catalog.json") == .text)
    }

    @Test func follow() {
        #expect(FilePreview.followCommand("/var/log/nginx/access.log") == "tail -n 200 -F -- '/var/log/nginx/access.log' 2>&1")
        #expect(FilePreview.followCommand("/tmp/it's.log", lines: 0).contains(#"'/tmp/it'\''s.log'"#))
    }
}
