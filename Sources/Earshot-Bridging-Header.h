// Bridging header that exposes vendored C utilities to Swift.
// Currently only TPCircularBuffer (lock-free SPSC ring buffer used to
// hand audio buffers from the input AUHAL's render proc to the output
// engine's AVAudioSourceNode without locks or allocations on the audio
// thread).

#ifndef Earshot_Bridging_Header_h
#define Earshot_Bridging_Header_h

#import "Vendor/TPCircularBuffer.h"
#import "Vendor/TPCircularBufferSwift.h"

#endif
