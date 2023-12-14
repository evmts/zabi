const std = @import("std");
const testing = std.testing;
const AbiParameter = @import("../abi_parameter.zig").AbiParameter;
const AbiEventParameter = @import("../abi_parameter.zig").AbiEventParameter;
const Alloc = std.mem.Allocator;
const Lexer = @import("lexer.zig").Lexer;
const ParamErrors = @import("../param_type.zig").ParamErrors;
const ParamType = @import("../param_type.zig").ParamType;
const Tokens = @import("tokens.zig").Tag.SoliditySyntax;

const Parser = @This();
const TokenList = std.MultiArrayList(struct {
    token_type: Tokens,
    start: u32,
    end: u32,
});

const ParseError = error{ InvalidDataLocation, UnexceptedToken, ExpectedCommaAfterParam } || ParamErrors;

alloc: Alloc,
tokens: []const Tokens,
tokens_start: []const u32,
tokens_end: []const u32,
token_index: u32,
source: []const u8,

fn parseFuncParamsDecl(p: *Parser) ![]const AbiParameter {
    var param_list = std.ArrayList(AbiParameter).init(p.alloc);
    errdefer param_list.deinit();

    while (true) {
        const abitype: ParamType = if (p.consumeToken(.OpenParen)) |_| ParamType{ .tuple = {} } else try p.parseTypeExpr();
        const location = p.parseDataLocation();

        if (location) |tok| {
            _ = p.consumeToken(tok);
            switch (tok) {
                .Indexed => return error.InvalidDataLocation,
                .Memory, .Calldata, .Storage => {
                    const isValid = switch (abitype) {
                        .string, .bytes => true,
                        .dynamicArray => true,
                        .fixedArray => true,
                        inline else => false,
                    };

                    if (!isValid) return error.InvalidDataLocation;
                },
                inline else => {},
            }
        }

        const name = p.parseIdentifier() orelse "";
        const param = .{ .type = abitype, .name = name, .internal_type = null, .components = null };

        try param_list.append(param);

        switch (p.tokens[p.token_index]) {
            .Comma => p.token_index += 1,
            .ClosingParen => break,
            inline else => return error.ExpectedCommaAfterParam,
        }
    }

    return try param_list.toOwnedSlice();
}

fn parseEventParamsDecl(p: *Parser) ![]const AbiEventParameter {
    var param_list = std.ArrayList(AbiEventParameter).init(p.alloc);
    errdefer param_list.deinit();

    while (true) {
        const abitype: ParamType = if (p.consumeToken(.OpenParen)) |_| ParamType{ .tuple = {} } else try p.parseTypeExpr();
        const location = p.parseDataLocation();

        const indexed = if (location) |tok| {
            switch (tok) {
                .Indexed => true,
                inline else => return error.InvalidDataLocation,
            }
        } else false;

        const name = p.parseIdentifier() orelse "";
        const param = .{ .type = abitype, .name = name, .indexed = indexed, .internal_type = null, .components = null };

        try param_list.append(param);

        switch (p.tokens[p.token_index]) {
            .Comma => p.token_index += 1,
            .ClosingParen => break,
            inline else => return error.ExpectedCommaAfterParam,
        }
    }

    return try param_list.toOwnedSlice();
}

fn parseErrorParamsDecl(p: *Parser) ParseError![]const AbiParameter {
    var param_list = std.ArrayList(AbiParameter).init(p.alloc);
    errdefer param_list.deinit();

    while (true) {
        const tuple_param = if (p.consumeToken(.OpenParen) != null) try p.parseTuple() else null;
        if (tuple_param != null) {
            try param_list.append(tuple_param.?);

            switch (p.tokens[p.token_index]) {
                .Comma => p.token_index += 1,
                .ClosingParen => break,
                .EndOfFileToken => break,
                inline else => return error.ExpectedCommaAfterParam,
            }

            continue;
        }

        const abitype = try p.parseTypeExpr();
        errdefer ParamType.freeArrayParamType(abitype, p.alloc);

        const location = p.parseDataLocation();
        if (location != null) return error.InvalidDataLocation;

        const name = p.parseIdentifier() orelse "";
        const param: AbiParameter = .{ .type = abitype, .name = name, .internal_type = null, .components = null };

        try param_list.append(param);

        switch (p.tokens[p.token_index]) {
            .Comma => p.token_index += 1,
            .ClosingParen => break,
            .EndOfFileToken => break,
            inline else => return error.ExpectedCommaAfterParam,
        }
    }

    return try param_list.toOwnedSlice();
}

fn parseTuple(p: *Parser) ParseError!AbiParameter {
    const components = try p.parseErrorParamsDecl();
    errdefer p.alloc.free(components);

    _ = try p.expectToken(.ClosingParen);
    const start = p.token_index;
    const end = try p.parseArrayType();
    const array_slice = if (end) |arr| p.source[p.tokens_start[start]..p.tokens_end[arr]] else null;

    const type_name = try std.fmt.allocPrintZ(p.alloc, "tuple{s}", .{array_slice orelse ""});
    defer p.alloc.free(type_name);

    const abitype = try ParamType.typeToUnion(type_name, p.alloc);
    errdefer ParamType.freeArrayParamType(abitype, p.alloc);

    const name = p.parseIdentifier() orelse "";

    return .{ .type = abitype, .name = name, .internal_type = null, .components = components };
}

fn parseTypeExpr(p: *Parser) !ParamType {
    const index = p.nextToken();
    const tok = p.tokens[index];

    if (tok.lexToken()) |type_name| {
        const slice = if (try p.parseArrayType()) |arr| p.source[p.tokens_start[index]..p.tokens_end[arr]] else type_name;

        return try ParamType.typeToUnion(slice, p.alloc);
    }

    return error.UnexceptedToken;
}

fn parseArrayType(p: *Parser) !?u32 {
    while (true) {
        const token = p.nextToken();

        switch (p.tokens[token]) {
            .OpenBracket => continue,
            .Number => {
                _ = try p.expectToken(.ClosingBracket);
                p.token_index -= 1;
            },
            .ClosingBracket => switch (p.tokens[p.token_index]) {
                .OpenBracket => continue,
                else => return token,
            },
            inline else => {
                p.token_index -= 1;
                return null;
            },
        }
    }
}

fn parseDataLocation(p: *Parser) ?Tokens {
    const tok = p.tokens[p.token_index];

    return switch (tok) {
        .Indexed, .Calldata, .Storage, .Memory => tok,
        inline else => null,
    };
}

fn parseVisibility(p: *Parser) !void {
    const external = p.consumeToken(.External) orelse 0;
    const public = p.consumeToken(.Public) orelse 0;

    if (external != 0 and public != 0) {
        return error.UnexceptedToken;
    }
}

fn parseIdentifier(p: *Parser) ?[]const u8 {
    return if (p.consumeToken(.Identifier)) |ident| p.source[p.tokens_start[ident]..p.tokens_end[ident]] else null;
}

fn expectToken(p: *Parser, expected: Tokens) !u32 {
    if (p.tokens[p.token_index] != expected) return error.UnexceptedToken;

    return p.nextToken();
}

fn consumeToken(p: *Parser, tok: Tokens) ?u32 {
    return if (p.tokens[p.token_index] == tok) p.nextToken() else null;
}

fn nextToken(p: *Parser) u32 {
    const index = p.token_index;
    p.token_index += 1;

    return index;
}

test "Simple" {
    var lex = Lexer.init("(address foo, (bool baz))[] bar");
    var list = Parser.TokenList{};
    defer list.deinit(testing.allocator);

    while (true) {
        const tok = lex.scan();
        try list.append(testing.allocator, .{ .token_type = tok.syntax, .start = tok.location.start, .end = tok.location.end });

        if (tok.syntax == .EndOfFileToken) break;
    }

    var parser: Parser = .{
        .alloc = testing.allocator,
        .tokens = list.items(.token_type),
        .tokens_start = list.items(.start),
        .tokens_end = list.items(.end),
        .token_index = 0,
        .source = lex.currentText,
    };

    const params = try parser.parseErrorParamsDecl();
    defer testing.allocator.free(params);
    defer testing.allocator.free(params[0].components.?);

    std.debug.print("FOOO: {any}\n", .{params[0].components.?[1].components.?});
}
