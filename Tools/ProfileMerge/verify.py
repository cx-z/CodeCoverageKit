#!/usr/bin/env python3
"""Isolated LLVM hit-equivalence and byte measurement. Synthetic desktop evidence is never true-device acceptance."""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import subprocess
import struct
import time
import uuid

HARNESS = r'''
#include "CCKProfileMerge.h"
#include <fstream>
#include <iterator>
#include <vector>
#include <cstdio>
#include <cstdlib>
#include <new>
#include <chrono>
#include <sys/resource.h>
// This single-threaded harness can fail std allocations only while the production bridge is executing.
static long allocationCountdown = -1;
// Injects allocator failure without adding any hook or shared state to the production library.
void *operator new(std::size_t size) {
  if (allocationCountdown == 0) { allocationCountdown=-1; throw std::bad_alloc(); }
  if (allocationCountdown > 0) --allocationCountdown;
  if (void *bytes=std::malloc(size ? size : 1)) return bytes;
  throw std::bad_alloc();
}
// Matches the fixture allocation implementation.
void operator delete(void *bytes) noexcept { std::free(bytes); }
// Drives the production C bridge, with independent files and no live runtime access.
int main(int argc, char **argv) {
  if (argc < 4) return 2;
  std::vector<std::vector<char>> storage;
  for (int i=2; i<argc; ++i) {
    std::ifstream file(argv[i], std::ios::binary);
    storage.emplace_back(std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>());
  }
  std::vector<CCKProfileInput> inputs;
  for (auto &bytes : storage) inputs.push_back({bytes.data(), bytes.size()});
  CCKMergeResult result{}; char error[512]{};
  auto timeout=std::getenv("CCK_TIMEOUT_MS");
  auto limit=std::getenv("CCK_MAX_OUTPUT_BYTES");
  auto failure=std::getenv("CCK_FAIL_ALLOCATION");
  if (failure) allocationCountdown=std::atol(failure);
  const auto started=std::chrono::steady_clock::now();
  int code=cck_profile_merge(inputs.data(), inputs.size(), 64*1024*1024, limit?std::atol(limit):100*1024*1024, 1000000, timeout?std::atol(timeout):10000, &result, error, sizeof(error));
  allocationCountdown=-1;
  if(code) {
    auto elapsed=std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now()-started).count();
    std::fprintf(stderr,"%d: %s\n", code,error);
    std::printf("{\"error_code\":%d,\"microseconds\":%lld}\n",code,(long long)elapsed);
    return code;
  }
  std::ofstream output(argv[1], std::ios::binary);
  output.write(static_cast<const char *>(result.bytes), result.size);
  struct rusage usage{}; getrusage(RUSAGE_SELF,&usage);
  std::printf("{\"microseconds\":%llu,\"records\":%zu,\"bytes\":%zu,\"peak_rss_bytes\":%ld}\n", (unsigned long long)result.elapsed_microseconds,result.records,result.size,usage.ru_maxrss);
  cck_profile_merge_free(result.bytes);
  return output.good()?0:6;
}
'''
C_SOURCE = r'''
#include <stdlib.h>
#include <stdio.h>
#include <pthread.h>
#include <stdatomic.h>
#include <unistd.h>
extern void __llvm_profile_set_filename(const char *);
extern int __llvm_profile_write_file(void);
static atomic_int running=1;
static atomic_int sink;
#define CONDITION(a,b) ((a)>2 && ((b)<8 || (a)==9))
/* Exercises an inline counter expression. */
static inline int inline_route(int n) { return n ? n*2 : 0; }
/* Combines short-circuit, macro and switch coverage. */
static int branch(int n) {
  if (CONDITION(n,n)) return inline_route(n);
  switch(n) { case 0:return 3; case 1:return 7; default:return n+1; }
}
/* Continues atomic-instrumented execution during file snapshots. */
static void *worker(void *arg) {
  while(atomic_load(&running)) { sink=branch(4); }
  return NULL;
}
/* Captures cumulative profiles without suspending the business counter updates. */
int main(int argc, char **argv) {
  int mode=argc>1?atoi(argv[1]):0;
  pthread_t threads[4];
  for(int i=0;i<4;i++) pthread_create(&threads[i],NULL,worker,NULL);
  sink=branch(mode);
  char path[4096];
  for(int i=0;i<16;i++) {
    snprintf(path,sizeof(path),"%s-%02d.profraw",argv[2],i);
    __llvm_profile_set_filename(path);
    if(__llvm_profile_write_file()) return 9;
    usleep(100);
  }
  atomic_store(&running,0);
  for(int i=0;i<4;i++) pthread_join(threads[i],NULL);
  snprintf(path,sizeof(path),"%s-final.profraw",argv[2]);
  __llvm_profile_set_filename(path);
  return branch(mode)==-1;
}
'''
CPP_SOURCE = r'''
#include <cstdlib>
#define BOTH(n) ((n)>0 && (n)<8)
/* Exercises a template instantiation and inline branch. */
template<class T> inline int choose(T n) { if(BOTH(n)) return n*2; return n?7:0; }
/* Selects one launch path without resetting counters. */
int main(int c,char **v) { for(int i=0;i<7;i++) { if(choose(c>1?std::atoi(v[1]):0)==-1) return 4; } return 0; }
'''
OBJC_SOURCE = r'''
#import <Foundation/Foundation.h>
@interface Route : NSObject
/// Declares an Objective-C branch-producing fixture method.
- (NSInteger)choose:(NSInteger)n;
@end
@implementation Route
/// Covers both Objective-C condition directions across launches.
- (NSInteger)choose:(NSInteger)n { if(n>0 && n<8) return n*2; return n?7:0; }
@end
/* Produces one independent Objective-C launch profile. */
int main(int c,char **v) { @autoreleasepool { Route *r=[Route new]; return [r choose:c>1?atoi(v[1]):0]==-1; } }
'''
SWIFT_SOURCE = '''
/// Exercises Swift short-circuit and switch coverage.
@inline(never) func route(_ n: Int) -> Int {
    if n > 0 && n < 8 { return n * 2 }
    switch n { case 0: return 3; case 1: return 7; default: return n + 1 }
}
let n = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 0 : 0
for i in 0..<7 { _ = route(n + i % 2) }
'''


def hit_projection(value, key=None):
    """Preserves all identities, coordinates, record presence, kinds and states; only execution counts become hit booleans."""
    if isinstance(value, dict):
        return {k: (bool(v) if k == 'count' and key == 'functions' else hit_projection(v, k)) for k, v in value.items()}
    if isinstance(value, list):
        if key in ('regions', 'target_regions', 'branches', 'segments'):
            converted=[]
            for record in value:
                row=list(record)
                for index in ({'regions': [4], 'target_regions': [4], 'branches': [4, 5], 'segments': [2]}[key]):
                    row[index]=bool(row[index])
                converted.append(row)
            return converted
        if key == 'source_region':
            result=list(value); result[4]=bool(result[4]); return result
        return [hit_projection(item, key) for item in value]
    return value


def multipart(metadata, payload):
    """Matches the SDK's deterministic complete three-field multipart, including provenance overhead."""
    boundary='code-coverage-kit-run-'+metadata['run_id']
    digest=hashlib.sha256(payload).hexdigest()
    extension='.profdata' if metadata.get('profile_format')=='indexed' else '.profraw'
    return (f'--{boundary}\r\nContent-Disposition: form-data; name="metadata"\r\nContent-Type: application/json\r\n\r\n'.encode()
        +json.dumps(metadata,ensure_ascii=False,sort_keys=True,separators=(',',':')).encode()
        +f'\r\n--{boundary}\r\nContent-Disposition: form-data; name="sha256"\r\n\r\n{digest}\r\n--{boundary}\r\nContent-Disposition: form-data; name="profile"; filename="{metadata["run_id"]}{extension}"\r\nContent-Type: application/octet-stream\r\n\r\n'.encode()
        +payload+f'\r\n--{boundary}--\r\n'.encode())


def main():
    """Builds fictional fixed-source binaries, compares every exported record, and writes measurements only to the given temp output."""
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--framework',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--developer-dir',default='/Applications/Xcode263.app/Contents/Developer')
    args=parser.parse_args(); root=args.output.resolve(); root.mkdir(parents=True,exist_ok=False)
    env=dict(os.environ,DEVELOPER_DIR=args.developer_dir,CLANG_MODULE_CACHE_PATH=str(root/'modules'))
    def run(command, **kw):
        return subprocess.run([str(x) for x in command],env=env,check=True,capture_output=True,**kw)
    tool=Path(__file__).resolve().parent
    (root/'harness.cpp').write_text(HARNESS)
    library=next((args.framework/'macos-arm64_x86_64').glob('*.a'))
    run(['xcrun','clang++','-std=c++17','-Os','-I'+str(tool/'include'),root/'harness.cpp',library,'-lz','-Wl,-dead_strip','-o',root/'merge'])
    results={}
    for language,source,compiler,options in (
        ('c',C_SOURCE,'clang',['-pthread','-fprofile-update=atomic']),
        ('cpp',CPP_SOURCE,'clang++',[]), ('m',OBJC_SOURCE,'clang',['-framework','Foundation']),
        ('swift',SWIFT_SOURCE,'swiftc',[])):
        path=root/('fixture.'+language); path.write_text(source)
        binary=root/('binary-'+language)
        flags=['-profile-generate','-profile-coverage-mapping'] if language=='swift' else ['-fprofile-instr-generate','-fcoverage-mapping','-O0']
        run(['xcrun',compiler,*flags,*options,path,'-o',binary])
        raw=[]; representatives=[]; launch_files=[]
        for launch,mode in enumerate((0,4,10)):
            prefix=root/(language+'-'+str(launch))
            local=dict(env,LLVM_PROFILE_FILE=str(prefix)+'.profraw')
            subprocess.run([str(binary),str(mode),str(prefix)],env=local,check=True,capture_output=True)
            files=sorted(root.glob(prefix.name+('-*.profraw' if language=='c' else '*.profraw'))); raw.extend(files); launch_files.append(files)
            representatives.append(next((p for p in files if 'final' in p.name),files[-1]))
        def merge_export(label, profiles):
            merged=root/(language+'-'+label+'.profdata')
            run(['xcrun','llvm-profdata','merge','-sparse',*profiles,'-o',merged])
            exported=json.loads(run(['xcrun','llvm-cov','export',binary,'-instr-profile='+str(merged)]).stdout)
            return merged,hit_projection(exported)
        same_launch_checks=[]
        for index,files in enumerate(launch_files):
            _,expected=merge_export('launch-'+str(index)+'-all',files)
            _,actual=merge_export('launch-'+str(index)+'-last',[representatives[index]])
            same_launch_checks.append(expected==actual)
        control,all_hits=merge_export('all',raw)
        _,representative_hits=merge_export('representatives',representatives)
        production=root/(language+'-client.profdata')
        metrics=json.loads(run([root/'merge',production,*raw]).stdout)
        scenarios={}
        for label,existing in (('no-existing',[]),('source-overlap',[raw[0]]),('retained-baseline',[control]),('later-raw',[raw[-1]])):
            _,expected=merge_export(label+'-control',[*existing,*raw])
            _,actual=merge_export(label+'-client',[*existing,production])
            scenarios[label]=expected==actual
            if expected!=actual: raise AssertionError(language+' '+label+' hit mismatch')
        sources=[]; baseline=[]
        outer={k:str(uuid.uuid4()) for k in ('run_id','cycle_id','build_id','device_id','launch_id')}
        outer.update(schema_version=1,process_id=123,captured_at='2026-01-01T00:00:00Z',app_state='active',trigger_reason='user_upload')
        # Byte measurement uses one real raw representative per launch, matching the SDK's two-layer choice.
        selected = representatives if all(same_launch_checks) else raw
        launch_ids = [str(uuid.uuid4()) for _ in launch_files]
        for source_index,profile in enumerate(selected):
            payload=profile.read_bytes(); md=dict(outer,run_id=str(uuid.uuid4()),launch_id=launch_ids[next(i for i,files in enumerate(launch_files) if profile in files)])
            canonical=json.dumps(md,ensure_ascii=False,sort_keys=True,separators=(',',':')).encode()
            sources.append(dict(run_id=md['run_id'],launch_id=md['launch_id'],process_id=123,captured_at=md['captured_at'],size=len(payload),sha256=hashlib.sha256(payload).hexdigest(),metadata_sha256=hashlib.sha256(canonical).hexdigest(),capture_sequence=source_index+1))
            baseline.append(len(gzip.compress(multipart(md,payload),compresslevel=6,mtime=0)))
        rep_output=root/(language+'-representative-client.profdata')
        rep_metrics=json.loads(run([root/'merge',rep_output,*selected]).stdout)
        md=dict(outer,run_id=str(uuid.uuid4()),profile_format='indexed',trigger_reason='cross_launch_merge',aggregation=dict(schema_version=1,merger_version='llvm-20.1.8/cck-1',sources=sorted(sources,key=lambda x:x['run_id'])))
        compressed=len(gzip.compress(multipart(md,rep_output.read_bytes()),compresslevel=6,mtime=0))
        sample=raw[0].read_bytes(); failures=0
        for cut in sorted(set([0,1,7,8,15,16,len(sample)//2,len(sample)-1])):
            truncated=root/'truncated.profraw'; truncated.write_bytes(sample[:cut])
            p=subprocess.run([str(root/'merge'),str(root/'invalid.profdata'),str(truncated),str(raw[-1])],env=env,capture_output=True)
            if p.returncode <= 0: raise AssertionError(('truncated input did not return error',language,cut,p.returncode))
            failures+=1
        # LLVM raw v10 has sixteen uint64 header fields (InstrProfData.inc); an empty segment can be skipped inside one iterator advance.
        empty = struct.pack('<16Q', 0xff6c70726f667281, 10, *([0] * 14))
        variant = struct.pack('<16Q', 0xff6c70726f667281, 10 | (1 << 60), *([0] * 14))
        padded = sample + b'\0' * ((-len(sample)) % 8)
        concatenations = [padded + sample, padded + variant + sample, padded + empty + variant + empty,
                          variant + sample, padded + variant, padded + empty + sample]
        for index, content in enumerate(concatenations):
            path = root / (language + '-concatenated-' + str(index) + '.profraw')
            path.write_bytes(content)
            rejected = subprocess.run([str(root/'merge'), str(root/'concatenated-output.profdata'), str(path), str(raw[-1])], env=env, capture_output=True)
            if rejected.returncode != 1: raise AssertionError(('concatenated input admitted', language, index, rejected.returncode))
        injected=[]
        for allocation in (0,1,5,20):
            faulty=dict(env,CCK_FAIL_ALLOCATION=str(allocation))
            p=subprocess.run([str(root/'merge'),str(root/'allocation.profdata'),str(raw[0]),str(raw[-1])],env=faulty,capture_output=True)
            if p.returncode < 0: raise AssertionError(('allocation crash',language,allocation,p.returncode))
            injected.append(p.returncode)
        if 5 not in injected: raise AssertionError('allocation error boundary not exercised')
        limited=dict(env,CCK_MAX_OUTPUT_BYTES='1')
        p=subprocess.run([str(root/'merge'),str(root/'limited.profdata'),str(raw[0]),str(raw[-1])],env=limited,capture_output=True)
        if p.returncode!=3: raise AssertionError('output limit did not fail closed')
        results[language]={'allocation_error_codes':injected,'all_raw_count':len(raw),'same_launch_representatives_equivalent':all_hits==representative_hits,'per_launch_equivalence':same_launch_checks,
            'cross_launch_scenarios':scenarios,'all_sources_merge':metrics,'representatives_merge':rep_metrics,
            'selected_source_count':len(selected),'raw_gzip_sum':sum(baseline),'max_raw_gzip_request':max(baseline),'merged_gzip_request':compressed,
            'savings_bytes':sum(baseline)-compressed,'three_attempt_merged_bytes':3*compressed,'truncation_errors':failures,'concatenation_rejections':len(concatenations)}
    large_source=root/'deadline.c'
    definitions=['/* A fixed synthetic function for reader/writer cost measurement. */\nint f%d(int n){if(n>%d)return n+1;return n-1;}\n'%(i,i%10) for i in range(5000)]
    large_source.write_text(''.join(definitions)+'/* Exercises every fixed function for a non-sparse writer cost measurement. */\nint main(void){int sum=0;'+''.join('sum+=f%d(4);'%i for i in range(5000))+'return sum==-1;}\n')
    large_binary=root/'deadline-binary'; large_raw=root/'deadline.profraw'
    run(['xcrun','clang','-O0','-fprofile-instr-generate','-fcoverage-mapping',large_source,'-o',large_binary])
    subprocess.run([str(large_binary)],env=dict(env,LLVM_PROFILE_FILE=str(large_raw)),check=True,capture_output=True)
    full=json.loads(run([root/'merge',root/'large.profdata',large_raw,large_raw]).stdout)
    deadline=subprocess.run([str(root/'merge'),str(root/'deadline-output.profdata'),str(large_raw),str(large_raw)],env=dict(env,CCK_TIMEOUT_MS='1'),capture_output=True)
    if deadline.returncode!=4: raise AssertionError('cooperative deadline not exercised')
    results['bounded_large_fixture']={'profile_bytes':large_raw.stat().st_size,'normal_merge':full,
        'one_ms_deadline':json.loads(deadline.stdout),'stopping_phase':deadline.stderr.decode().strip()}
    mcdc_source=root/'mcdc.c'
    mcdc_source.write_text('/* Keeps both conditions independently measurable. */\nint route(int a,int b){if(a&&b)return 4;return 0;}\n/* Produces a real MC/DC bitmap profile. */\nint main(int c,char **v){return route(c>1,c>2)==-1;}\n')
    mcdc_binary=root/'mcdc-binary'; mcdc_raw=root/'mcdc.profraw'
    run(['xcrun','clang','-fprofile-instr-generate','-fcoverage-mapping','-fcoverage-mcdc',mcdc_source,'-o',mcdc_binary])
    subprocess.run([str(mcdc_binary)],env=dict(env,LLVM_PROFILE_FILE=str(mcdc_raw)),check=True,capture_output=True)
    unsupported=subprocess.run([str(root/'merge'),str(root/'mcdc-output.profdata'),str(mcdc_raw),str(mcdc_raw)],env=env,capture_output=True)
    if unsupported.returncode!=1: raise AssertionError('unvalidated bitmap feature was not rejected')
    results['mcdc_rejected']=True
    results['scope']='Synthetic macOS fixtures only; no true-device, sudden-reboot or production-budget acceptance'
    results['linked_harness_bytes']=(root/'merge').stat().st_size
    (root/'measurements.json').write_text(json.dumps(results,ensure_ascii=False,indent=2))
    print(json.dumps(results,ensure_ascii=False,indent=2))


if __name__=='__main__':
    main()
