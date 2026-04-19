# Fimpo

Fimpo sorts zig imports.

It splits them into the following groups:
- Standard library imports and its derived
- "builtin"
- Third-party imports, including the build targets of yours
- Relative imports, e.g. ../foo.zig or folder/to/path.zig
- Local imports, e.g. "file.zig"

The groups are separated by a blank line, and the imports within each group are sorted alphabetically.
A derived import from one above stays in the same group

The imports after first code statement not related to the import are not sorted and are left as is.

Read unit tests for more
