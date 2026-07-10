//! Arithmetic expression evaluator for `graff repl` — pure, allocation-free.
//! Offline fallback engine + the thing the headless tests exercise. Split
//! out of repl.zig (#123, 600-line goal); Parser is used only by eval()
//! here, so it stays private to this file.

const std = @import("std");

pub const EvalError = error{ SyntaxError, DivByZero, Overflow };

const Parser = struct {
    src: []const u8,
    pos: usize = 0,

    fn skipWs(self: *Parser) void {
        while (self.pos < self.src.len and (self.src[self.pos] == ' ' or
            self.src[self.pos] == '\t')) : (self.pos += 1)
        {}
    }
    fn peek(self: *Parser) ?u8 {
        self.skipWs();
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }
    fn expr(self: *Parser) EvalError!i64 {
        var acc = try self.term();
        while (self.peek()) |c| {
            if (c != '+' and c != '-') break;
            self.pos += 1;
            const rhs = try self.term();
            acc = if (c == '+') try std.math.add(i64, acc, rhs) else try std.math.sub(i64, acc, rhs);
        }
        return acc;
    }
    fn term(self: *Parser) EvalError!i64 {
        var acc = try self.factor();
        while (self.peek()) |c| {
            if (c != '*' and c != '/' and c != '%') break;
            self.pos += 1;
            const rhs = try self.factor();
            switch (c) {
                '*' => acc = try std.math.mul(i64, acc, rhs),
                '/' => {
                    if (rhs == 0) return error.DivByZero;
                    if (acc == std.math.minInt(i64) and rhs == -1) return error.Overflow;
                    acc = @divTrunc(acc, rhs);
                },
                else => {
                    if (rhs == 0) return error.DivByZero;
                    if (acc == std.math.minInt(i64) and rhs == -1) return error.Overflow;
                    acc = @rem(acc, rhs);
                },
            }
        }
        return acc;
    }
    fn factor(self: *Parser) EvalError!i64 {
        const c = self.peek() orelse return error.SyntaxError;
        if (c == '-') {
            self.pos += 1;
            return std.math.negate(try self.factor()) catch error.Overflow;
        }
        if (c == '+') {
            self.pos += 1;
            return self.factor();
        }
        if (c == '(') {
            self.pos += 1;
            const v = try self.expr();
            if (self.peek() != @as(?u8, ')')) return error.SyntaxError;
            self.pos += 1;
            return v;
        }
        if (!std.ascii.isDigit(c)) return error.SyntaxError;
        const start = self.pos;
        while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) : (self.pos += 1) {}
        return std.fmt.parseInt(i64, self.src[start..self.pos], 10) catch error.Overflow;
    }
};

pub fn eval(src: []const u8) EvalError!i64 {
    var p = Parser{ .src = src };
    const v = try p.expr();
    if (p.peek() != null) return error.SyntaxError;
    return v;
}

test "eval: precedence and parentheses" {
    try std.testing.expectEqual(@as(i64, 14), try eval("2 + 3 * 4"));
    try std.testing.expectEqual(@as(i64, 20), try eval("(2 + 3) * 4"));
    try std.testing.expectEqual(@as(i64, -6), try eval("-(2 * 3)"));
    try std.testing.expectEqual(@as(i64, 2), try eval("7 / 3"));
    try std.testing.expectEqual(@as(i64, 1), try eval("7 % 3"));
}

test "eval: error cases" {
    try std.testing.expectError(error.DivByZero, eval("1 / 0"));
    try std.testing.expectError(error.SyntaxError, eval("2 +"));
    try std.testing.expectError(error.SyntaxError, eval("2 2"));
    try std.testing.expectError(error.Overflow, eval("9223372036854775807 + 1"));
}
