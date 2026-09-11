//! Direct pasteboard flavors avoid AppleScript's lossy PNGf coercion (#843).
const std = @import("std");
const clip = @import("vision_clipboard.zig");
const runner = @import("process_runner.zig");
pub const script = @embedFile("clipboard_export.js");

pub fn grab(io: std.Io, gpa: std.mem.Allocator, board: []const u8) clip.GrabAttempt {
    if (@import("builtin").os.tag != .macos) return .empty;
    const path = clip.tempPath(io, gpa, "png") orelse return .{ .failed = .access };
    var keep = false;
    defer if (!keep) clip.discard(io, gpa, path);
    // Retry only when the clipboard changed during the read. Promised flavors
    // can take time to materialize, but cannot block a paste indefinitely.
    for (0..2) |_| {
        const r = runner.runCapped(gpa, io, &.{ "/usr/bin/osascript", "-l", "JavaScript", "-e", script, path, board }, 64, 1024, 5000) catch return .{ .failed = .access };
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        if (!runner.ranOk(r) or r.stdout_truncated) return .{ .failed = .access };
        const status = std.mem.trim(u8, r.stdout, " \r\n");
        if (std.mem.eql(u8, status, "changed")) continue;
        if (std.mem.eql(u8, status, "empty")) return .empty;
        if (std.mem.eql(u8, status, "convert")) return .{ .failed = .convert };
        if (!std.mem.startsWith(u8, status, "ok:")) return .{ .failed = .extract };
        if (!clip.looksLikePng(io, path)) return .{ .failed = .extract };
        const flavor = std.meta.stringToEnum(clip.Flavor, status[3..]) orelse return .{ .failed = .extract };
        keep = true;
        return .{ .ok = .{ .path = path, .flavor = flavor, .owned = true } };
    }
    return .{ .failed = .access };
}

test "#843 real named pasteboards export PNG TIFF JPEG file URLs and distinguish invalid data" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const board = clip.tempPath(io, gpa, "pasteboard") orelse return error.OutOfMemory;
    defer gpa.free(board);
    const source = clip.tempPath(io, gpa, "png") orelse return error.OutOfMemory;
    defer clip.discard(io, gpa, source);
    const setup =
        \\ObjC.import('AppKit');
        \\function run(argv) {
        \\ const pb=$.NSPasteboard.pasteboardWithName(argv[0]); pb.clearContents;
        \\ if(argv[1]==='empty') return 'ready';
        \\ if(argv[1]==='text') {pb.setStringForType('fixture','public.utf8-plain-text');return 'ready';}
        \\ if(argv[1]==='invalid') {pb.setDataForType($('broken').dataUsingEncoding($.NSUTF8StringEncoding),'public.png');return 'ready';}
        \\ const png=$.NSData.alloc.initWithBase64EncodedStringOptions('iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGP4z8AARAwQCgAf7gP9i18U1AAAAABJRU5ErkJggg==',0);
        \\ if(argv[1]==='pdf') {pb.setDataForType($.NSData.alloc.initWithBase64EncodedStringOptions('JVBERi0xLjQKMSAwIG9iago8PCAvVHlwZSAvQ2F0YWxvZyAvUGFnZXMgMiAwIFIgPj4KZW5kb2JqCjIgMCBvYmoKPDwgL1R5cGUgL1BhZ2VzIC9LaWRzIFszIDAgUl0gL0NvdW50IDEgPj4KZW5kb2JqCjMgMCBvYmoKPDwgL1R5cGUgL1BhZ2UgL1BhcmVudCAyIDAgUiAvTWVkaWFCb3ggWzAgMCA0IDRdIC9Db250ZW50cyA0IDAgUiA+PgplbmRvYmoKNCAwIG9iago8PCAvTGVuZ3RoIDI0ID4+CnN0cmVhbQoxIDAgMCByZyAwIDAgNCA0IHJlIGYKZW5kc3RyZWFtCmVuZG9iagp4cmVmCjAgNQowMDAwMDAwMDAwIDY1NTM1IGYgCjAwMDAwMDAwMDkgMDAwMDAgbiAKMDAwMDAwMDA1OCAwMDAwMCBuIAowMDAwMDAwMTE1IDAwMDAwIG4gCjAwMDAwMDAxOTggMDAwMDAgbiAKdHJhaWxlcgo8PCAvU2l6ZSA1IC9Sb290IDEgMCBSID4+CnN0YXJ0eHJlZgoyNjkKJSVFT0YK',0),'com.adobe.pdf');return 'ready';}
        \\ if(argv[1]==='furl') {png.writeToFileAtomically(argv[2],true);pb.setStringForType($.NSURL.fileURLWithPath(argv[2]).absoluteString,'public.file-url');return 'ready';}
        \\ const image=$.NSImage.alloc.initWithData(png);
        \\ const bitmap=$.NSBitmapImageRep.imageRepWithData(image.TIFFRepresentation);
        \\ const data=argv[1]==='tiff'?image.TIFFRepresentation:argv[1]==='jpeg'?bitmap.representationUsingTypeProperties($.NSBitmapImageFileTypeJPEG,$({})):png;
        \\ pb.setDataForType(data,argv[1]==='tiff'?'public.tiff':argv[1]==='jpeg'?'public.jpeg':'public.png'); return 'ready';
        \\}
    ;
    for ([_][]const u8{ "png", "tiff", "jpeg", "pdf", "furl", "invalid", "text", "empty" }) |kind| {
        const r = try runner.runCapped(gpa, io, &.{ "/usr/bin/osascript", "-l", "JavaScript", "-e", setup, board, kind, source }, 64, 2048, 5000);
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        try std.testing.expect(runner.ranOk(r));
        const got = grab(io, gpa, board);
        if (std.mem.eql(u8, kind, "invalid")) {
            try std.testing.expect(got == .failed and got.failed == .convert);
        } else if (std.mem.eql(u8, kind, "text") or std.mem.eql(u8, kind, "empty")) {
            try std.testing.expect(got == .empty);
        } else {
            try std.testing.expect(got == .ok);
            defer got.ok.release(io, gpa);
            try std.testing.expect(clip.looksLikePng(io, got.ok.path));
            try std.testing.expect(got.ok.owned);
            if (std.mem.eql(u8, kind, "furl")) try std.testing.expect(clip.looksLikePng(io, source));
        }
    }
}
