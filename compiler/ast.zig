//! Zig++ abstract syntax tree node definitions.
//!
//! This module declares the shapes used by the parser and consumed by the
//! semantic analyzer and the lowering stage. Traversal, allocation, and
//! pretty-printing logic live elsewhere; only the types live here.

/// Declared ownership flavor on a binding or parameter. `.owned` is the
/// affine-tracked kind handled by the ownership pass.
pub const OwnershipKind = enum {
    none,
    owned,
    borrowed,
};

/// Effect labels. The set is open in design but stubbed to a few well-known
/// labels; the analyzer treats unknown labels as opaque.
pub const Effect = enum {
    noalloc,
    io,
    panic,
    pure,
    unknown,
};

/// Signature of a method declared inside a `trait`. The bodies live on the
/// `impl` blocks, not here.
pub const MethodSig = struct {
    name: []const u8,
    params: []Param,
    return_type: ?*Node,
    effects: []Effect,
};

pub const Param = struct {
    name: []const u8,
    type_node: *Node,
    ownership: OwnershipKind = .none,
};

/// `trait Name { fn ...; fn ...; }`
pub const TraitDecl = struct {
    name: []const u8,
    methods: []MethodSig,
};

/// Top-level AST node. The variants intentionally cover only what the parser
/// is expected to emit and what sema / lowering pattern-match on.
pub const Node = union(enum) {
    module: Module,
    fn_decl: FnDecl,
    struct_decl: StructDecl,
    trait_decl: TraitDecl,
    impl_block: ImplBlock,
    using_stmt: UsingStmt,
    own_decl: OwnDecl,
    move_expr: MoveExpr,
    dyn_type: DynType,
    impl_type: ImplType,
    effects_attr: EffectsAttr,
    requires_attr: ContractAttr,
    ensures_attr: ContractAttr,
    derive_attr: DeriveAttr,
    block: Block,
    call: Call,
    ident: Ident,
    literal: Literal,

    pub fn initModule(decls: []*Node) Node {
        return .{ .module = .{ .decls = decls } };
    }
};

pub const Module = struct {
    decls: []*Node,
};

pub const FnDecl = struct {
    name: []const u8,
    params: []Param,
    return_type: ?*Node,
    effects: []Effect,
    body: ?*Node,
};

pub const StructDecl = struct {
    name: []const u8,
    fields: []Param,
    derives: []DeriveAttr,
};

pub const ImplBlock = struct {
    /// The trait being implemented, or `null` for an inherent impl.
    trait_name: ?[]const u8,
    type_name: []const u8,
    methods: []*Node,
};

/// `using x = expr;` — explicit RAII binding.
pub const UsingStmt = struct {
    name: []const u8,
    init_expr: *Node,
};

/// `own x: T = expr;` — affine-tracked owned binding.
pub const OwnDecl = struct {
    name: []const u8,
    type_node: ?*Node,
    init_expr: ?*Node,
};

/// `move(x)` — consumes the affine binding `x`.
pub const MoveExpr = struct {
    target: *Node,
};

/// `dyn Trait` type reference.
pub const DynType = struct {
    trait_name: []const u8,
};

/// `impl Trait` type reference (static dispatch via comptime generics).
pub const ImplType = struct {
    trait_name: []const u8,
};

pub const EffectsAttr = struct {
    effects: []Effect,
};

/// Both `requires` and `ensures` share this shape; the kind is encoded by
/// which `Node` variant carries it.
pub const ContractAttr = struct {
    expr: *Node,
};

pub const DeriveAttr = struct {
    /// Names of the derive macros, e.g. `Json`, `Hash`, `Debug`.
    names: [][]const u8,
};

pub const Block = struct {
    stmts: []*Node,
};

pub const Call = struct {
    callee: *Node,
    args: []*Node,
};

pub const Ident = struct {
    name: []const u8,
};

pub const Literal = struct {
    pub const Kind = enum { int, float, string, bool_true, bool_false, null_lit };
    kind: Kind,
    text: []const u8,
};

