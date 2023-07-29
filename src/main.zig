const std = @import("std");

pub fn main() !void {
    //const source = @embedFile("ftcsv.lua");
    const source = @embedFile("serpent.lua");
    try luastrip(source);
}

const Tokenizer = struct {
    data: [:0]const u8 = undefined,
    pos: usize = 0,
    peek: []const u8 = "\n",

    pub fn next(self: *Tokenizer) []const u8 {
        const token = self.peek;
        self.peek = self.next_token();
        if (token[0] == '\n') {
            while (self.peek[0] == '\n') {
                self.peek = self.next_token();
            }
        }
        return token;
    }

    fn next_token(self: *Tokenizer) []const u8 {
        if (self.pos == self.data.len - 1) {
            return "\x00";
        }

        switch (self.data[self.pos]) {
            ' ', '\t' => {
                while (self.pos < self.data.len - 1 and (self.data[self.pos] == ' ' or self.data[self.pos] == '\t')) {
                    self.pos += 1;
                }
                return self.next_token();
            },
            '\r', '\n' => {
                while (self.pos < self.data.len - 1 and (self.data[self.pos] == '\r' or self.data[self.pos] == '\n')) {
                    self.pos += 1;
                }
                return "\n";
            },
            '-' => {
                if (self.pos < self.data.len - 2 and self.data[self.pos + 1] == '-') {
                    while (self.pos < self.data.len - 1 and self.data[self.pos] != '\r' and self.data[self.pos] != '\n') {
                        self.pos += 1;
                    }
                    return self.next_token();
                } else { //todo: check for number and return negative number as token
                    self.pos += 1;
                    return "-";
                }
            },
            '_', 'a'...'z', 'A'...'Z', '0'...'9' => {
                const start = self.pos;
                while (self.pos < self.data.len - 1) {
                    switch (self.data[self.pos]) {
                        '_', 'a'...'z', 'A'...'Z', '0'...'9' => {
                            self.pos += 1;
                        },
                        else => {
                            return self.data[start..self.pos];
                        },
                    }
                }
            },
            '"' => {
                const start = self.pos;
                self.pos += 1;
                while (self.pos < self.data.len - 1 and self.data[self.pos] != '"') {
                    self.pos += 1;
                }
                self.pos += 1;
                return self.data[start..self.pos];
            },
            '\'' => {
                const start = self.pos;
                self.pos += 1;
                while (self.pos < self.data.len - 1 and self.data[self.pos] != '\'') {
                    self.pos += 1;
                }
                self.pos += 1;
                return self.data[start..self.pos];
            },
            '[' => {
                if (self.data[self.pos + 1] == '[') {
                    const start = self.pos;
                    while (self.pos < self.data.len - 2 and !(self.data[self.pos] == ']' and self.data[self.pos + 1] == ']')) {
                        self.pos += 1;
                    }
                    self.pos += 3;
                    return self.data[start..self.pos];
                } else {
                    self.pos += 1;
                    return "[";
                }
            },
            '.' => {
                if (self.data[self.pos + 1] == '.') {
                    if (self.data[self.pos + 2] == '.') {
                        self.pos += 3;
                        return "...";
                    } else {
                        self.pos += 2;
                        return "..";
                    }
                } else {
                    self.pos += 1;
                    return ".";
                }
            },
            else => {
                const cpos = self.pos;
                self.pos += 1;
                return self.data[cpos .. cpos + 1];
            },
        }
        unreachable;
    }
};

fn tokenizer(source: [:0]const u8) Tokenizer {
    var iterator: Tokenizer = .{
        .data = source,
    };
    iterator.peek = iterator.next_token();
    return iterator;
}

pub fn luastrip(source: [:0]const u8) !void {
    const writer = std.io.getStdOut().writer();
    var it: Tokenizer = tokenizer(source);
    var token = it.next();
    while (token[0] != 0) : (token = it.next()) {
        if (token[0] == '\n') {
            try writer.writeAll(" ");
        } else {
            try writer.writeAll(token);
        }

        switch (token[0]) {
            '{', '}', '(', ')', '.', '+', '-', '*', '/', '"', '\'', '[', ']', '\n', '#', '=', ',', '~' => {
                if (it.peek[0] == '\n') {
                    _ = it.next();
                }
            },
            else => {
                switch (it.peek[0]) {
                    '{', '}', '(', ')', '.', '+', '-', '*', '/', '"', '\'', '[', ']', '\n', '#', '=', ',', '~' => {},
                    else => {
                        try writer.writeAll(" ");
                    },
                }
            },
        }
    }
}
