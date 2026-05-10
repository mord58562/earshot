#include "TPCircularBufferSwift.h"

bool TPCBSwiftInit(TPCircularBuffer *buffer, uint32_t length) {
    return _TPCircularBufferInit(buffer, length, sizeof(TPCircularBuffer));
}

uint32_t TPCBSwiftFillBytes(const TPCircularBuffer *buffer) {
    return buffer->fillCount;
}

uint32_t TPCBSwiftLengthBytes(const TPCircularBuffer *buffer) {
    return buffer->length;
}
