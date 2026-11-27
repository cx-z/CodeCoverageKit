# Bundled LLVM instrumentation profile library

This SDK-owned static XCFramework is built from official LLVM 20.1.8 sources using `Tools/ProfileMerge/build.py` and the adjacent production C bridge. It is not the App instrumentation runtime. No LLVM source patches are applied.

Slices: iOS arm64, iOS Simulator arm64/x86_64, macOS arm64/x86_64. Deployment targets: iOS 15, macOS 12. Recipe: Xcode 26.3, CMake 3.31.6, Ninja 1.11.1.4; MinSizeRel, EH/RTTI enabled, hidden visibility, profile-data static dependency closure. The build script pins and authenticates LLVM and CMake source archives.

`checksums.json` binds the versioned binary/header/license files and bridge/build source hashes. Both CocoaPods and the root Swift Package consume this same artifact. `NOTICE.txt` combines the SDK and LLVM notices for CocoaPods acknowledgements; LLVM is Apache-2.0 WITH LLVM-exception.

To update, rebuild with the documented script into a fresh directory, run the production bridge and fixed-binary hit-equivalence validation, replace the framework/license, and regenerate checksums in the same SDK change. Commit the actual static library slices, not LFS pointers or developer-machine paths. The complete multi-architecture dependency occupies about 145 MB before Git compression; this is not the linked App increment. Device equality, performance and sudden-reboot acceptance remain separate.
