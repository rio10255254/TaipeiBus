require_relative 'apple_client'
require 'digest'

config = JSON.parse(File.read(File.join(__dir__, 'testflight.json')))
key = OpenSSL::PKey.read(ENV.fetch('ASC_PRIVATE_KEY').sub(/\A\uFEFF/, '').strip)
client = TaipeiBusRelease::Client.new(key_id: ENV.fetch('ASC_KEY_ID'), issuer_id: ENV.fetch('ASC_ISSUER_ID'), key: key)
release = TaipeiBusRelease::Release.new(client, config)
number = ENV.fetch('BUS_BUILD_NUMBER')
abort 'Specify the exact existing TestFlight build.' unless number.match?(/\A\d{1,4}(?:\.\d{1,2}){0,2}\z/)
build = release.exact_build(number)
abort 'The exact existing build must be valid and unexpired.' unless build && build.dig('attributes','processingState') == 'VALID' && build.dig('attributes','expired') == false
app_id, build_id = release.app.fetch('id'), build.fetch('id')
read_copy = ->(type, relationship, parent, field) {
  client.all("/v1/#{type}","filter[#{relationship}]"=>parent).map do |row|
    {id:row.fetch('id'),locale:row.dig('attributes','locale'),text:row.dig('attributes',field)}
  end
}
report = {app_id:app_id,version:release.version,build_number:number,build_id:build_id,
  before_description:read_copy.call('betaAppLocalizations','app',app_id,'description'),
  before_test_notes:read_copy.call('betaBuildLocalizations','build',build_id,'whatsNew'),
  status:'read_only',formal_submission_changed:false,build_uploaded:false}
path = File.join(ENV.fetch('RUNNER_TEMP'),'testflight-metadata.json')
begin
  if ENV['BUS_UPDATE_BETA_METADATA'] == 'true'
    description = File.read(File.join(__dir__,config.fetch('description_file')))
    notes = File.read(File.join(__dir__,config.fetch('what_to_test_file')))
    abort 'TestFlight copy must be present and the build notes must identify the exact version.' unless !description.strip.empty? && notes.include?(release.version)
    release.localize('betaAppLocalizations','app',app_id,'description',description)
    release.localize('betaBuildLocalizations','build',build_id,'whatsNew',notes)
    report[:after_description] = read_copy.call('betaAppLocalizations','app',app_id,'description')
    report[:after_test_notes] = read_copy.call('betaBuildLocalizations','build',build_id,'whatsNew')
    locale = config.fetch('locale')
    raise TaipeiBusRelease::Error,'Apple did not save the expected TestFlight description.' unless report[:after_description].find { |row| row[:locale] == locale }&.fetch(:text) == description
    raise TaipeiBusRelease::Error,'Apple did not save the expected build test notes.' unless report[:after_test_notes].find { |row| row[:locale] == locale }&.fetch(:text) == notes
    report[:description_sha256] = Digest::SHA256.hexdigest(description)
    report[:test_notes_sha256] = Digest::SHA256.hexdigest(notes)
    report[:status] = 'metadata_updated_and_verified'
  end
  puts "TestFlight #{release.version} (#{number}): #{report[:status]}; no archive or formal submission."
ensure
  report[:checked_at] = Time.now.utc.iso8601
  File.write(path,JSON.pretty_generate(report)+"\n")
end
