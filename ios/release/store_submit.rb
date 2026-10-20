require_relative 'apple_client'
require_relative 'review_bundle'

config = JSON.parse(File.read(File.join(__dir__, 'testflight.json')))
abort 'Public release is not enabled.' if config['distribution'] == 'testflight-only'
verification = JSON.parse(File.read(File.join(ENV.fetch('RUNNER_TEMP'), 'app-store-verification.json')))
abort 'Store verification does not match the requested update.' unless verification['version'] == (ENV['BUS_VERSION'].to_s.empty? ? config.fetch('version') : ENV['BUS_VERSION']) && verification['automatic_release'] && verification['price'] == 0
key = OpenSSL::PKey.read(ENV.fetch('ASC_PRIVATE_KEY').sub(/\A\uFEFF/, '').strip)
client = TaipeiBusRelease::Client.new(key_id: ENV.fetch('ASC_KEY_ID'), issuer_id: ENV.fetch('ASC_ISSUER_ID'), key: key)
version_id = verification.fetch('version_id')
version = client.request(:get, "/v1/appStoreVersions/#{version_id}", { include: 'build' }).fetch('data')
build_id = version.dig('relationships', 'build', 'data', 'id')
abort 'Expected build is missing.' unless build_id
build = client.request(:get, "/v1/builds/#{build_id}").fetch('data')
abort 'The selected build differs from the authorized exact build.' unless build.dig('attributes', 'version') == ENV.fetch('BUS_BUILD_NUMBER') && build.dig('attributes', 'processingState') == 'VALID' && build.dig('attributes', 'expired') == false
billing = JSON.parse(File.read(File.join(__dir__,'billing.json')))
bundle = TaipeiBusRelease::ReviewBundle.new(client,billing).prepare(version_id)
submission = client.request(:get,"/v1/reviewSubmissions/#{bundle.fetch(:submission_id)}").fetch('data')
if (%w[READY_FOR_REVIEW] + TaipeiBusRelease::ReviewBundle::RESUBMITTABLE_STATES).include?(submission.dig('attributes', 'state'))
  client.request(:patch, "/v1/reviewSubmissions/#{submission.fetch('id')}", {}, data: {
    type: 'reviewSubmissions', id: submission.fetch('id'), attributes: { submitted: true }
  })
end
saved = client.request(:get, "/v1/reviewSubmissions/#{submission.fetch('id')}").fetch('data')
abort 'Apple did not confirm the review submission.' unless %w[WAITING_FOR_REVIEW IN_REVIEW COMPLETE].include?(saved.dig('attributes', 'state'))
receipt = verification.merge(bundle).merge(status: 'submitted_for_app_review', submission_id: saved.fetch('id'), submission_state: saved.dig('attributes', 'state'), build_id: build_id, submitted_at: Time.now.utc.iso8601)
File.write(File.join(ENV.fetch('RUNNER_TEMP'), 'app-store-submitted.json'), JSON.pretty_generate(receipt) + "\n")
puts "Apple confirmed update #{verification.fetch('version')} submitted for review: #{saved.dig('attributes', 'state')}."
