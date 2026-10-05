require_relative 'apple_client'

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
submissions = client.all("/v1/apps/#{verification.fetch('app_id')}/reviewSubmissions")
submission = submissions.find do |s|
  %w[READY_FOR_REVIEW WAITING_FOR_REVIEW IN_REVIEW].include?(s.dig('attributes', 'state')) &&
    client.all("/v1/reviewSubmissions/#{s.fetch('id')}/items").any? { |i| i.dig('relationships', 'appStoreVersion', 'data', 'id') == version_id }
end
unless submission
  abort 'Update is not editable for submission.' unless version.dig('attributes', 'appStoreState') == 'PREPARE_FOR_SUBMISSION'
  submission = client.request(:post, '/v1/reviewSubmissions', {}, data: {
    type: 'reviewSubmissions', attributes: { platform: 'IOS' }, relationships: { app: { data: { type: 'apps', id: verification.fetch('app_id') } } }
  }).fetch('data')
  client.request(:post, '/v1/reviewSubmissionItems', {}, data: {
    type: 'reviewSubmissionItems', relationships: {
      reviewSubmission: { data: { type: 'reviewSubmissions', id: submission.fetch('id') } },
      appStoreVersion: { data: { type: 'appStoreVersions', id: version_id } }
    }
  })
end
if submission.dig('attributes', 'state') == 'READY_FOR_REVIEW'
  client.request(:patch, "/v1/reviewSubmissions/#{submission.fetch('id')}", {}, data: {
    type: 'reviewSubmissions', id: submission.fetch('id'), attributes: { submitted: true }
  })
end
saved = client.request(:get, "/v1/reviewSubmissions/#{submission.fetch('id')}").fetch('data')
abort 'Apple did not confirm the review submission.' unless %w[WAITING_FOR_REVIEW IN_REVIEW COMPLETE].include?(saved.dig('attributes', 'state'))
receipt = verification.merge(status: 'submitted_for_app_review', submission_id: saved.fetch('id'), submission_state: saved.dig('attributes', 'state'), build_id: build_id, submitted_at: Time.now.utc.iso8601)
File.write(File.join(ENV.fetch('RUNNER_TEMP'), 'app-store-submitted.json'), JSON.pretty_generate(receipt) + "\n")
puts "Apple confirmed update #{verification.fetch('version')} submitted for review: #{saved.dig('attributes', 'state')}."
