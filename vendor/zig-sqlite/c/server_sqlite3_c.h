#include "server_namespace.h"
/* translate-c uses the first declaration. Preserve the array ABI for the
 * pinned 3.54.0 string (including NUL), rather than translating [] as a pointer.
 * The namespace check and lifecycle test pin this size and contents. */
extern const char sqlite3_version[7];
#include "sqlite3_c.h"
/* A Zig const alias would try to copy this extern array at comptime. Access
 * this data symbol by its namespaced name; function aliases remain unchanged. */
#undef sqlite3_version
