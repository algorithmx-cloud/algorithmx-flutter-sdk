Pod::Spec.new do |s|
  s.name             = 'algorithmx_flutter'
  s.version          = '1.0.0'
  s.summary          = 'Flutter bridge for the native AlgorithmX engagement SDK.'
  s.description      = 'Provides the full AlgorithmX iOS SDK through Flutter method channels.'
  s.homepage         = 'https://github.com/algorithmx-cloud/algorithmx-flutter-sdk'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'AlgorithmX' => 'hello@algorithmx.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'algorithmx_flutter/Sources/algorithmx_flutter/**/*.swift'
  # The native SDK's Apple privacy manifest (synced with the sources).
  s.resource_bundles = { 'algorithmx_flutter_privacy' => ['algorithmx_flutter/Sources/algorithmx_flutter/NativeSDK/PrivacyInfo.xcprivacy'] }
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.9'
  s.static_framework = true

  # The native SDK is vendored under Sources/NativeSDK, so host applications
  # do not need a separate AlgorithmXSDK CocoaPod or a custom Podfile entry.
  s.dependency 'Flutter'
  s.frameworks = 'UIKit', 'WebKit', 'UserNotifications', 'Network'
  s.libraries = 'sqlite3'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
