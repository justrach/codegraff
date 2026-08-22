//! The Windows console/pipe API shim: the kernel32 externs and the ABI structs
//! the harness needs, and nothing else. A std/builtin leaf with no imports at
//! all, so a caller may reach for one syscall without taking a dependency it
//! does not want.
//!
//! Split out of term.zig (#422/#429): the shim lived inside the terminal
//! module, so hooks.zig — which wants exactly ONE call, PeekNamedPipe, to poll
//! a child's stderr pipe — had to import the terminal cluster to get it.
//! term.zig keeps `pub const win = @import("win_api.zig")`, so its own call
//! sites are unchanged; the declarations are `pub` because they now cross a
//! file boundary, not because anything else should reach for them.

pub const HANDLE = *anyopaque;
pub const BOOL = i32;
pub const DWORD = u32;
pub const UINT = u32;
pub const WORD = u16;
pub const WCHAR = u16;
pub const SHORT = i16;

/// UTF-8. PowerShell 5.1/conhost default to CP437/1252, which turns box-drawing
/// and icons into mojibake (#607). zigzag already switches; the line REPL did not.
pub const CP_UTF8: UINT = 65001;

pub const STD_INPUT_HANDLE: DWORD = 0xFFFFFFF6; // (DWORD)-10
pub const STD_OUTPUT_HANDLE: DWORD = 0xFFFFFFF5; // (DWORD)-11

pub const ENABLE_PROCESSED_INPUT: DWORD = 0x0001;
pub const ENABLE_LINE_INPUT: DWORD = 0x0002;
pub const ENABLE_ECHO_INPUT: DWORD = 0x0004;
pub const ENABLE_VIRTUAL_TERMINAL_INPUT: DWORD = 0x0200;
pub const ENABLE_PROCESSED_OUTPUT: DWORD = 0x0001;
pub const ENABLE_VIRTUAL_TERMINAL_PROCESSING: DWORD = 0x0004;

pub const WAIT_OBJECT_0: DWORD = 0x0;
pub const INFINITE: DWORD = 0xFFFFFFFF;
pub const KEY_EVENT: WORD = 0x0001;

pub const COORD = extern struct { X: SHORT, Y: SHORT };
pub const SMALL_RECT = extern struct { Left: SHORT, Top: SHORT, Right: SHORT, Bottom: SHORT };
pub const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
    dwSize: COORD,
    dwCursorPosition: COORD,
    wAttributes: WORD,
    srWindow: SMALL_RECT,
    dwMaximumWindowSize: COORD,
};
pub const KEY_EVENT_RECORD = extern struct {
    bKeyDown: BOOL,
    wRepeatCount: WORD,
    wVirtualKeyCode: WORD,
    wVirtualScanCode: WORD,
    UnicodeChar: WCHAR,
    dwControlKeyState: DWORD,
};
// EventType (WORD) + ABI padding + the 16-byte event union, modeled as its
// largest relevant member (KEY_EVENT_RECORD), totals 20 bytes — the C size.
pub const INPUT_RECORD = extern struct {
    EventType: WORD,
    KeyEvent: KEY_EVENT_RECORD,
};

pub extern "kernel32" fn GetStdHandle(nStdHandle: DWORD) callconv(.winapi) HANDLE;
pub extern "kernel32" fn GetConsoleMode(hConsoleHandle: HANDLE, lpMode: *DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetConsoleMode(hConsoleHandle: HANDLE, dwMode: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetConsoleScreenBufferInfo(hConsoleOutput: HANDLE, lpInfo: *CONSOLE_SCREEN_BUFFER_INFO) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetNumberOfConsoleInputEvents(hConsoleInput: HANDLE, lpNumberOfEvents: *DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn ReadConsoleInputW(hConsoleInput: HANDLE, lpBuffer: [*]INPUT_RECORD, nLength: DWORD, lpRead: *DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn PeekNamedPipe(hNamedPipe: HANDLE, lpBuffer: ?*anyopaque, nBufferSize: DWORD, lpBytesRead: ?*DWORD, lpTotalBytesAvail: ?*DWORD, lpBytesLeftThisMessage: ?*DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) UINT;
pub extern "kernel32" fn SetConsoleOutputCP(wCodePageID: UINT) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetConsoleCP() callconv(.winapi) UINT;
pub extern "kernel32" fn SetConsoleCP(wCodePageID: UINT) callconv(.winapi) BOOL;
