package gbbfx

// Build-time feature flags. Compile with `-define:EDITOR=true` (or
// `make debug EDITOR=true`) to include the editor UI; anything wrapped in
// `when EDITOR` is pruned from editor-less builds.
EDITOR :: #config(EDITOR, false)
