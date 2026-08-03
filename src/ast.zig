//! Abstract syntax tree for the Nix expression language.
//! Mirrors Nix's `Expr*` class hierarchy (nixexpr.hh).

const std = @import("std");

pub const Expr = union(enum) {
    int: i64,
    float: f64,
    str: Str,
    path: []const u8, // already resolved to an absolute filesystem path
    var_ref: []const u8,
    select: Select,
    has_attr: HasAttr,
    apply: Apply,
    op: Op,
    concat: Concat,
    not_: *Expr,
    call_builtin: CallBuiltin,
    attrset: AttrSet,
    let_rec: LetRec, // legacy `let <binds> in <expr>`
    with_: With,
    if_: If,
    assert_: Assert,
    lambda: Lambda,
    list: []*Expr,
    pos: void, // __curPos
    import_path: []const u8, // <spath> → findFile; kept as special node
};

pub const StrKind = enum { dquote, indented };

pub const Str = struct {
    parts: []const Part,
    kind: StrKind,
};

pub const Part = union(enum) {
    lit: []const u8,
    interp: *Expr,
};

pub const AttrElem = union(enum) {
    static: []const u8,
    dyn: *Expr,
};

pub const Select = struct {
    base: *Expr,
    attrs: []const AttrElem,
    default: ?*Expr,
};

pub const HasAttr = struct {
    base: *Expr,
    attrs: []const AttrElem,
};

pub const Apply = struct { fun: *Expr, arg: *Expr };

pub const OpKind = enum {
    eq,
    neq,
    and_,
    or_,
    impl,
    update, // //
    concat_lists, // ++
};

pub const Op = struct { kind: OpKind, left: *Expr, right: *Expr };

/// `+` (Nix ExprConcatStrings with indented=false) and string/path
/// interpolation.  All parts must be concatenable values.
pub const Concat = struct { parts: []*Expr };

/// Calls to `builtins.sub`/`mul`/`div`/`lessThan` produced by the
/// desugarings `-`, `*`, `/`, `<`, `>`, `<=`, `>=`, unary `-`.
pub const CallBuiltin = struct { name: []const u8, args: []*Expr };

pub const AttrBind = struct {
    /// Attrpath; may contain dynamic (${expr}) elements.
    path: []const AttrElem,
    value: *Expr,
    /// `inherit (x) a b`: expression producing the attrset to inherit from.
    inherit_from: ?*Expr,
};

pub const AttrSet = struct {
    binds: []const AttrBind,
    recursive: bool,
};

pub const LetRec = struct {
    binds: []const AttrBind,
    body: *Expr,
};

pub const With = struct { attrs: *Expr, body: *Expr };

pub const If = struct { cond: *Expr, then: *Expr, else_: *Expr };

pub const Assert = struct { cond: *Expr, body: *Expr };

pub const Formal = struct {
    name: []const u8,
    default: ?*Expr,
};

pub const Formals = struct {
    formals: []Formal,
    ellipsis: bool,
};

pub const Lambda = struct {
    /// `x: body`
    arg: ?[]const u8,
    /// `{ ... }: body`
    formals: ?Formals,
    /// `@name` binding receiving the whole argument attrset
    arg_name: ?[]const u8,
    body: *Expr,
};
