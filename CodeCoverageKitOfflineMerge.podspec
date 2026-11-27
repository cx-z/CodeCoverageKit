Pod::Spec.new do |spec|
  spec.name = 'CodeCoverageKitOfflineMerge'
  spec.version = '0.1.3'
  spec.summary = 'Optional LLVM offline profile merger for internal Coverage builds.'
  spec.homepage = 'https://github.com/cx-z/CodeCoverageKit'
  spec.license = { :type => 'Apache-2.0', :file => 'LICENSE' }
  spec.author = 'CodeCoverageKit Contributors'
  spec.source = { :git => 'https://github.com/cx-z/CodeCoverageKit.git', :tag => spec.version.to_s }
  spec.ios.deployment_target = '15.0'
  spec.swift_version = '5.9'
  spec.static_framework = true
  spec.dependency 'CodeCoverageKit/Core', '= 0.1.3'
  spec.source_files = 'ProfileMergeSupport/Sources/*.swift'
  spec.vendored_frameworks = 'ProfileMergeSupport/Artifacts/CCKProfileMerge.xcframework'
  spec.preserve_paths = 'ProfileMergeSupport/Artifacts/LLVM-LICENSE.txt'
  spec.prepare_command = 'python3 Tools/ProfileMerge/prepare_pod.py'
  spec.libraries = ['c++', 'z']
  spec.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS' => '$(inherited) CODE_COVERAGE_KIT_ENABLED CCK_OFFLINE_MERGE_SEPARATE_MODULE'
  }
end
