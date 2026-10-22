require 'xcodeproj'

path = File.expand_path('../TaipeiBus.xcodeproj', __dir__)
project = Xcodeproj::Project.open(path)
app = project.targets.find { |target| target.name == 'TaipeiBus' }
group = project.main_group.groups.find { |item| item.path == 'ai' } || project.main_group.new_group('ai', 'ai')
[['TaipeiBusAITests', :unit_test_bundle, 'AIIntegrationTests.swift'],
 ['TaipeiBusAIUITests', :ui_test_bundle, 'AIUITests.swift']].each do |name, kind, source|
  target = project.targets.find { |item| item.name == name } || project.new_target(kind, name, :ios, '17.0')
  target.add_dependency(app) unless target.dependencies.any? { |item| item.target == app }
  unless target.source_build_phase.files.any? { |item| item.file_ref&.path == source }
    target.source_build_phase.add_file_reference(group.new_file(source))
  end
  target.build_configurations.each do |config|
    config.build_settings.merge!('GENERATE_INFOPLIST_FILE' => 'YES', 'PRODUCT_NAME' => '$(TARGET_NAME)',
      'ONLY_ACTIVE_ARCH' => 'YES', 'SWIFT_VERSION' => '5.0', 'TARGETED_DEVICE_FAMILY' => '1',
      'CODE_SIGNING_ALLOWED' => 'NO', 'PRODUCT_BUNDLE_IDENTIFIER' => "com.example.#{name}")
    if kind == :unit_test_bundle
      config.build_settings.merge!('TEST_HOST' => '$(BUILT_PRODUCTS_DIR)/TaipeiBus.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/TaipeiBus', 'BUNDLE_LOADER' => '$(TEST_HOST)')
    else
      config.build_settings['TEST_TARGET_NAME'] = 'TaipeiBus'
    end
  end
  scheme = Xcodeproj::XCScheme.new
  scheme.configure_with_targets(app, target, launch_target: true)
  scheme.test_action.build_configuration = 'Debug'
  scheme.save_as(path, name)
end
project.save
