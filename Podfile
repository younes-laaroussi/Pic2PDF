platform :ios, '17.0'

target 'Pic2PDF' do
  use_frameworks!

  # MediaPipe for on-device AI inference
  pod 'MediaPipeTasksGenAI', '0.10.24'
  pod 'MediaPipeTasksGenAIC', '0.10.24'

  # ZIPFoundation for extracting model files
  pod 'ZIPFoundation', '~> 0.9'
end

# Xcode 27 rejects deployment targets < iOS 15; lift pod targets to the app's platform.
post_install do |installer|
  installer.pods_project.targets.each do |t|
    t.build_configurations.each do |c|
      c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
    end
  end
end
