require_relative 'apple_client'

# Uses only Apple's documented public API. Review contact values stay in the
# repository secret and the Apple review record, never in logs or artifacts.
abort 'Choose store-prepare explicitly.' unless ENV['BUS_PUBLISH_TESTFLIGHT'] == 'true'
config = JSON.parse(File.read(File.join(__dir__, 'testflight.json')))
abort 'This is a TestFlight-only experiment; public App Store preparation is disabled.' if config['distribution'] == 'testflight-only'
copy = JSON.parse(File.read(File.join(__dir__, 'app-store.zh-Hant.json')))
contact = JSON.parse(ENV.fetch('APP_STORE_REVIEW_CONTACT'))
fields = %w[contactFirstName contactLastName contactPhone contactEmail]
abort 'Review contact is incomplete.' unless fields.all? { |field| !contact[field].to_s.strip.empty? }
key = OpenSSL::PKey.read(ENV.fetch('ASC_PRIVATE_KEY').sub(/\A\uFEFF/, '').strip)
client = TaipeiBusRelease::Client.new(key_id: ENV.fetch('ASC_KEY_ID'), issuer_id: ENV.fetch('ASC_ISSUER_ID'), key: key)
release = TaipeiBusRelease::Release.new(client, config)
app = release.app
app_id = app.fetch('id')
build_number = ENV.fetch('BUS_BUILD_NUMBER')
abort 'An exact uploaded build number is required.' if build_number.empty?
build = client.all('/v1/builds', release.build_query).find { |row| row.dig('attributes', 'version') == build_number }
abort 'The selected build must be valid and unexpired.' unless build && build.dig('attributes', 'processingState') == 'VALID' && build.dig('attributes', 'expired') == false
version = client.all("/v1/apps/#{app_id}/appStoreVersions").find do |row|
  row.dig('attributes', 'platform') == 'IOS' && row.dig('attributes', 'versionString') == release.version
end
abort 'The matching editable App Store version is missing.' unless version && version.dig('attributes', 'appStoreState') == 'PREPARE_FOR_SUBMISSION'
version_id = version.fetch('id')
info = client.all("/v1/apps/#{app_id}/appInfos").find { |row| row.dig('attributes', 'state') == 'PREPARE_FOR_SUBMISSION' }
abort 'Editable App Information is missing.' unless info
local_info = client.all("/v1/appInfos/#{info.fetch('id')}/appInfoLocalizations").find { |row| row.dig('attributes', 'locale') == config.fetch('locale') }
local_version = client.all("/v1/appStoreVersions/#{version_id}/appStoreVersionLocalizations").find { |row| row.dig('attributes', 'locale') == config.fetch('locale') }
abort 'Traditional Chinese localizations are missing.' unless local_info && local_version

client.request(:patch, "/v1/apps/#{app_id}", {}, data: {
  type: 'apps', id: app_id, attributes: { contentRightsDeclaration: 'USES_THIRD_PARTY_CONTENT' }
})
client.request(:patch, "/v1/appInfoLocalizations/#{local_info.fetch('id')}", {}, data: {
  type: 'appInfoLocalizations', id: local_info.fetch('id'),
  attributes: copy.slice('name', 'subtitle', 'privacyPolicyUrl')
})
client.request(:patch, "/v1/appStoreVersionLocalizations/#{local_version.fetch('id')}", {}, data: {
  type: 'appStoreVersionLocalizations', id: local_version.fetch('id'),
  attributes: copy.slice('description', 'keywords', 'marketingUrl', 'promotionalText', 'supportUrl')
})
review_attributes = contact.slice(*fields).merge('demoAccountRequired' => false, 'notes' => copy.fetch('reviewNotes'))
begin
  review = client.request(:get, "/v1/appStoreVersions/#{version_id}/appStoreReviewDetail").fetch('data')
rescue TaipeiBusRelease::Error => error
  raise unless error.message.include?('HTTP 404')
  review = nil
end
if review
  client.request(:patch, "/v1/appStoreReviewDetails/#{review.fetch('id')}", {}, data: {
    type: 'appStoreReviewDetails', id: review.fetch('id'), attributes: review_attributes
  })
else
  client.request(:post, '/v1/appStoreReviewDetails', {}, data: {
    type: 'appStoreReviewDetails', attributes: review_attributes,
    relationships: { appStoreVersion: { data: { type: 'appStoreVersions', id: version_id } } }
  })
end
client.request(:patch, "/v1/appStoreVersions/#{version_id}", {}, data: {
  type: 'appStoreVersions', id: version_id,
  attributes: { copyright: copy.fetch('copyright'), releaseType: 'AFTER_APPROVAL' },
  relationships: { build: { data: { type: 'builds', id: build.fetch('id') } } }
})

saved_app = client.request(:get, "/v1/apps/#{app_id}").fetch('data')
saved_info = client.request(:get, "/v1/appInfoLocalizations/#{local_info.fetch('id')}").fetch('data')
saved_version = client.request(:get, "/v1/appStoreVersions/#{version_id}", { include: 'build' }).fetch('data')
saved_review = client.request(:get, "/v1/appStoreVersions/#{version_id}/appStoreReviewDetail").fetch('data')
abort 'Saved content rights mismatch.' unless saved_app.dig('attributes', 'contentRightsDeclaration') == 'USES_THIRD_PARTY_CONTENT'
abort 'Saved privacy URL mismatch.' unless saved_info.dig('attributes', 'privacyPolicyUrl') == copy.fetch('privacyPolicyUrl')
abort 'Saved build mismatch.' unless saved_version.dig('relationships', 'build', 'data', 'id') == build.fetch('id')
abort 'Saved release mode mismatch.' unless saved_version.dig('attributes', 'releaseType') == 'AFTER_APPROVAL'
abort 'Saved review contact mismatch.' unless fields.all? { |field| saved_review.dig('attributes', field) == contact[field] }
receipt = { app_id: app_id, version: release.version, version_id: version_id,
  build_id: build.fetch('id'), build_number: build_number, locale: config.fetch('locale'),
  status: 'metadata_and_build_prepared', automatic_release: true, review_contact_verified: true,
  privacy_policy_url: copy.fetch('privacyPolicyUrl'), captured_at: Time.now.utc.iso8601 }
File.write(File.join(ENV.fetch('RUNNER_TEMP'), 'app-store-receipt.json'), JSON.pretty_generate(receipt) + "\n")
puts "Verified App Store metadata and exact build #{release.version} (#{build_number}); contact values withheld."
