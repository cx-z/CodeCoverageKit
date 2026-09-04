#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Serial-queue-only bridge that captures the current LLVM counters into one independent raw profile buffer.
@interface CodeCoverageRuntimeBridge : NSObject

/// Returns a complete `.profraw` snapshot without resetting counters, or an error when the runtime cannot serialize it.
+ (nullable NSData *)snapshotDataWithError:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(snapshotData());

@end

NS_ASSUME_NONNULL_END
