// Tiny shim for Swift interop with TPCircularBuffer. Swift's importer
// can't expand the function-like `TPCircularBufferInit` macro and can't
// see the atomic `fillCount` field; both are exposed via plain C
// functions here.

#ifndef TPCircularBufferSwift_h
#define TPCircularBufferSwift_h

#include "TPCircularBuffer.h"

#ifdef __cplusplus
extern "C" {
#endif

bool TPCBSwiftInit(TPCircularBuffer *buffer, uint32_t length);
uint32_t TPCBSwiftFillBytes(const TPCircularBuffer *buffer);
uint32_t TPCBSwiftLengthBytes(const TPCircularBuffer *buffer);

#ifdef __cplusplus
}
#endif

#endif
