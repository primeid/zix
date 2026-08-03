//! ZIX — the Nix expression language, reimplemented in Zig.
//! Re-exports the interpreter modules so `zig build test` covers them all.

pub const nixhash = @import("nixhash.zig");
pub const fsutil = @import("fsutil.zig");
pub const store = @import("store.zig");
pub const drv = @import("drv.zig");
pub const lexer = @import("lexer.zig");
pub const ast = @import("ast.zig");
pub const parser = @import("parser.zig");
pub const value = @import("value.zig");
pub const eval = @import("eval.zig");
pub const builtins = @import("builtins.zig");
pub const tests = @import("tests.zig");

test {
    _ = nixhash;
    _ = store;
    _ = drv;
    _ = lexer;
    _ = ast;
    _ = parser;
    _ = value;
    _ = eval;
    _ = builtins;
    _ = tests;
}
