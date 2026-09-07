Pod::Spec.new do |spec|
  spec.name = 'CodeCoverageKit'
  spec.version = '0.1.0'
  spec.summary = 'LLVM coverage snapshot and upload support for internal iOS builds.'
  spec.description = <<-DESC
    CodeCoverageKit captures LLVM profile snapshots, persists pending Runs, and
    uploads them only after an explicit user action in an internal iOS build.
  DESC
  spec.homepage = 'https://github.com/cx-z/CodeCoverageKit'
  spec.license = {
    :type => 'Apache-2.0',
    :file => 'LICENSE'
  }
  spec.author = 'CodeCoverageKit Contributors'
  spec.source = {
    :git => 'https://github.com/cx-z/CodeCoverageKit.git',
    :tag => spec.version.to_s
  }
  spec.ios.deployment_target = '15.0'
  spec.swift_version = '5.9'
  spec.static_framework = true
  spec.source_files = [
    'Sources/CodeCoverageKit/**/*.swift',
    'Sources/CodeCoverageRuntimeBridge/**/*.{h,m}'
  ]
  spec.public_header_files = 'Sources/CodeCoverageRuntimeBridge/include/*.h'
  spec.frameworks = ['Foundation', 'UIKit']
  spec.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) CODE_COVERAGE_KIT_ENABLED=1',
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS' => '$(inherited) CODE_COVERAGE_KIT_ENABLED'
  }
  spec.user_target_xcconfig = {
    'OTHER_LDFLAGS' => '$(inherited) -fprofile-instr-generate'
  }
end
