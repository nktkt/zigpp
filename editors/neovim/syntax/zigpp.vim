if exists("b:current_syntax") | finish | endif

" Comments
syntax match  zppCommentDoc      "//[!/].*$" contains=@Spell
syntax match  zppComment         "//\(\/\|!\)\@!.*$" contains=@Spell
syntax region zppCommentBlock    start="/\*" end="\*/" contains=@Spell

" Strings & chars
syntax region zppString          start=+"+ skip=+\\\\\|\\"+ end=+"+
syntax match  zppMultilineString "\\\\.*$"
syntax region zppChar            start=+'+ skip=+\\\\\|\\'+ end=+'+

" Numbers
syntax match  zppNumber          "\<0x[0-9A-Fa-f_]\+\>"
syntax match  zppNumber          "\<0b[01_]\+\>"
syntax match  zppNumber          "\<0o[0-7_]\+\>"
syntax match  zppNumber          "\<\d[0-9_]*\(\.\d[0-9_]*\)\?\>"

" Builtins
syntax match  zppBuiltin         "@\w\+"

" Keywords (Zig core subset)
syntax keyword zppKeyword        fn pub const var return if else while for defer try
syntax keyword zppKeyword        error struct enum union comptime extern packed inline
syntax keyword zppKeyword        and or orelse switch break continue catch errdefer test

" Zig++ extension keywords
syntax keyword zppZppKeyword     trait impl dyn using own move owned effects
syntax keyword zppZppKeyword     requires ensures invariant derive where interface

" Constants
syntax keyword zppBoolean        true false
syntax keyword zppNull           null undefined unreachable

" Function definition (highlight name after `fn`)
syntax match   zppFunction       "\<fn\>\s\+\zs\w\+"

" Type names: leading uppercase identifiers
syntax match   zppType           "\<[A-Z][A-Za-z0-9_]*\>"

" Highlight links
hi def link zppCommentDoc        SpecialComment
hi def link zppComment           Comment
hi def link zppCommentBlock      Comment
hi def link zppString            String
hi def link zppMultilineString   String
hi def link zppChar              Character
hi def link zppNumber            Number
hi def link zppBuiltin           Function
hi def link zppKeyword           Keyword
hi def link zppZppKeyword        Statement
hi def link zppBoolean           Boolean
hi def link zppNull              Constant
hi def link zppFunction          Function
hi def link zppType              Type

let b:current_syntax = "zigpp"
