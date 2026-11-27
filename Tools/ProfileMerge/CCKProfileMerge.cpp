#include "CCKProfileMerge.h"
#include "llvm/ProfileData/InstrProfReader.h"
#include "llvm/ProfileData/InstrProfWriter.h"
#include "llvm/Support/Endian.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/raw_ostream.h"
#include <chrono>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <new>
#include <exception>
using namespace llvm;

/// Copies a bounded diagnostic into caller-owned storage; no shared LLVM error handler is installed.
static int reject(int code, StringRef detail, char *error, size_t capacity) {
    if (error && capacity) std::snprintf(error, capacity, "%.*s", int(std::min(detail.size(), capacity - 1)), detail.data());
    return code;
}

/// Uses only local reader/writer state and rejects any partial, unsupported, over-budget or diagnostic-bearing group.
static int mergeImpl(const CCKProfileInput *inputs, size_t count, size_t maxInput,
                      size_t maxOutput, size_t maxRecords, uint64_t timeout,
                      CCKMergeResult *result, char *error, size_t capacity) {
    if (!result) return reject(2, "missing result", error, capacity);
    *result = {};
    if (!inputs || count < 2 || count > 64 || !maxInput || !maxOutput || !maxRecords || !timeout || timeout > 60000)
        return reject(3, "invalid budget", error, capacity);
    const auto started = std::chrono::steady_clock::now();
    const auto deadline = started + std::chrono::milliseconds(timeout);
    const auto expired = [&] { return std::chrono::steady_clock::now() >= deadline; };
    size_t inputBytes = 0, records = 0;
    for (size_t i = 0; i < count; ++i) {
        const auto &input = inputs[i];
        if (!input.bytes || input.size < 16) return reject(2, "truncated input", error, capacity);
        if (input.size > maxInput - inputBytes) return reject(3, "input budget", error, capacity);
        inputBytes += input.size;
        const auto *bytes = static_cast<const unsigned char *>(input.bytes);
        if (support::endian::read64le(bytes) != 0xff6c70726f667281ULL || support::endian::read64le(bytes + 8) != 10)
            return reject(1, "unsupported raw version or variant", error, capacity);
    }
    InstrProfWriter writer(true);
    std::vector<object::BuildID> expectedIds;
    for (size_t i = 0; i < count; ++i) {
        if (expired()) return reject(4, "reader deadline", error, capacity);
        const auto &input = inputs[i];
        auto readerOrError = InstrProfReader::create(MemoryBuffer::getMemBufferCopy(
            StringRef(static_cast<const char *>(input.bytes), input.size)));
        if (!readerOrError) return reject(2, toString(readerOrError.takeError()), error, capacity);
        auto &reader = **readerOrError;
        if (auto e = writer.mergeProfileKind(reader.getProfileKind())) return reject(2, toString(std::move(e)), error, capacity);
        for (auto &record : reader) {
            if (reader.getVersion() != 10) return reject(1, "unsupported concatenated raw variant", error, capacity);
            if (expired()) return reject(4, "record deadline", error, capacity);
            if (++records > maxRecords) return reject(3, "record budget", error, capacity);
            if (!record.BitmapBytes.empty() || record.getNumValueKinds() || !reader.getSymtab().getVTableNames().empty())
                return reject(1, "bitmap/value/vtable profiling not validated", error, capacity);
            std::string diagnostic;
            writer.addRecord(std::move(record), [&](Error e) { diagnostic = toString(std::move(e)); });
            if (!diagnostic.empty()) return reject(2, diagnostic, error, capacity);
        }
        if (auto e = reader.getError()) return reject(2, toString(std::move(e)), error, capacity);
        if (reader.getVersion() != 10) return reject(1, "unsupported concatenated raw variant", error, capacity);
        if (!reader.getSymtab().getVTableNames().empty()) return reject(1, "vtable profiling not validated", error, capacity);
        std::vector<object::BuildID> ids;
        if (auto e = reader.readBinaryIds(ids)) return reject(2, toString(std::move(e)), error, capacity);
        writer.addBinaryIds(ids);
        expectedIds.insert(expectedIds.end(), ids.begin(), ids.end());
    }
    if (expired()) return reject(4, "writer deadline", error, capacity);
    std::string output;
    raw_string_ostream stream(output);
    if (auto e = writer.write(stream)) return reject(2, toString(std::move(e)), error, capacity);
    if (expired()) return reject(4, "writer deadline", error, capacity);
    if (output.size() > maxOutput) return reject(3, "output budget", error, capacity);
    auto verified = InstrProfReader::create(MemoryBuffer::getMemBufferCopy(output));
    if (!verified) return reject(2, toString(verified.takeError()), error, capacity);
    if ((*verified)->getVersion() != 12) return reject(1, "unexpected indexed version", error, capacity);
    for (auto &record : **verified) {
        (void)record;
        if (expired()) return reject(4, "verification deadline", error, capacity);
    }
    if (auto e = (*verified)->getError()) return reject(2, toString(std::move(e)), error, capacity);
    std::vector<object::BuildID> writtenIds;
    if (auto e = (*verified)->readBinaryIds(writtenIds)) return reject(2, toString(std::move(e)), error, capacity);
    std::sort(expectedIds.begin(), expectedIds.end());
    expectedIds.erase(std::unique(expectedIds.begin(), expectedIds.end()), expectedIds.end());
    std::sort(writtenIds.begin(), writtenIds.end());
    writtenIds.erase(std::unique(writtenIds.begin(), writtenIds.end()), writtenIds.end());
    if (expectedIds != writtenIds) return reject(2, "binary ID preservation failed", error, capacity);
    if (expired()) return reject(4, "verification deadline", error, capacity);

    void *bytes = std::malloc(output.size());
    if (!bytes) return reject(5, "result allocation", error, capacity);
    std::memcpy(bytes, output.data(), output.size());
    result->bytes = bytes;
    result->size = output.size();
    result->records = records;
    result->elapsed_microseconds = std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - started).count();
    return 0;
}

/// Converts LLVM/std allocation failures into local errors; no exception or process-wide error-handler mutation crosses C.
int cck_profile_merge(const CCKProfileInput *inputs, size_t count, size_t maxInput,
                      size_t maxOutput, size_t maxRecords, uint64_t timeout,
                      CCKMergeResult *result, char *error, size_t capacity) {
    try {
        return mergeImpl(inputs, count, maxInput, maxOutput, maxRecords, timeout, result, error, capacity);
    } catch (const std::bad_alloc &) {
        if (result) *result = {};
        return reject(5, "allocation failure", error, capacity);
    } catch (const std::exception &) {
        if (result) *result = {};
        return reject(2, "profile processing failure", error, capacity);
    }
}

/// Matches the C allocation contract without exposing LLVM ownership across the bridge.
void cck_profile_merge_free(void *bytes) { std::free(bytes); }
