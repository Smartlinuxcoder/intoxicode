const std = @import("std");

pub const expressions = @import("expressions.zig");
pub const statements = @import("statement.zig");

const Expression = expressions.Expression;
const Statement = statements.Statement;

const _tokens = @import("../lexer/tokens.zig");
const Token = _tokens.Token;
const TokenType = _tokens.TokenType;

pub const Parser = struct {
    tokens: std.ArrayList(Token),
    current: usize = 0,

    allocator: std.mem.Allocator,

    pub fn init(tokens: std.ArrayList(Token), allocator: std.mem.Allocator) Parser {
        return Parser{
            .tokens = tokens,
            .current = 0,
            .allocator = allocator,
        };
    }

    fn consume(self: *Parser, token_type: TokenType, message: []const u8) !Token {
        if (self.check(token_type)) {
            return self.advance();
        }

        std.debug.panic("Expected token type: {}, but found: {}. {s}", .{
            token_type,
            self.peek().token_type,
            message,
        });
    }

    fn peek(self: *Parser) Token {
        return self.tokens.items[self.current];
    }

    fn previous(self: *Parser) Token {
        return self.tokens.items[self.current - 1];
    }

    fn is_at_end(self: *Parser) bool {
        return self.peek().token_type == .EOF;
    }

    fn advance(self: *Parser) Token {
        if (!self.is_at_end()) self.current += 1;
        return self.previous();
    }

    fn check(self: *Parser, token_type: TokenType) bool {
        if (self.is_at_end()) return false;
        return self.peek().token_type == token_type;
    }

    fn match(self: *Parser, token_types: []const TokenType) bool {
        for (token_types) |token_type| {
            if (self.check(token_type)) {
                _ = self.advance();
                return true;
            }
        }
        return false;
    }

    pub fn parse(self: *Parser) error{ OutOfMemory, InvalidCharacter }!std.ArrayList(*Statement) {
        var stmts = std.ArrayList(*Statement).init(self.allocator);

        while (!self.is_at_end()) {
            const statement_obj = try self.statement();
            try stmts.append(statement_obj);
        }

        return stmts;
    }

    fn statement(self: *Parser) error{ OutOfMemory, InvalidCharacter }!*Statement {
        const found_stmt = if (self.match(&[_]TokenType{.If}))
            try self.if_statement()
        else if (self.match(&[_]TokenType{.Loop}))
            try self.loop_statement()
        else if (self.match(&[_]TokenType{.Fun}))
            try self.function_declaration()
        else if (self.match(&[_]TokenType{.Try}))
            try self.try_statement()
        else if (self.match(&[_]TokenType{.Throwaway}))
            try self.throwaway_statement()
        else if (self.match(&[_]TokenType{.Identifier}))
            try self.assignment_or_expression()
        else
            try self.expression_statement();

        const next = self.advance();
        const certainty: f32 = switch (next.token_type) {
            .Period => 1.0,
            .QuestionMark => 0.75,
            else => std.debug.panic("Unexpected token after statement: {s}", .{next.value}),
        };

        found_stmt.set_certainty(certainty);

        return found_stmt;
    }

    fn expression_statement(self: *Parser) !*Statement {
        const expr = try self.expression();

        const stmt = try self.allocator.create(Statement);
        stmt.* = Statement{
            .expression = expr,
        };

        return stmt;
    }

    fn assignment_or_expression(self: *Parser) !*Statement {
        const identifier = self.previous().value;

        if (self.match(&[_]TokenType{.Assignment})) {
            const expr = try self.expression();

            const stmt = try self.allocator.create(Statement);
            stmt.* = Statement{
                .assignment = statements.Assignment{
                    .identifier = identifier,
                    .expression = expr,
                },
            };

            return stmt;
        }

        if (self.match(&[_]TokenType{.LeftParen})) {
            const args = try self.allocator.create(std.ArrayList(Expression));
            args.* = std.ArrayList(Expression).init(self.allocator);

            while (!self.is_at_end() and !self.check(.RightParen)) {
                const arg = try self.expression();
                try args.append(arg);

                if (!self.match(&[_]TokenType{.Comma})) break;
            }

            _ = try self.consume(.RightParen, "Expected ')' after function arguments.");

            const identifier_expr = try self.allocator.create(Expression);
            identifier_expr.* = Expression{
                .identifier = expressions.Identifier{
                    .name = identifier,
                },
            };

            const stmt = try self.allocator.create(Statement);
            stmt.* = Statement{
                .expression = Expression{
                    .call = expressions.Call{
                        .callee = identifier_expr,
                        .arguments = args.*,
                    },
                },
            };

            return stmt;
        }

        return self.expression_statement();
    }

    fn if_statement(self: *Parser) !*Statement {
        const condition = try self.expression();

        _ = try self.consume(.LeftBrace, "Expected '{' after 'if'.");

        var then_branch = std.ArrayList(*Statement).init(self.allocator);

        while (!self.is_at_end() and !self.check(.RightBrace)) {
            const stmt = try self.statement();
            try then_branch.append(stmt);
        }

        _ = try self.consume(.RightBrace, "Expected '}' to end 'if' block.");

        var else_branch: ?std.ArrayList(*Statement) = null;
        if (self.match(&[_]TokenType{.Else})) {
            _ = try self.consume(.LeftBrace, "Expected '{' after 'if'.");

            else_branch = std.ArrayList(*Statement).init(self.allocator);

            while (!self.is_at_end() and !self.check(.RightBrace)) {
                const stmt = try self.statement();
                try else_branch.?.append(stmt);
            }

            _ = try self.consume(.RightBrace, "Expected '}' to end 'if' block.");
        }

        const stmt = try self.allocator.create(Statement);
        stmt.* = Statement{
            .if_statement = statements.IfStatement{
                .condition = condition,
                .then_branch = then_branch,
                .else_branch = else_branch,
            },
        };

        return stmt;
    }

    fn loop_statement(self: *Parser) !*Statement {
        const condition = try self.expression();
        _ = try self.consume(.LeftParen, "Expected '(' after 'loop'.");

        var body = std.ArrayList(*Statement).init(self.allocator);
        defer body.deinit();

        while (!self.is_at_end()) {
            const stmt = try self.statement();
            try body.append(stmt);
        }

        const stmt = try self.allocator.create(Statement);
        stmt.* = Statement{
            .loop_statement = statements.LoopStatement{
                .condition = condition,
                .body = body,
            },
        };

        return stmt;
    }

    fn function_declaration(self: *Parser) !*Statement {
        const name = (try self.consume(.Identifier, "Expected function name after 'fun' keyword.")).value;
        _ = try self.consume(.LeftParen, "Expected '(' after function name.");

        var params = std.ArrayList([]const u8).init(self.allocator);

        while (!self.is_at_end() and !self.check(.RightParen)) {
            if (self.match(&[_]TokenType{.Identifier})) {
                try params.append(self.previous().value);
            } else {
                std.debug.panic("Expected identifier for function parameter.", .{});
            }

            if (!self.match(&[_]TokenType{.Comma})) break;
        }

        _ = try self.consume(.RightParen, "Expected ')' after function parameters.");

        _ = try self.consume(.LeftBrace, "Expected '{' to start function body.");

        var body = std.ArrayList(*Statement).init(self.allocator);

        while (!self.is_at_end() and !self.check(.RightBrace)) {
            const stmt = try self.statement();
            try body.append(stmt);
        }

        _ = try self.consume(.RightBrace, "Expected '}' to end function body.");

        const stmt = try self.allocator.create(Statement);
        stmt.* = Statement{
            .function_declaration = statements.FunctionDeclaration{
                .name = name,
                .parameters = params,
                .body = body,
            },
        };

        return stmt;
    }

    fn try_statement(self: *Parser) !*Statement {
        _ = try self.consume(.LeftBrace, "Expected '{' after 'try'.");

        var body = std.ArrayList(*Statement).init(self.allocator);

        while (!self.is_at_end() and !self.check(.RightBrace)) {
            const stmt = try self.statement();
            try body.append(stmt);
        }

        _ = try self.consume(.RightBrace, "Expected '}' to end 'try' block.");

        var catch_block = std.ArrayList(*Statement).init(self.allocator);

        _ = try self.consume(.Gotcha, "Expected 'gotcha' after 'try' block.");
        _ = try self.consume(.LeftBrace, "Expected '{' after 'gotcha'.");

        while (!self.is_at_end() and !self.check(.RightBrace)) {
            const stmt = try self.statement();
            try catch_block.append(stmt);
        }

        _ = try self.consume(.RightBrace, "Expected '}' to end 'gotcha' block.");

        const stmt = try self.allocator.create(Statement);
        stmt.* = Statement{
            .try_statement = statements.TryStatement{
                .body = body,
                .catch_block = catch_block,
            },
        };

        return stmt;
    }

    fn throwaway_statement(self: *Parser) !*Statement {
        const expr = try self.expression();

        const stmt = try self.allocator.create(Statement);
        stmt.* = Statement{
            .throwaway_statement = statements.ThrowawayStatement{
                .expression = expr,
            },
        };

        return stmt;
    }

    fn expression(self: *Parser) error{ OutOfMemory, InvalidCharacter }!Expression {
        if (self.match(&[_]TokenType{.LeftParen})) {
            const expr = try self.allocator.create(Expression);
            expr.* = try self.expression();

            _ = try self.consume(.RightParen, "Expected ')' after expression.");

            return Expression{
                .grouping = expressions.Grouping{
                    .expression = expr,
                },
            };
        }

        if (self.match(&[_]TokenType{.LeftBracket})) {
            const elements = try self.allocator.create(std.ArrayList(Expression));
            elements.* = std.ArrayList(Expression).init(self.allocator);

            while (!self.is_at_end() and !self.check(.RightBracket)) {
                const element = try self.expression();
                try elements.append(element);

                if (!self.match(&[_]TokenType{.Comma})) break;
            }

            _ = try self.consume(.RightBracket, "Expected ']' after array elements.");

            return Expression{
                .literal = expressions.Literal{
                    .array = elements.*,
                },
            };
        }

        return try self.equality();
    }

    fn equality(self: *Parser) !Expression {
        var expr = try self.comparison();

        while (self.match((&[_]TokenType{ .Equal, .NotEqual })[0..])) {
            const operator = self.previous();

            const right = try self.allocator.create(Expression);
            right.* = try self.comparison();

            const left = try self.allocator.create(Expression);
            left.* = expr;

            expr = Expression{
                .binary = expressions.Binary{
                    .left = left,
                    .operator = operator,
                    .right = right,
                },
            };
        }

        return expr;
    }

    fn comparison(self: *Parser) !Expression {
        var expr = try self.term();

        while (self.match((&[_]TokenType{ .GreaterThan, .LessThan })[0..])) {
            const operator = self.previous();

            const right = try self.allocator.create(Expression);
            right.* = try self.term();

            const left = try self.allocator.create(Expression);
            left.* = expr;

            expr = Expression{
                .binary = expressions.Binary{
                    .left = left,
                    .operator = operator,
                    .right = right,
                },
            };
        }

        return expr;
    }

    fn term(self: *Parser) !Expression {
        var expr = try self.factor();

        while (self.match(&[_]TokenType{ .Plus, .Minus })) {
            const operator = self.previous();

            const right = try self.allocator.create(Expression);
            right.* = try self.factor();

            const left = try self.allocator.create(Expression);
            left.* = expr;

            expr = Expression{
                .binary = expressions.Binary{
                    .left = left,
                    .operator = operator,
                    .right = right,
                },
            };
        }

        return expr;
    }

    fn factor(self: *Parser) !Expression {
        var expr = try self.indexing();

        while (self.match(&[_]TokenType{ .Multiply, .Divide })) {
            const operator = self.previous();

            const right = try self.allocator.create(Expression);
            right.* = try self.indexing();

            const left = try self.allocator.create(Expression);
            left.* = expr;

            expr = Expression{
                .binary = expressions.Binary{
                    .left = left,
                    .operator = operator,
                    .right = right,
                },
            };
        }

        return expr;
    }

    fn indexing(self: *Parser) !Expression {
        var expr = try self.call();

        while (self.match(&[_]TokenType{.LeftBracket})) {
            const index_expr = try self.expression();

            const index = try self.allocator.create(Expression);
            index.* = index_expr;

            _ = try self.consume(.RightBracket, "Expected ']' after index expression.");

            const array = try self.allocator.create(Expression);
            array.* = expr;

            expr = Expression{
                .indexing = expressions.Indexing{
                    .array = array,
                    .index = index,
                },
            };
        }

        return expr;
    }

    fn call(self: *Parser) !Expression {
        var expr = try self.primary();

        while (self.match(&[_]TokenType{.LeftParen})) {
            const args = try self.allocator.create(std.ArrayList(Expression));
            args.* = std.ArrayList(Expression).init(self.allocator);

            while (!self.is_at_end() and !self.check(.RightParen)) {
                const arg = try self.expression();
                try args.append(arg);

                if (!self.match(&[_]TokenType{.Comma})) break;
            }

            _ = try self.consume(.RightParen, "Expected ')' after arguments.");

            const callee = try self.allocator.create(Expression);
            callee.* = expr;

            expr = Expression{
                .call = expressions.Call{
                    .callee = callee,
                    .arguments = args.*,
                },
            };
        }

        return expr;
    }

    fn primary(self: *Parser) !Expression {
        if (self.match(&[_]TokenType{ .Integer, .Float, .String, .Identifier })) {
            const token = self.previous();

            return switch (token.token_type) {
                .Identifier => Expression{
                    .identifier = expressions.Identifier{
                        .name = token.value,
                    },
                },
                .Integer, .Float => Expression{ .literal = try expressions.Literal.number_from_string(token.value) },
                .String => Expression{
                    .literal = expressions.Literal{
                        .string = token.value,
                    },
                },
                else => unreachable,
            };
        }

        if (self.match(&[_]TokenType{.LeftParen})) {
            const expr = try self.allocator.create(Expression);
            expr.* = try self.expression();

            _ = try self.consume(.RightParen, "Expected ')' after expression.");

            return Expression{
                .grouping = expressions.Grouping{
                    .expression = expr,
                },
            };
        }

        std.debug.panic("Unexpected token: {s}", .{self.peek().value});
    }
};
