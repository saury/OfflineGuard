# fishhook

Source: https://github.com/facebook/fishhook

Pinned revision: `aadc161ac3b80db07a9908851839a17ba63a9eb1` (2021-10-12).

BSD-3-Clause; the full license is preserved in both source files. Include these
notices when distributing OfflineGuard binaries.

This rebinder covers indirect symbol pointers in `__DATA` and `__DATA_CONST`.
It does not provide inline function hooks, direct syscall interception, or
universal coverage of dyld shared-cache / authenticated / chained-fixup calls.
