// Umbrella for the CZlibHost system library target: the platform's zlib.
#if defined(_WIN32)
// zlib.h is not available on Windows (no system zlib). The CZlibHost module
// is a no-op on Windows; GuestPack's zlib uses are stubbed via #if os(Windows).
typedef void *CZlibHostDummy;
#else
#include <zlib.h>
#endif
