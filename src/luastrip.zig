const std = @import("std");

pub const StripError = error{
    UnterminatedString,
    UnterminatedLongBracket,
    UnterminatedComment,
};

/// Strip a Lua source file from disk and write the result to `output`.
/// Both paths must be NUL-terminated. The caller owns `allocator`.
pub fn file(io: std.Io, input: [:0]const u8, output: [:0]const u8, allocator: std.mem.Allocator) !void {
    var input_file = try std.Io.Dir.cwd().openFile(io, input, .{});
    defer input_file.close(io);

    const file_size = (try input_file.stat(io)).size;
    const data = try allocator.alloc(u8, file_size);
    defer allocator.free(data);

    var buffer: [1024]u8 = undefined;
    var reader_if = input_file.reader(io, &buffer);
    const reader = &reader_if.interface;
    _ = try reader.readSliceAll(data);

    const stripped = try strip(data, allocator);
    defer allocator.free(stripped);

    var output_file = try std.Io.Dir.cwd().createFile(io, output, .{});
    defer output_file.close(io);

    var writer_if = output_file.writer(io, &buffer);
    const writer = &writer_if.interface;

    _ = try writer.write(stripped);
    try writer.flush();
}

/// Remove unnecessary whitespace and comments from Lua source code.
///
/// The returned slice is newly allocated and must be freed by the caller.
/// Malformed input (an unterminated string, long string or long comment)
/// returns an error instead of producing corrupt output.
pub fn strip(source: []const u8, allocator: std.mem.Allocator) (StripError || std.mem.Allocator.Error)![]const u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, source.len);
    errdefer out.deinit(allocator);

    var start: usize = 0;
    // Lua ignores a first line starting with '#'. Keep it verbatim so that
    // executable scripts stay executable after stripping.
    if (source.len > 0 and source[0] == '#') {
        const end = if (std.mem.indexOfScalar(u8, source, '\n')) |newline| newline + 1 else source.len;
        try out.appendSlice(allocator, source[0..end]);
        start = end;
    }

    var tokenizer = try Tokenizer.init(source[start..]);
    var token = try tokenizer.next();
    while (token.kind != .eof) {
        try out.appendSlice(allocator, token.text);
        if (needsSpace(token, tokenizer.peek)) {
            try out.append(allocator, ' ');
        }
        token = try tokenizer.next();
    }

    return out.toOwnedSlice(allocator);
}

/// Returns true when removing the whitespace between two tokens would change
/// how Lua lexes the result.
fn needsSpace(previous: Token, next: Token) bool {
    if (previous.kind == .eof or next.kind == .eof) {
        return false;
    }

    // Two word-like tokens ("local a", "1 local") must stay separated.
    if ((previous.kind == .name or previous.kind == .number) and
        (next.kind == .name or next.kind == .number))
    {
        return true;
    }

    // A numeral immediately followed by ".." or "..." is a malformed number.
    if (previous.kind == .number and next.text[0] == '.') {
        return true;
    }

    const last = previous.text[previous.text.len - 1];
    const first = next.text[0];
    // Never create "--" (a comment), "[["/" [=[" (a long bracket) or a
    // ".."/"..." token by gluing separate tokens together.
    return (last == '-' and first == '-') or
        (last == '[' and first == '[') or
        (last == '.' and first == '.');
}

const TokenKind = enum {
    eof,
    name,
    number,
    string,
    symbol,
};

const Token = struct {
    text: []const u8,
    kind: TokenKind,
};

const Tokenizer = struct {
    data: []const u8,
    pos: usize = 0,
    peek: Token = .{ .text = "", .kind = .eof },

    pub fn init(data: []const u8) !Tokenizer {
        var self: Tokenizer = .{ .data = data };
        self.peek = try self.next_token();
        return self;
    }

    pub fn next(self: *Tokenizer) !Token {
        const token = self.peek;
        self.peek = try self.next_token();
        return token;
    }

    fn next_token(self: *Tokenizer) !Token {
        const data = self.data;

        while (self.pos < data.len) {
            switch (data[self.pos]) {
                ' ', '\t', '\r', '\n', 0x0b, 0x0c => self.pos += 1,
                else => break,
            }
        }
        if (self.pos >= data.len) {
            return .{ .text = "", .kind = .eof };
        }

        const start = self.pos;
        switch (data[self.pos]) {
            '-' => {
                if (self.pos + 1 < data.len and data[self.pos + 1] == '-') {
                    const block_len = blockLen(data[self.pos + 2 ..]) catch return error.UnterminatedComment;
                    if (block_len) |len| {
                        self.pos += 2 + len;
                    } else {
                        while (self.pos < data.len and data[self.pos] != '\n' and data[self.pos] != '\r') {
                            self.pos += 1;
                        }
                    }
                    return self.next_token();
                }
                self.pos += 1;
                return .{ .text = data[start..self.pos], .kind = .symbol };
            },
            '\'', '"' => return self.scanString(data[self.pos]),
            '[' => {
                if (try blockLen(data[self.pos..])) |len| {
                    self.pos += len;
                    return .{ .text = data[start..self.pos], .kind = .string };
                }
                self.pos += 1;
                return .{ .text = data[start..self.pos], .kind = .symbol };
            },
            '.' => {
                if (self.pos + 1 < data.len and data[self.pos + 1] == '.') {
                    if (self.pos + 2 < data.len and data[self.pos + 2] == '.') {
                        self.pos += 3;
                    } else {
                        self.pos += 2;
                    }
                    return .{ .text = data[start..self.pos], .kind = .symbol };
                }
                if (self.pos + 1 < data.len and isDigit(data[self.pos + 1])) {
                    return self.scanNumber();
                }
                self.pos += 1;
                return .{ .text = data[start..self.pos], .kind = .symbol };
            },
            '0'...'9' => return self.scanNumber(),
            '_', 'a'...'z', 'A'...'Z' => {
                self.pos += 1;
                while (self.pos < data.len and isNameChar(data[self.pos])) {
                    self.pos += 1;
                }
                return .{ .text = data[start..self.pos], .kind = .name };
            },
            else => {
                self.pos += 1;
                return .{ .text = data[start..self.pos], .kind = .symbol };
            },
        }
    }

    fn scanString(self: *Tokenizer, quote: u8) !Token {
        const data = self.data;
        const start = self.pos;
        var pos = self.pos + 1;
        while (pos < data.len) {
            if (data[pos] == '\\') {
                pos += 2;
                continue;
            }
            if (data[pos] == quote) {
                self.pos = pos + 1;
                return .{ .text = data[start..self.pos], .kind = .string };
            }
            pos += 1;
        }
        return error.UnterminatedString;
    }

    fn scanNumber(self: *Tokenizer) Token {
        const data = self.data;
        const start = self.pos;

        if (self.pos + 1 < data.len and data[self.pos] == '0' and
            (data[self.pos + 1] == 'x' or data[self.pos + 1] == 'X'))
        {
            self.pos += 2;
            while (self.pos < data.len and isHexDigit(data[self.pos])) {
                self.pos += 1;
            }
            if (self.pos < data.len and data[self.pos] == '.') {
                self.pos += 1;
                while (self.pos < data.len and isHexDigit(data[self.pos])) {
                    self.pos += 1;
                }
            }
            if (self.pos < data.len and (data[self.pos] == 'p' or data[self.pos] == 'P')) {
                self.pos += 1;
                if (self.pos < data.len and (data[self.pos] == '+' or data[self.pos] == '-')) {
                    self.pos += 1;
                }
                while (self.pos < data.len and isDigit(data[self.pos])) {
                    self.pos += 1;
                }
            }
        } else {
            while (self.pos < data.len and isDigit(data[self.pos])) {
                self.pos += 1;
            }
            if (self.pos < data.len and data[self.pos] == '.') {
                self.pos += 1;
                while (self.pos < data.len and isDigit(data[self.pos])) {
                    self.pos += 1;
                }
            }
            if (self.pos < data.len and (data[self.pos] == 'e' or data[self.pos] == 'E')) {
                self.pos += 1;
                if (self.pos < data.len and (data[self.pos] == '+' or data[self.pos] == '-')) {
                    self.pos += 1;
                }
                while (self.pos < data.len and isDigit(data[self.pos])) {
                    self.pos += 1;
                }
            }
        }

        return .{ .text = data[start..self.pos], .kind = .number };
    }
};

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isHexDigit(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn isNameChar(c: u8) bool {
    return c == '_' or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or isDigit(c);
}

/// Returns the length of the long bracket starting at `data[0]`, or null when
/// `data` does not start with a long bracket. An opening long bracket without
/// a matching closing bracket is an error.
fn blockLen(data: []const u8) error{UnterminatedLongBracket}!?usize {
    if (data.len < 2 or data[0] != '[') {
        return null;
    }

    var equals: usize = 0;
    while (1 + equals < data.len and data[1 + equals] == '=') : (equals += 1) {}
    if (1 + equals >= data.len or data[1 + equals] != '[') {
        return null;
    }

    const open_len = equals + 2;
    var pos = open_len;
    while (pos + equals + 1 < data.len) : (pos += 1) {
        if (data[pos] != ']') {
            continue;
        }
        if (std.mem.eql(u8, data[pos + 1 .. pos + 1 + equals], data[1 .. 1 + equals]) and
            data[pos + 1 + equals] == ']')
        {
            return pos + equals + 2;
        }
    }

    return error.UnterminatedLongBracket;
}

const testing = std.testing;

fn expectStrip(input: []const u8, expected: []const u8) !void {
    const output = try strip(input, testing.allocator);
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(expected, output);
}

fn expectToken(tokenizer: *Tokenizer, expected: []const u8) !void {
    const token = try tokenizer.next();
    try testing.expectEqualStrings(expected, token.text);
}

fn expectEnd(tokenizer: *Tokenizer) !void {
    const token = try tokenizer.next();
    try testing.expect(token.kind == .eof);
}

test "strip just whitespaces" {
    try expectStrip("  \r\n\t \r \n \t\t ", "");
}

test "strip simple expression - not changed" {
    try expectStrip("local a=1", "local a=1");
}

test "strip simple expression - whitespace removed" {
    try expectStrip("\t local\t a = 1 \n", "local a=1");
}

test "strip bigger script" {
    const input =
        "\r\n " ++
        " -- Some bigger script \n" ++
        " \n\n " ++
        "\tlocal a = \t1\n" ++
        "   local   b =   2\n\n" ++
        " --[[ Big Block of comment \n" ++
        "      should be removed  \n" ++
        "]]" ++
        "print ( 'result =\\''  ..  \n( a + b ) ..\n '\\'') \r\n   \n";
    try expectStrip(input, "local a=1 local b=2 print('result =\\''..(a+b)..'\\'')");
}

test "operators that are not in the punctuation set do not overflow" {
    try expectStrip("a<b", "a<b");
    try expectStrip("a<=b", "a<=b");
    try expectStrip("a>b", "a>b");
    try expectStrip("a%b", "a%b");
    try expectStrip("a^b", "a^b");
    try expectStrip("a&b", "a&b");
    try expectStrip("a|b", "a|b");
}

test "do not create a line comment" {
    try expectStrip("print(3 - -2)", "print(3- -2)");
    try expectStrip("a - --[[comment]] -b", "a- -b");
}

test "do not create a malformed number" {
    try expectStrip("print(1 .. 2)", "print(1 ..2)");
    try expectStrip("print(1 .. .5)", "print(1 .. .5)");
    try expectStrip("print(0x1 .. 2)", "print(0x1 ..2)");
}

test "do not create a long bracket" {
    try expectStrip("print(t[ [[x]] ])", "print(t[ [[x]]])");
    try expectStrip("print(t[ [=[x]=] ])", "print(t[ [=[x]=]])");
    try expectStrip("local a = {[ [[k]] ]=true}", "local a={[ [[k]]]=true}");
}

test "decimals and exponents stay intact" {
    try expectStrip("local a = 1.5", "local a=1.5");
    try expectStrip("local a = 1.5e-3", "local a=1.5e-3");
    try expectStrip("local a = .5", "local a=.5");
    try expectStrip("local a = 0x1p4", "local a=0x1p4");
}

test "strip shebang line" {
    try expectStrip("#!/usr/bin/env lua\nprint(1)\n", "#!/usr/bin/env lua\nprint(1)");
    try expectStrip("# only a shebang", "# only a shebang");
}

test "strip block comments" {
    try expectStrip("a=1--[[ comment ]]b=2", "a=1 b=2");
    try expectStrip("a=1--[==[ comment ]==]b=2", "a=1 b=2");
    try expectStrip("a=1--[ not a block comment", "a=1");
}

test "unterminated constructs are errors" {
    try testing.expectError(error.UnterminatedString, strip("\"", testing.allocator));
    try testing.expectError(error.UnterminatedString, strip("'abc", testing.allocator));
    try testing.expectError(error.UnterminatedLongBracket, strip("[[abc", testing.allocator));
    try testing.expectError(error.UnterminatedLongBracket, strip("[=[abc", testing.allocator));
    try testing.expectError(error.UnterminatedComment, strip("--[[abc", testing.allocator));
    try testing.expectError(error.UnterminatedComment, strip("--[=[abc", testing.allocator));
}

test "short strings keep escaped quotes and backslashes" {
    try expectStrip("a='test \\'123\\''", "a='test \\'123\\''");
    try expectStrip("a=\"test \\\"123\\\"\"", "a=\"test \\\"123\\\"\"");
    try expectStrip("a=\"test \\\\\\\"123\\\"\"", "a=\"test \\\\\\\"123\\\"\"");
}

test "long brackets with many equals" {
    var input_buffer: [300]u8 = undefined;
    const equals: [130]u8 = @splat('=');
    const input = try std.fmt.bufPrint(&input_buffer, "[{s}[test]{s}]", .{ equals, equals });
    try expectStrip(input, input);
}

test "simple tokens" {
    var tokenizer = try Tokenizer.init("a=1");

    try expectToken(&tokenizer, "a");
    try expectToken(&tokenizer, "=");
    try expectToken(&tokenizer, "1");
    try expectEnd(&tokenizer);
}

test "simple tokens with spaces" {
    var tokenizer = try Tokenizer.init("  a\t\n = \t\n\r1\t ");

    try expectToken(&tokenizer, "a");
    try expectToken(&tokenizer, "=");
    try expectToken(&tokenizer, "1");
    try expectEnd(&tokenizer);
}

test "simple string with escaped quote" {
    var tokenizer = try Tokenizer.init("a='test \\'123\\''");

    try expectToken(&tokenizer, "a");
    try expectToken(&tokenizer, "=");
    try expectToken(&tokenizer, "'test \\'123\\''");
    try expectEnd(&tokenizer);
}

test "string with escaped quote" {
    var tokenizer = try Tokenizer.init("a=\"test \\\"123\\\"\"");

    try expectToken(&tokenizer, "a");
    try expectToken(&tokenizer, "=");
    try expectToken(&tokenizer, "\"test \\\"123\\\"\"");
    try expectEnd(&tokenizer);
}

test "block string" {
    var tokenizer = try Tokenizer.init("a=[==[this is a test]==]");

    try expectToken(&tokenizer, "a");
    try expectToken(&tokenizer, "=");
    try expectToken(&tokenizer, "[==[this is a test]==]");
    try expectEnd(&tokenizer);
}

test "line comment" {
    var tokenizer = try Tokenizer.init("a=1--this is a comment");

    try expectToken(&tokenizer, "a");
    try expectToken(&tokenizer, "=");
    try expectToken(&tokenizer, "1");
    try expectEnd(&tokenizer);
}

test "line comments at end of input" {
    try expectStrip("a=1--", "a=1");
    try expectStrip("a=1--[", "a=1");
    try expectStrip("a=1\r\n-- comment", "a=1");
}

test "form feed and vertical tab are whitespace" {
    try expectStrip("local\x0ba\x0c=\x0b1", "local a=1");
}

test "punctuations" {
    var tokenizer = try Tokenizer.init("{}()[].+-*/#=,~:");

    const expected = [_][]const u8{
        "{", "}", "(", ")", "[", "]", ".", "+", "-", "*", "/", "#", "=", ",", "~", ":",
    };
    for (expected) |token| {
        try expectToken(&tokenizer, token);
    }
    try expectEnd(&tokenizer);
}

test "names" {
    var tokenizer = try Tokenizer.init(" a.test_4_names:_call( other5 ) ");

    try expectToken(&tokenizer, "a");
    try expectToken(&tokenizer, ".");
    try expectToken(&tokenizer, "test_4_names");
    try expectToken(&tokenizer, ":");
    try expectToken(&tokenizer, "_call");
    try expectToken(&tokenizer, "(");
    try expectToken(&tokenizer, "other5");
    try expectToken(&tokenizer, ")");
    try expectEnd(&tokenizer);
}

test "numbers" {
    var tokenizer = try Tokenizer.init("1 1.5 1.5e-3 .5 0xFF 0x1p4");

    const expected = [_][]const u8{ "1", "1.5", "1.5e-3", ".5", "0xFF", "0x1p4" };
    for (expected) |token| {
        try expectToken(&tokenizer, token);
    }
    try expectEnd(&tokenizer);
}

test "tokenizer does not read past the end" {
    var tokenizer = try Tokenizer.init("a.");
    try expectToken(&tokenizer, "a");
    try expectToken(&tokenizer, ".");
    try expectEnd(&tokenizer);
}

test "blockLen with simple block" {
    const string: []const u8 = "[[test]]";
    const len = (try blockLen(string)).?;
    try testing.expectEqualStrings("[[test]]", string[0..len]);
}

test "blockLen with simple block additional text" {
    const string: []const u8 = "[[test]] outside block";
    const len = (try blockLen(string)).?;
    try testing.expectEqualStrings("[[test]]", string[0..len]);
}

test "blockLen not starting with a block" {
    const string: []const u8 = " [[test]]";
    try testing.expect((try blockLen(string)) == null);
}

test "blockLen with one equals block" {
    const string: []const u8 = "[=[test]=] outside block";
    const len = (try blockLen(string)).?;
    try testing.expectEqualStrings("[=[test]=]", string[0..len]);
}

test "blockLen with multiple equals block" {
    const string: []const u8 = "[===[test]===] outside block";
    const len = (try blockLen(string)).?;
    try testing.expectEqualStrings("[===[test]===]", string[0..len]);
}

test "blockLen with no matching end" {
    try testing.expectError(error.UnterminatedLongBracket, blockLen("[===[test]====]"));
    try testing.expectError(error.UnterminatedLongBracket, blockLen("[===[test]==]"));
    try testing.expectError(error.UnterminatedLongBracket, blockLen("[===[test]]"));
}

test "blockLen does not read past the end" {
    try testing.expect((try blockLen("[=")) == null);
    try testing.expect((try blockLen("[==")) == null);
    try testing.expect((try blockLen("[")) == null);
}
