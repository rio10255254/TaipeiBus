require_relative 'apple_client'
require_relative 'review_bundle'

at_exit do
  error = $!
  warn JSON.generate(error.diagnostics) if error.is_a?(TaipeiBusRelease::Error)
end

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
versions = client.all("/v1/apps/#{app_id}/appStoreVersions").select { |row| row.dig('attributes', 'platform') == 'IOS' }
version = versions.find { |row| row.dig('attributes', 'versionString') == release.version }
# Apple keeps a single unreleased version. Reuse a withdrawn or unsent one under the new
# number (for example 1.6.1 withdrawn, released as 1.7.0) instead of failing to add another.
pending = versions.find { |row| TaipeiBusRelease::EDITABLE_VERSION_STATES.include?(row.dig('attributes', 'appStoreState')) }
if !version && pending
  version = client.request(:patch, "/v1/appStoreVersions/#{pending.fetch('id')}", {}, data: {
    type: 'appStoreVersions', id: pending.fetch('id'), attributes: { versionString: release.version }
  }).fetch('data')
  abort 'Apple did not rename the unreleased version.' unless version.dig('attributes', 'versionString') == release.version
end
unless version
  version = client.request(:post, '/v1/appStoreVersions', {}, data: {
    type: 'appStoreVersions', attributes: { platform: 'IOS', versionString: release.version,
      copyright: copy.fetch('copyright'), releaseType: 'AFTER_APPROVAL' },
    relationships: { app: { data: { type: 'apps', id: app_id } } }
  }).fetch('data')
end
state = version.dig('attributes','appStoreState')
abort 'The matching editable App Store version is missing.' unless (TaipeiBusRelease::EDITABLE_VERSION_STATES + ['READY_FOR_REVIEW']).include?(state)
write_metadata = TaipeiBusRelease::EDITABLE_VERSION_STATES.include?(state)
if version.dig('attributes','appStoreState') == 'READY_FOR_REVIEW'
  # READY_FOR_REVIEW is still an unsent draft. Verify that fact before changing
  # its wording for the user-approved annual-price adjustment.
  drafts = client.all("/v1/apps/#{app_id}/reviewSubmissions")
  write_metadata = drafts.any? do |draft|
    next false unless draft.dig('attributes','state') == 'READY_FOR_REVIEW' && draft.dig('attributes','submittedDate').nil?
    client.all("/v1/reviewSubmissions/#{draft.fetch('id')}/items",'include'=>'appStoreVersion').any? { |item| item.dig('relationships','appStoreVersion','data','id') == version.fetch('id') }
  end
  abort 'The editable app version is not part of an unsent draft.' unless write_metadata
end
version_id = version.fetch('id')
# Restore the explicitly approved Taiwan storefront if Apple currently has no
# storefront enabled. Never silently disable an existing foreign storefront.
availability = client.request(:get,"/v1/apps/#{app_id}/appAvailabilityV2").fetch('data')
territories_path = "/v2/appAvailabilities/#{availability.fetch('id')}/territoryAvailabilities"
territories = client.all(territories_path, include:'territory',limit:'200')
enabled = territories.select { |row| row.dig('attributes','available') }.map { |row| row.dig('relationships','territory','data','id') }
abort 'Unexpected existing storefronts require review.' unless (enabled - ['TWN']).empty? && availability.dig('attributes','availableInNewTerritories') == false
taiwan = territories.find { |row| row.dig('relationships','territory','data','id') == 'TWN' }
abort 'Taiwan storefront record is missing.' unless taiwan
unless taiwan.dig('attributes','available')
  client.request(:patch,"/v1/territoryAvailabilities/#{taiwan.fetch('id')}",{},data:{
    type:'territoryAvailabilities',id:taiwan.fetch('id'),attributes:{available:true}})
end
saved_territories = client.all(territories_path, include:'territory',limit:'200')
abort 'Apple did not confirm Taiwan-only availability.' unless saved_territories.select { |row| row.dig('attributes','available') }.map { |row| row.dig('relationships','territory','data','id') } == ['TWN']
infos = client.all("/v1/apps/#{app_id}/appInfos")
info = infos.find { |row| row.dig('attributes', 'state') == 'PREPARE_FOR_SUBMISSION' || row.dig('attributes', 'appStoreState') == 'PREPARE_FOR_SUBMISSION' }
local_info = info && client.all("/v1/appInfos/#{info.fetch('id')}/appInfoLocalizations").find { |row| row.dig('attributes', 'locale') == config.fetch('locale') }
local_version = client.all("/v1/appStoreVersions/#{version_id}/appStoreVersionLocalizations").find { |row| row.dig('attributes', 'locale') == config.fetch('locale') }
unless local_version
  abort 'A prepared review draft must already have its localization.' unless write_metadata
  local_version = client.request(:post, '/v1/appStoreVersionLocalizations', {}, data: {
    type: 'appStoreVersionLocalizations', attributes: { locale: config.fetch('locale') },
    relationships: { appStoreVersion: { data: { type: 'appStoreVersions', id: version_id } } }
  }).fetch('data')
end

if write_metadata
client.request(:patch, "/v1/apps/#{app_id}", {}, data: {
  type: 'apps', id: app_id, attributes: { contentRightsDeclaration: 'USES_THIRD_PARTY_CONTENT' }
})
if local_info
  client.request(:patch, "/v1/appInfoLocalizations/#{local_info.fetch('id')}", {}, data: {
    type: 'appInfoLocalizations', id: local_info.fetch('id'),
    attributes: copy.slice('name', 'subtitle', 'privacyPolicyUrl')
  })
end
client.request(:patch, "/v1/appStoreVersionLocalizations/#{local_version.fetch('id')}", {}, data: {
  type: 'appStoreVersionLocalizations', id: local_version.fetch('id'),
  attributes: copy.slice('description', 'keywords', 'marketingUrl', 'promotionalText', 'supportUrl', 'whatsNew')
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
end

saved_app = client.request(:get, "/v1/apps/#{app_id}").fetch('data')
privacy_info = local_info || infos.flat_map { |item| client.all("/v1/appInfos/#{item.fetch('id')}/appInfoLocalizations") }.find { |row| row.dig('attributes', 'locale') == config.fetch('locale') }
saved_info = client.request(:get, "/v1/appInfoLocalizations/#{privacy_info.fetch('id')}").fetch('data')
saved_localization = client.request(:get, "/v1/appStoreVersionLocalizations/#{local_version.fetch('id')}").fetch('data')
saved_version = client.request(:get, "/v1/appStoreVersions/#{version_id}", { include: 'build' }).fetch('data')
saved_review = client.request(:get, "/v1/appStoreVersions/#{version_id}/appStoreReviewDetail").fetch('data')
abort 'Saved content rights mismatch.' unless saved_app.dig('attributes', 'contentRightsDeclaration') == 'USES_THIRD_PARTY_CONTENT'
abort 'Saved privacy URL mismatch.' unless saved_info.dig('attributes', 'privacyPolicyUrl') == copy.fetch('privacyPolicyUrl')
abort 'Saved build mismatch.' unless saved_version.dig('relationships', 'build', 'data', 'id') == build.fetch('id')
abort 'Saved release mode mismatch.' unless saved_version.dig('attributes', 'releaseType') == 'AFTER_APPROVAL'
abort 'Saved review contact mismatch.' unless fields.all? { |field| saved_review.dig('attributes', field) == contact[field] }
abort 'Saved description mismatch.' unless saved_localization.dig('attributes', 'description') == copy.fetch('description')
abort 'Saved update notes mismatch.' unless saved_localization.dig('attributes', 'whatsNew') == copy.fetch('whatsNew')
receipt = { app_id: app_id, version: release.version, version_id: version_id,
  build_id: build.fetch('id'), build_number: build_number, locale: config.fetch('locale'),
  status: 'metadata_and_build_prepared', automatic_release: true, review_contact_verified: true,
  privacy_policy_url: copy.fetch('privacyPolicyUrl'), localization_id: local_version.fetch('id'),
  description_verified: true, whats_new_verified: true, subtitle_updated: !local_info.nil?, captured_at: Time.now.utc.iso8601 }
File.write(File.join(ENV.fetch('RUNNER_TEMP'), 'app-store-receipt.json'), JSON.pretty_generate(receipt) + "\n")
begin
  billing = JSON.parse(File.read(File.join(__dir__,'billing.json')))
  receipt.merge!(TaipeiBusRelease::ReviewBundle.new(client,billing).prepare(version_id))
  receipt[:status] = 'metadata_build_and_review_bundle_prepared'
rescue TaipeiBusRelease::Error => error
  receipt.merge!(status:'review_bundle_requires_metadata',error:error.message,diagnostics:error.diagnostics)
  raise
ensure
  File.write(File.join(ENV.fetch('RUNNER_TEMP'),'app-store-receipt.json'),JSON.pretty_generate(receipt)+"\n")
end
puts "Verified App Store metadata and exact build #{release.version} (#{build_number}); contact values withheld."
