#import "CodeCoverageRuntimeBridge.h"

#if CODE_COVERAGE_KIT_ENABLED

#include <stdint.h>
#include <stdlib.h>

extern uint64_t __llvm_profile_get_size_for_buffer(void) __attribute__((weak_import));
extern int __llvm_profile_write_buffer(char *buffer) __attribute__((weak_import));

static NSString * const CodeCoverageRuntimeBridgeErrorDomain = @"CodeCoverageKit.RuntimeBridge";

@implementation CodeCoverageRuntimeBridge

/// Captures the process-wide LLVM profile runtime without resetting counters, or reports that the host is not instrumented.
+ (nullable NSData *)snapshotDataWithError:(NSError * _Nullable __autoreleasing *)error {
    if (__llvm_profile_get_size_for_buffer == NULL || __llvm_profile_write_buffer == NULL) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:CodeCoverageRuntimeBridgeErrorDomain
                                         code:4
                                     userInfo:@{NSLocalizedDescriptionKey: @"宿主进程未链接 LLVM profile runtime。"}];
        }
        return nil;
    }

    uint64_t size = __llvm_profile_get_size_for_buffer();
    if (size == 0 || size > (uint64_t)NSIntegerMax) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:CodeCoverageRuntimeBridgeErrorDomain
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"LLVM runtime 返回了无效的 profile buffer 大小。"}];
        }
        return nil;
    }

    void *buffer = malloc((size_t)size);
    if (buffer == NULL) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:CodeCoverageRuntimeBridgeErrorDomain
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"无法为 LLVM profile snapshot 分配内存。"}];
        }
        return nil;
    }

    int result = __llvm_profile_write_buffer((char *)buffer);
    if (result != 0) {
        free(buffer);
        if (error != NULL) {
            *error = [NSError errorWithDomain:CodeCoverageRuntimeBridgeErrorDomain
                                         code:3
                                     userInfo:@{NSLocalizedDescriptionKey: @"LLVM runtime 写入 profile buffer 失败。"}];
        }
        return nil;
    }

    return [NSData dataWithBytesNoCopy:buffer length:(NSUInteger)size freeWhenDone:YES];
}

@end

#endif
