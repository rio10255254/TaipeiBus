require_relative 'apple_client'

config = JSON.parse(File.read(File.join(__dir__, 'testflight.json')))
copy = JSON.parse(File.read(File.join(__dir__, 'app-store.zh-Hant.json')))
key = OpenSSL::PKey.read(ENV.fetch('ASC_PRIVATE_KEY').sub(/\A\uFEFF/, '').strip)
client = TaipeiBusRelease::Client.new(key_id: ENV.fetch('ASC_KEY_ID'), issuer_id: ENV.fetch('ASC_ISSUER_ID'), key: key)
release = TaipeiBusRelease::Release.new(client, config)
app_id = release.app.fetch('id')
version = client.all("/v1/apps/#{app_id}/appStoreVersions").find { |v| v.dig('attributes', 'platform') == 'IOS' && v.dig('attributes', 'versionString') == release.version }
abort 'Matching store version missing.' unless version
availability = client.request(:get, "/v1/apps/#{app_id}/appAvailabilityV2").fetch('data')
territories = client.all("/v2/appAvailabilities/#{availability.fetch('id')}/territoryAvailabilities", { include: 'territory', limit: '200' })
enabled = territories.select { |t| t.dig('attributes', 'available') }.map { |t| t.dig('relationships', 'territory', 'data', 'id') }.sort
abort 'Availability must be Taiwan only.' unless enabled == ['TWN']
abort 'Future countries must not be enabled automatically.' unless availability.dig('attributes', 'availableInNewTerritories') == false
prices = client.request(:get, "/v1/appPriceSchedules/#{app_id}/manualPrices", { include: 'appPricePoint,territory', limit: '200' })
taiwan_prices = prices.fetch('data').select { |p| p.dig('relationships', 'territory', 'data', 'id') == 'TWN' && p.dig('attributes', 'endDate').nil? }
abort 'Taiwan price missing.' if taiwan_prices.empty?
taiwan_prices.each do |price|
  point_id = price.dig('relationships', 'appPricePoint', 'data', 'id')
  point = prices.fetch('included', []).find { |p| p.fetch('type') == 'appPricePoints' && p.fetch('id') == point_id }
  abort 'Taiwan download must be free.' unless point && Float(point.dig('attributes', 'customerPrice')) == 0
end

localization = client.all("/v1/appStoreVersions/#{version.fetch('id')}/appStoreVersionLocalizations").find { |l| l.dig('attributes', 'locale') == config.fetch('locale') }
abort 'Traditional Chinese metadata missing.' unless localization
sets = client.all("/v1/appStoreVersionLocalizations/#{localization.fetch('id')}/appScreenshotSets")
# Apple's public API still names the current 6.9-inch media slot APP_IPHONE_67.
set = sets.find { |s| s.dig('attributes', 'screenshotDisplayType') == 'APP_IPHONE_67' }
abort '6.9-inch store screenshots missing.' unless set
shots_path = "/v1/appScreenshotSets/#{set.fetch('id')}/appScreenshots"
shots = client.all(shots_path)
abort 'At least three real app screenshots are required.' unless shots.length.between?(3, 10)
abort 'Screenshots are still processing or failed.' unless shots.all? { |s| s.dig('attributes', 'assetDeliveryState', 'state') == 'COMPLETE' }
abort 'Screenshots must match the actual 6.9-inch simulator capture.' unless shots.all? do |s|
  [s.dig('attributes', 'imageAsset', 'width'), s.dig('attributes', 'imageAsset', 'height')] == [1320, 2868]
end
if ENV['BUS_ORDER_SCREENSHOTS'] == 'true'
  desired = copy.fetch('screenshotOrder')
  names = shots.map { |s| s.dig('attributes', 'fileName') }
  abort 'A requested feature screenshot is missing; order unchanged.' unless (desired - names).empty?
  ordered = desired.map { |name| shots.find { |s| s.dig('attributes', 'fileName') == name } }
  ordered.concat(shots.reject { |s| desired.include?(s.dig('attributes', 'fileName')) })
  client.request(:patch, "/v1/appScreenshotSets/#{set.fetch('id')}/relationships/appScreenshots", {},
    data: ordered.map { |s| { type: 'appScreenshots', id: s.fetch('id') } })
  shots = client.all(shots_path)
  abort 'Saved screenshot order mismatch.' unless shots.first(desired.length).map { |s| s.dig('attributes', 'fileName') } == desired
end
report = { app_id: app_id, version: release.version, version_id: version.fetch('id'),
  state: version.dig('attributes', 'appStoreState'), enabled_territories: enabled,
  price: 0, currency: 'TWD', automatic_release: version.dig('attributes', 'releaseType') == 'AFTER_APPROVAL',
  screenshot_set_id: set.fetch('id'), screenshots: shots.map { |s|
    { id: s.fetch('id'), file_name: s.dig('attributes', 'fileName'), state: s.dig('attributes', 'assetDeliveryState', 'state'),
      width: s.dig('attributes', 'imageAsset', 'width'), height: s.dig('attributes', 'imageAsset', 'height') }
  },
  checked_at: Time.now.utc.iso8601 }
File.write(File.join(ENV.fetch('RUNNER_TEMP'), 'app-store-verification.json'), JSON.pretty_generate(report) + "\n")
puts "Verified free Taiwan availability and #{shots.length} fully processed native screenshots; state #{report[:state]}."
