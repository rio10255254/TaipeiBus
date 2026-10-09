require 'xcodeproj'

path = File.expand_path('../TaipeiBus.xcodeproj', __dir__)
project = Xcodeproj::Project.open(path)
app = project.targets.find { |target| target.name == 'TaipeiBus' }
tests = project.targets.find { |target| target.name == 'TaipeiBusUsabilityTests' }
unless tests
  tests = project.new_target(:ui_test_bundle, 'TaipeiBusUsabilityTests', :ios, '17.0')
  tests.add_dependency(app)
  group = project.main_group.new_group('usability', 'usability')
  tests.source_build_phase.add_file_reference(group.new_file('JourneyUsabilityTests.swift'))
  tests.build_configurations.each do |config|
    config.build_settings.merge!('GENERATE_INFOPLIST_FILE' => 'YES',
      'PRODUCT_NAME' => '$(TARGET_NAME)', 'ONLY_ACTIVE_ARCH' => 'YES',
      'PRODUCT_BUNDLE_IDENTIFIER' => 'com.example.TaipeiBus.UsabilityTests',
      'TEST_TARGET_NAME' => 'TaipeiBus', 'SWIFT_VERSION' => '5.0',
      'TARGETED_DEVICE_FAMILY' => '1', 'CODE_SIGNING_ALLOWED' => 'NO')
  end
  project.save
end
group = project.main_group.groups.find { |item| item.path == 'usability' } || project.main_group.new_group('usability', 'usability')
existing = tests.source_build_phase.files.map { |item| item.file_ref&.path }
Dir.glob(File.join(__dir__, '*.swift')).sort.each do |source|
  name = File.basename(source)
  tests.source_build_phase.add_file_reference(group.new_file(name)) unless existing.include?(name)
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(app, tests, launch_target: true)
scheme.test_action.build_configuration = 'Debug'
scheme.save_as(path, 'TaipeiBusUsability')
