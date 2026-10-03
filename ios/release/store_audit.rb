require_relative 'apple_client'

# Read-only account audit. Private review contact values never enter logs/artifacts.
config = JSON.parse(File.read(File.join(__dir__, 'testflight.json')))
key = OpenSSL::PKey.read(ENV.fetch('ASC_PRIVATE_KEY').sub(/\A\uFEFF/, '').strip)
client = TaipeiBusRelease::Client.new(key_id: ENV.fetch('ASC_KEY_ID'), issuer_id: ENV.fetch('ASC_ISSUER_ID'), key: key)
app = client.all('/v1/apps', 'filter[bundleId]' => config.fetch('bundle_id')).first
abort 'Apple app record not found.' unless app
id = app.fetch('id')
report = { app_id: id, name: app.dig('attributes', 'name'), primary_locale: app.dig('attributes', 'primaryLocale'),
           content_rights: app.dig('attributes', 'contentRightsDeclaration'), captured_at: Time.now.utc.iso8601 }
queries = {
  app_infos: ["/v1/apps/#{id}/appInfos", { include: 'appInfoLocalizations,ageRatingDeclaration,primaryCategory,secondaryCategory' }],
  versions: ["/v1/apps/#{id}/appStoreVersions", { include: 'appStoreVersionLocalizations,build,appStoreReviewDetail' }],
  availability: ["/v1/apps/#{id}/appAvailabilityV2", { include: 'territoryAvailabilities' }],
  pricing: ["/v1/apps/#{id}/appPriceSchedule", {}],
  beta_localizations: ["/v1/apps/#{id}/betaAppLocalizations", {}],
  submissions: ["/v1/apps/#{id}/reviewSubmissions", {}],
  builds: ['/v1/builds', { 'filter[app]' => id, 'limit' => '200' }]
}
def redacted(value)
  case value
  when Array then value.map { |item| redacted(item) }
  when Hash
    value.to_h do |key, item|
      if key.match?(/contact(?:FirstName|LastName|Phone|Email)|demoAccount(?:Name|Password)/i)
        [key + 'Present', !item.to_s.empty?]
      else
        [key, redacted(item)]
      end
    end
  else value
  end
end
queries.each do |name, (path, query)|
  begin
    report[name] = redacted(client.request(:get, path, query))
  rescue TaipeiBusRelease::Error => error
    report[name] = { error: error.message }
  end
end
path = File.join(ENV.fetch('RUNNER_TEMP'), 'app-store-audit.json')
File.write(path, JSON.pretty_generate(report) + "\n")
puts "Read-only App Store audit saved for app #{id}; contact values are redacted."
