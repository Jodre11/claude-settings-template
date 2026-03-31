#!/usr/bin/env swift
// html2clip — copies HTML from stdin to the macOS clipboard as rich text.
// Teams, Slack, Outlook etc. read the HTML pasteboard type and render it.

import Cocoa

let data = FileHandle.standardInput.readDataToEndOfFile()
guard !data.isEmpty else {
    fputs("Usage: echo '<p>Hello</p>' | html2clip\n", stderr)
    exit(1)
}

let pb = NSPasteboard.general
pb.clearContents()
pb.setData(data, forType: .html)

let charCount = String(data: data, encoding: .utf8)?.count ?? data.count
fputs("Copied \(charCount) bytes of HTML to clipboard.\n", stderr)
