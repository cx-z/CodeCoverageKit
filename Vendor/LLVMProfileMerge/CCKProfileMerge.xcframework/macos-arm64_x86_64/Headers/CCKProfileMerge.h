#ifndef CCK_PROFILE_MERGE_H
#define CCK_PROFILE_MERGE_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct { const void *bytes; size_t size; } CCKProfileInput;
typedef struct { void *bytes; size_t size; size_t records; uint64_t elapsed_microseconds; } CCKMergeResult;
/* Merges independent immutable raw-v10 LE64 frontend profiles; 0 succeeds, nonzero rejects the entire group.
 * Failure classes: 1 unsupported format/features, 2 invalid/read/write/verification, 3 budget, 4 deadline, 5 allocation.
 * Caller owns input lifetime and frees result.bytes with cck_profile_merge_free. No runtime counters are accessed.
 * Deadline checks are cooperative at reader/record/writer boundaries; one LLVM operation may overrun. */
int cck_profile_merge(const CCKProfileInput *inputs, size_t count, size_t max_input_bytes,
                      size_t max_output_bytes, size_t max_records, uint64_t timeout_milliseconds,
                      CCKMergeResult *result, char *error, size_t error_capacity);
/* Releases only the independent result allocation, on the calling worker. */
void cck_profile_merge_free(void *bytes);
#ifdef __cplusplus
}
#endif
#endif
