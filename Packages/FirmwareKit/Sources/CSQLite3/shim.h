// Umbrella for the CSQLite3 system library target: the platform's SQLite.
#if defined(_WIN32)
// sqlite3.h is not available on Windows. The CSQLite3 module is a no-op on
// Windows; FirmwareKit's sqlite call sites still need #if os(Windows) guards
// in Swift (Swift-layer work) before the package can build there.
typedef void *CSQLite3Dummy;
#else
#include <sqlite3.h>
#endif
