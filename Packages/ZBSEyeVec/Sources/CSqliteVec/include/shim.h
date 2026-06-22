#ifndef CSQLITEVEC_SHIM_H
#define CSQLITEVEC_SHIM_H

/* Статическая линковка sqlite-vec: используем системный sqlite3.h (не extension API). */
#ifndef SQLITE_CORE
#define SQLITE_CORE 1
#endif
#ifndef SQLITE_VEC_STATIC
#define SQLITE_VEC_STATIC 1
#endif

#include <sqlite3.h>
#include "sqlite-vec.h"

#endif /* CSQLITEVEC_SHIM_H */
