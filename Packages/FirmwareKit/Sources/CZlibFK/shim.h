// Umbrella for the CZlibFK system library target: the platform's zlib.
#if defined(_WIN32)
// zlib.h is not available on Windows (no system zlib). The CZlibFK module is
// a no-op on Windows; FirmwareKit's zlib call sites still need
// #if os(Windows) guards in Swift (Swift-layer work) before the package can
// build there.
typedef void *CZlibFKDummy;
#else
#include <zlib.h>
#endif
