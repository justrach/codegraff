//! #883 edge cases use private named pasteboards, never the general clipboard.
const std = @import("std");
const clip = @import("vision_clipboard.zig");
const native = @import("clipboard_native.zig");
const runner = @import("process_runner.zig");

const setup =
    \\ObjC.import('AppKit');
    \\function run(argv) {
    \\ const pb=$.NSPasteboard.pasteboardWithName(argv[0]); pb.clearContents;
    \\ const kind=argv[1];
    \\ const png=$.NSData.alloc.initWithBase64EncodedStringOptions('iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGP4z8AARAwQCgAf7gP9i18U1AAAAABJRU5ErkJggg==',0);
    \\ const broken=$('not an image').dataUsingEncoding($.NSUTF8StringEncoding);
    \\ function put(types, values) {
    \\  pb.declareTypesOwner($(types),null);
    \\  for(let i=0;i<types.length;i++) {
    \\   const ok=typeof values[i]==='string'?pb.setStringForType(values[i],types[i]):pb.setDataForType(values[i],types[i]);
    \\   if(!ok) throw Error('fixture flavor write failed');
    \\  }
    \\ }
    \\ if(kind==='mixed') put(['public.utf8-plain-text','public.png'],['fixture text',png]);
    \\ else if(kind==='alternate') {
    \\  const image=$.NSImage.alloc.initWithData(png);
    \\  put(['public.png','public.tiff'],[broken,image.TIFFRepresentation]);
    \\ } else if(kind==='corrupt-text') put(['public.png','public.utf8-plain-text'],[broken,'fixture text']);
    \\ else if(kind==='unsupported') put(['org.example.clipboard-edge-unsupported'],[png]);
    \\ else if(kind==='unsupported-text') put(['public.html','public.utf8-plain-text'],['<b>fixture</b>','fixture']);
    \\ else if(kind==='remote') put(['public.file-url'],['https://example.invalid/image.png']);
    \\ else if(kind==='filenames'||kind==='filenames-alternate') {
    \\  if(!png.writeToFileAtomically(argv[2],true)) throw Error('fixture file write failed');
    \\  const declared=kind==='filenames-alternate'?['public.tiff','NSFilenamesPboardType']:['NSFilenamesPboardType'];
    \\  pb.declareTypesOwner($(declared),null);
    \\  if(kind==='filenames-alternate' && !pb.setDataForType(broken,'public.tiff')) throw Error('fixture flavor write failed');
    \\  if(!pb.setPropertyListForType([argv[2]],'NSFilenamesPboardType')) throw Error('fixture flavor write failed');
    \\ } else {
    \\  if(kind!=='missing') {
    \\   const data=kind==='nonimage'||kind==='nonimage-png'?broken:png;
    \\   if(!data.writeToFileAtomically(argv[2],true)) throw Error('fixture file write failed');
    \\  }
    \\  const url=ObjC.unwrap($.NSURL.fileURLWithPath(argv[2]).absoluteString);
    \\  if(kind==='file-alternate') put(['public.png','public.file-url'],[broken,url]);
    \\  else put(['public.file-url'],[url]);
    \\ }
    \\ return 'ready';
    \\}
;

const cleanup =
    \\ObjC.import('AppKit');
    \\function run(argv) { $.NSPasteboard.pasteboardWithName(argv[0]).releaseGlobally; }
;

fn releaseBoard(board: []const u8) void {
    const gpa = std.testing.allocator;
    const r = runner.runCapped(gpa, std.testing.io, &.{ "/usr/bin/osascript", "-l", "JavaScript", "-e", cleanup, board }, 64, 2048, 5000) catch return;
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
}

test "#883 named pasteboard edge cases mixed flavors alternate images file URLs and unsupported types" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const Expected = enum { png, furl, empty, convert };
    const Case = struct {
        kind: []const u8,
        ext: []const u8 = "png",
        expected: Expected,
        source_png: bool = false,
    };
    const cases = [_]Case{
        .{ .kind = "mixed", .expected = .png },
        .{ .kind = "alternate", .expected = .png },
        .{ .kind = "corrupt-text", .expected = .convert },
        .{ .kind = "file", .ext = "space # percent% quote' double\" café 雪.PNG", .expected = .furl, .source_png = true },
        .{ .kind = "file-alternate", .expected = .furl, .source_png = true },
        .{ .kind = "file", .ext = "cache", .expected = .furl, .source_png = true },
        .{ .kind = "filenames", .expected = .furl, .source_png = true },
        .{ .kind = "filenames-alternate", .expected = .furl, .source_png = true },
        .{ .kind = "missing", .expected = .convert },
        .{ .kind = "nonimage", .ext = "txt", .expected = .empty },
        .{ .kind = "nonimage-png", .expected = .convert },
        .{ .kind = "unsupported-file", .ext = "unsupported", .expected = .furl, .source_png = true },
        .{ .kind = "remote", .expected = .empty },
        .{ .kind = "unsupported", .expected = .empty },
        .{ .kind = "unsupported-text", .expected = .empty },
    };
    for (cases) |case| {
        const board = clip.tempPath(io, gpa, "pasteboard") orelse return error.OutOfMemory;
        defer gpa.free(board);
        defer releaseBoard(board);
        const source = clip.tempPath(io, gpa, case.ext) orelse return error.OutOfMemory;
        defer clip.discard(io, gpa, source);
        const r = try runner.runCapped(gpa, io, &.{ "/usr/bin/osascript", "-l", "JavaScript", "-e", setup, board, case.kind, source }, 64, 2048, 5000);
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        try std.testing.expect(runner.ranOk(r));
        try std.testing.expectEqualStrings("ready", std.mem.trim(u8, r.stdout, " \r\n"));
        const got = native.grab(io, gpa, board);
        defer if (got == .ok) got.ok.release(io, gpa);
        const matches = switch (case.expected) {
            .empty => got == .empty,
            .convert => got == .failed and got.failed == .convert,
            .png => got == .ok and got.ok.flavor == .png,
            .furl => got == .ok and got.ok.flavor == .furl,
        };
        if (!matches) std.debug.print("clipboard edge case {s}: expected {s}, got {s} {s}\n", .{
            case.kind,
            @tagName(case.expected),
            @tagName(got),
            switch (got) {
                .failed => |k| @tagName(k),
                .ok => |g| g.flavor.name(),
                else => "",
            },
        });
        try std.testing.expect(matches);
        if (got == .ok) {
            try std.testing.expect(got.ok.owned);
            try std.testing.expect(clip.looksLikePng(io, got.ok.path));
            try std.testing.expect(!std.mem.eql(u8, source, got.ok.path));
        }
        if (case.source_png) try std.testing.expect(clip.looksLikePng(io, source));
        if (std.mem.eql(u8, case.kind, "missing")) try std.testing.expect(clip.regularFileSize(io, source) == null);
        if (std.mem.startsWith(u8, case.kind, "nonimage")) try std.testing.expectEqual(@as(?u64, 12), clip.regularFileSize(io, source));
    }
}
