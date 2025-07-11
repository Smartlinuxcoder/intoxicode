const std = @import("std");

pub const tokens = @import("tokens.zig");
const Token = tokens.Token;
const TokenType = tokens.TokenType;

const Pair = struct {
    key: []const u8,
    value: TokenType,
};

pub const Keywords = [_]Pair{
    .{ .key = "if", .value = .If },
    .{ .key = "else", .value = .Else },
    .{ .key = "loop", .value = .Loop },
    .{ .key = "puke", .value = .Puke },
    .{ .key = "fun", .value = .Fun },
    .{ .key = "throwaway", .value = .Throwaway },
    .{ .key = "try", .value = .Try },
    .{ .key = "gotcha", .value = .Gotcha },
    .{ .key = "and", .value = .And },
    .{ .key = "or", .value = .Or },
    .{ .key = "not", .value = .Not },
    .{ .key = "null", .value = .Null },
    .{ .key = "true", .value = .Boolean },
    .{ .key = "false", .value = .Boolean },
};

pub fn is_keyword(token: []const u8) bool {
    for (Keywords) |pair| {
        if (std.mem.eql(u8, token, pair.key)) {
            return true;
        }
    }
    return false;
}

pub fn get_keyword_type(token: []const u8) ?TokenType {
    for (Keywords) |pair| {
        if (std.mem.eql(u8, token, pair.key)) {
            return pair.value;
        }
    }
    return null;
}

pub const Lexer = struct {
    input: []const u8,

    start_position: usize,
    position: usize,

    current_char: u8,

    tokens: std.ArrayList(Token),

    allocator: std.mem.Allocator,

    pub fn init(input: []const u8, allocator: std.mem.Allocator) Lexer {
        const lexer = Lexer{
            .input = input,
            .start_position = 0,
            .position = 0,
            .current_char = 0,
            .tokens = std.ArrayList(Token).init(allocator),
            .allocator = allocator,
        };

        return lexer;
    }

    pub fn deinit(self: *Lexer) void {
        self.tokens.deinit();
    }

    pub fn scan_tokens(self: *Lexer) !void {
        while (!self.at_end()) {
            self.start_position = self.position;
            try self.scan_token();
        }

        try self.add_raw_token(Token.init(TokenType.EOF, ""));
    }

    pub fn scan_token(self: *Lexer) !void {
        self.advance();

        switch (self.current_char) {
            '(' => try self.add_token(TokenType.LeftParen),
            ')' => try self.add_token(TokenType.RightParen),
            '{' => try self.add_token(TokenType.LeftBrace),
            '}' => try self.add_token(TokenType.RightBrace),
            '[' => try self.add_token(TokenType.LeftBracket),
            ']' => try self.add_token(TokenType.RightBracket),
            '+' => try self.add_token(TokenType.Plus),
            '-' => {
                const next = self.peek();
                if (next >= '0' and next <= '9') {
                    self.advance();
                    try self.add_token(try self.number());
                } else {
                    // This is a minus operator
                    try self.add_token(TokenType.Minus);
                }
            },
            '*' => try self.add_token(TokenType.Multiply),
            '/' => try self.add_token(TokenType.Divide),
            '%' => try self.add_token(TokenType.Modulo),
            '<' => try self.add_token(TokenType.LessThan),
            '>' => try self.add_token(TokenType.GreaterThan),
            '.' => try self.add_token(TokenType.Period),
            '?' => try self.add_token(TokenType.QuestionMark),
            ',' => try self.add_token(TokenType.Comma),
            '=' => {
                if (self.peek() == '=') {
                    self.advance(); // Consume the '='
                    try self.add_token(TokenType.Equal);
                } else {
                    try self.add_token(TokenType.Assignment);
                }
            },
            '!' => {
                if (self.peek() == '=') {
                    self.advance(); // Consume the '='
                    try self.add_token(TokenType.NotEqual);
                }
            },
            'a'...'z', 'A'...'Z', '_' => {
                var next = self.peek();
                while (!self.at_end() and (next >= 'a' and next <= 'z' or
                    next >= 'A' and next <= 'Z' or
                    next >= '0' and next <= '9' or
                    next == '_'))
                {
                    self.advance();
                    next = self.peek();
                }

                var token_type = TokenType.Identifier;

                const value = self.get_value();

                if (is_keyword(value)) {
                    token_type = get_keyword_type(value).?;
                }

                try self.add_token(token_type);
            },
            '"' => {
                self.advance(); // Consume the opening quote

                while (!self.at_end() and self.current_char != '"') self.advance();

                if (self.current_char != '"') {
                    return error.UnterminatedString; // Unterminated string literal
                }

                try self.add_token(TokenType.String);
            },
            '0'...'9' => try self.add_token(try self.number()),
            ' ', '\n', '\r', '\t' => {}, // Ignore whitespace
            else => {
                std.debug.print("Input: {s}\n", .{self.input});

                for (self.tokens.items) |token| {
                    std.debug.print("Token: {s} ({})\n", .{ token.value, token.token_type });
                }

                std.debug.print("Unexpected character: '{c}' ({d}) at line, position {d}\n", .{
                    self.current_char,
                    self.current_char,
                    self.position,
                });
                unreachable; // Handle unexpected characters
            },
        }
    }

    fn number(self: *Lexer) !TokenType {
        var next = self.peek();
        while (!self.at_end() and next >= '0' and next <= '9') {
            self.advance();
            next = self.peek();
        }

        next = self.peek();
        const next_to_next = self.peek_next();

        var token_type: TokenType = undefined;

        if (next == '.' and (next_to_next >= '0' and next_to_next <= '9')) {
            self.advance(); // Consume the '.'
            next = self.peek();
            while (!self.at_end() and next >= '0' and next <= '9') {
                self.advance();
                next = self.peek();
            }

            token_type = .Float;
        } else {
            token_type = .Integer;
        }

        return token_type;
    }

    pub fn add_raw_token(self: *Lexer, token: Token) !void {
        try self.tokens.append(token);
    }

    pub fn get_value(self: *Lexer) []const u8 {
        const end_index = self.position;

        return self.input[self.start_position..end_index];
    }

    pub fn add_token(self: *Lexer, token_type: TokenType) !void {
        const value = self.get_value();

        const token = Token.init(token_type, value);

        try self.tokens.append(token);
    }

    pub fn at_end(self: *Lexer) bool {
        return self.position >= self.input.len;
    }

    pub fn peek(self: *Lexer) u8 {
        if (self.at_end()) return 0;

        if (self.position >= self.input.len) {
            return 0;
        }

        return self.input[self.position];
    }

    pub fn peek_next(self: *Lexer) u8 {
        if (self.at_end()) return 0;

        if (self.position + 1 >= self.input.len) {
            return 0; // No next character
        }

        return self.input[self.position + 1];
    }

    pub fn advance(self: *Lexer) void {
        self.current_char = self.input[self.position];
        self.position += 1;
    }

    pub fn match(self: *Lexer, expected: u8) bool {
        if (self.at_end()) return false;
        if (self.current_char != expected) return false;

        self.advance();
        return true;
    }

    pub fn next_position(self: *Lexer) void {
        self.position += 1;
    }
};
