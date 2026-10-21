# Read only. Persist no tester identity, email, full crash log or device identifier.
require_relative 'apple_client'
require 'digest'

config = JSON.parse(File.read(File.join(__dir__, 'testflight.json')))
key = OpenSSL::PKey.read(ENV.fetch('ASC_PRIVATE_KEY').sub(/\A\uFEFF/, '').strip)
client = TaipeiBusRelease::Client.new(key_id: ENV.fetch('ASC_KEY_ID'), issuer_id: ENV.fetch('ASC_ISSUER_ID'), key: key)
release = TaipeiBusRelease::Release.new(client, config)
number = ENV.fetch('BUS_BUILD_NUMBER')
abort 'An exact existing beta build is required.' unless number.match?(/\A\d{1,4}(?:\.\d{1,2}){0,2}\z/)
build = release.exact_build(number)
abort 'The selected beta build does not exist.' unless build
app_id, build_id = release.app.fetch('id'), build.fetch('id')
report = {version: release.version, build_number: number, status: 'read_only', reports: [], checked_at: Time.now.utc.iso8601}
begin
  rows = client.all("/v1/apps/#{app_id}/betaFeedbackCrashSubmissions",
    'filter[build]' => build_id, 'limit' => '50',
    'fields[betaFeedbackCrashSubmissions]' => 'createdDate,deviceModel,osVersion,buildBundleId')
  report[:count] = rows.length
  rows.first(5).each do |row|
    attributes = row.fetch('attributes', {})
    entry = attributes.slice('createdDate', 'deviceModel', 'osVersion', 'buildBundleId')
    begin
      log = client.request(:get, "/v1/betaFeedbackCrashSubmissions/#{row.fetch('id')}/crashLog").dig('data', 'attributes', 'logText').to_s
      entry[:log_sha256] = Digest::SHA256.hexdigest(log)
      entry[:summary] = log.lines.select { |line|
        line.match?(/\A(?:Exception Type|Exception Subtype|Termination Reason|Application Specific Information):/) ||
          line.match?(/\A\s*\d+\s+(?:TaipeiBus(?:Widgets)?|SwiftUI|WidgetKit|libswiftCore)\s/)
      }.first(40).map { |line| line.strip.gsub(%r{/(?:private|var|Users)/\S+}, '<path>')[0, 500] }
    rescue TaipeiBusRelease::Error
      entry[:log_unavailable] = true
    end
    report[:reports] << entry
  end
  puts "Exact beta diagnostic submissions: #{report[:count]}; tester identities and raw logs are omitted."
rescue TaipeiBusRelease::Error => error
  report[:status] = 'diagnostics_unavailable'
  report[:error_type] = error.class.name
  puts 'Apple diagnostic summaries are unavailable; beta metadata is unchanged.'
ensure
  File.write(File.join(ENV.fetch('RUNNER_TEMP'), 'testflight-diagnostics.json'), JSON.pretty_generate(report) + "\n")
end
