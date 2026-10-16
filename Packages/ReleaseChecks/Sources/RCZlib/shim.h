#if defined(_WIN32)
// zlib.h is not available on Windows (no system zlib). The RCZlib module
// is a no-op on Windows; BundleHygiene.inflate is stubbed out via
// #if os(Windows) in Swift.
typedef void *RCZlibDummy;
#else
#include <zlib.h>
#endif
