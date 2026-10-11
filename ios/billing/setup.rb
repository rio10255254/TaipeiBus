require 'xcodeproj'
path = File.expand_path('../TaipeiBus.xcodeproj',__dir__)
project = Xcodeproj::Project.open(path)
app = project.targets.find { |target| target.name == 'TaipeiBus' }
tests = project.targets.find { |target| target.name == 'TaipeiBusBillingTests' } || project.new_target(:unit_test_bundle,'TaipeiBusBillingTests',:ios,'17.0')
tests.add_dependency(app) unless tests.dependencies.any? { |value| value.target == app }
group = project.main_group.groups.find { |value| value.path == 'billing' } || project.main_group.new_group('billing','billing')
existing = tests.source_build_phase.files.map { |value| value.file_ref&.path }
tests.source_build_phase.add_file_reference(group.new_file('ProPurchaseTests.swift')) unless existing.include?('ProPurchaseTests.swift')
resources = tests.resources_build_phase.files.map { |value| value.file_ref&.path }
tests.resources_build_phase.add_file_reference(group.new_file('ProProducts.storekit')) unless resources.include?('ProProducts.storekit')
tests.build_configurations.each do |config|
  config.build_settings.merge!('GENERATE_INFOPLIST_FILE'=>'YES','PRODUCT_NAME'=>'$(TARGET_NAME)',
    'ONLY_ACTIVE_ARCH'=>'YES','PRODUCT_BUNDLE_IDENTIFIER'=>'com.example.TaipeiBus.BillingTests',
    'SWIFT_VERSION'=>'5.0','TARGETED_DEVICE_FAMILY'=>'1','CODE_SIGNING_ALLOWED'=>'NO',
    'TEST_HOST'=>'$(BUILT_PRODUCTS_DIR)/TaipeiBus.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/TaipeiBus',
    'BUNDLE_LOADER'=>'$(TEST_HOST)')
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(app,tests,launch_target:true)
scheme.test_action.build_configuration = 'Debug'
scheme.save_as(path,'TaipeiBusBilling')
