require 'xcodeproj'
require 'json'
require 'digest'
require 'open3'

path = File.expand_path('../TaipeiBus.xcodeproj', __dir__)
project = Xcodeproj::Project.open(path)
app = project.targets.find { |target| target.name == 'TaipeiBus' }
group = project.main_group.groups.find { |item| item.path == 'ai' } || project.main_group.new_group('ai', 'ai')
[['TaipeiBusAITests', :unit_test_bundle, 'AIIntegrationTests.swift'],
 ['TaipeiBusAIUITests', :ui_test_bundle, 'AIUITests.swift'],
 ['TaipeiBusAIBenchmarkTests', :unit_test_bundle, 'JourneyDeviceBenchmarkTests.swift']].each do |name, kind, source|
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
  if name == 'TaipeiBusAIBenchmarkTests'
    root = File.expand_path('../..', __dir__)
    commit, status = Open3.capture2('git', '-C', root, 'rev-parse', 'HEAD')
    raise 'Cannot identify benchmark source' unless status.success?
    dirty, = Open3.capture2('git', '-C', root, 'status', '--porcelain')
    sources = %w[ios/TaipeiBus/OnDeviceJourneyAssistant.swift ios/TransitCore/Sources/TransitCore/AssistantIntent.swift
                 ios/TaipeiBus/PlaceSearch.swift ios/TaipeiBus/JourneyBenchmark.swift ios/ai/journey-corpus.json
                 ios/ai/JourneyDeviceBenchmarkTests.swift]
    fingerprint = Digest::SHA256.new
    sources.each { |source| fingerprint.update(source).update(File.binread(File.join(root, source))) }
    File.write(File.join(__dir__, 'journey-build.json'), JSON.pretty_generate({
      'commit' => commit.strip, 'dirty' => (!dirty.empty?).to_s,
      'sourceSHA256' => fingerprint.hexdigest,
      'corpusSHA256' => Digest::SHA256.file(File.join(__dir__, 'journey-corpus.json')).hexdigest
    }) + "\n")
    %w[journey-corpus.json journey-build.json].each do |resource|
      unless target.resources_build_phase.files.any? { |item| item.file_ref&.path == resource }
        target.resources_build_phase.add_file_reference(group.files.find { |item| item.path == resource } || group.new_file(resource))
      end
    end
  end
  scheme = Xcodeproj::XCScheme.new
  scheme.configure_with_targets(app, target, launch_target: true)
  scheme.test_action.build_configuration = 'Debug'
  scheme.save_as(path, name)
end
project.save
