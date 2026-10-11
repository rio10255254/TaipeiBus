require_relative 'apple_client'

# Read only. Never writes products, prices, contracts, tax or bank records.
config = JSON.parse(File.read(File.join(__dir__, 'testflight.json')))
key = OpenSSL::PKey.read(ENV.fetch('ASC_PRIVATE_KEY').sub(/\A\uFEFF/, '').strip)
client = TaipeiBusRelease::Client.new(key_id:ENV.fetch('ASC_KEY_ID'),issuer_id:ENV.fetch('ASC_ISSUER_ID'),key:key)
app = client.all('/v1/apps','filter[bundleId]'=>config.fetch('bundle_id')).first
abort 'Apple app not found.' unless app
id = app.fetch('id')
report = {app_id:id,captured_at:Time.now.utc.iso8601,commercial_agreements:'Account Holder website verification required'}
queries = {
  versions:["/v1/apps/#{id}/appStoreVersions",{}],
  purchases:["/v1/apps/#{id}/inAppPurchasesV2",{}],
  subscription_groups:["/v1/apps/#{id}/subscriptionGroups",{}]
}
queries.each do |name,(path,query)|
  begin
    report[name] = client.all(path,query).map do |row|
      {id:row['id'],type:row['type'],attributes:row.fetch('attributes',{}).select { |field,_| %w[versionString appStoreState referenceName productId inAppPurchaseType state name].include?(field) }}
    end
  rescue TaipeiBusRelease::Error => error
    report[name] = {error:error.message}
  end
end
if report[:subscription_groups].is_a?(Array)
  report[:subscription_groups].each do |group|
    group[:versions] = client.all("/v1/subscriptionGroups/#{group.fetch(:id)}/versions").map do |version|
      {id:version['id'],attributes:version['attributes'],localizations:client.all("/v1/subscriptionGroupVersions/#{version['id']}/localizations").map { |value| value['attributes'] }}
    end
    group[:legacy_localizations] = client.all("/v1/subscriptionGroups/#{group.fetch(:id)}/subscriptionGroupLocalizations").map { |value| value['attributes'] }
  end
  report[:subscriptions] = report[:subscription_groups].flat_map do |group|
    begin
      client.all("/v1/subscriptionGroups/#{group.fetch(:id)}/subscriptions").map do |row|
        item = {id:row['id'],attributes:row.fetch('attributes',{}).select { |field,_| %w[name productId state subscriptionPeriod groupLevel].include?(field) }}
        begin
          item[:legacy_localizations] = client.all("/v1/subscriptions/#{row['id']}/subscriptionLocalizations").map { |value| value['attributes'] }
          item[:legacy_availability] = client.request(:get,"/v1/subscriptions/#{row['id']}/subscriptionAvailability",'include'=>'availableTerritories')['data']
          item[:prices] = client.all("/v1/subscriptions/#{row['id']}/prices",'filter[territory]'=>'TWN','filter[planType]'=>'UPFRONT','include'=>'subscriptionPricePoint').map do |price|
            point_id = price.dig('relationships','subscriptionPricePoint','data','id')
            point = client.request(:get,"/v1/subscriptionPricePoints/#{point_id}").fetch('data')
            {id:price['id'],customer_price:point.dig('attributes','customerPrice'),attributes:price['attributes']}
          end
          item[:trials] = client.all("/v1/subscriptions/#{row['id']}/introductoryOffers",'include'=>'territory').map do |offer|
            {id:offer['id'],attributes:offer['attributes'],territory:offer.dig('relationships','territory','data','id')}
          end
          item[:availability] = client.all("/v1/subscriptions/#{row['id']}/planAvailabilities").map do |availability|
            {id:availability['id'],attributes:availability['attributes'],territories:client.all("/v1/subscriptionPlanAvailabilities/#{availability['id']}/availableTerritories").map { |territory| territory['id'] }}
          end
          item[:versions] = client.all("/v1/subscriptions/#{row['id']}/versions").map do |version|
            {id:version['id'],attributes:version['attributes'],
             localizations:client.all("/v1/subscriptionVersions/#{version['id']}/localizations").map { |value| value['attributes'] },
             images:client.all("/v1/subscriptionVersions/#{version['id']}/images").map { |image| {id:image['id'],attributes:image['attributes'].slice('fileName','assetDeliveryState','sourceFileChecksum')} }}
          end
          image = client.request(:get,"/v1/subscriptions/#{row['id']}/appStoreReviewScreenshot")['data']
          item[:review_screenshot] = image && {id:image['id'],attributes:image['attributes'].slice('fileName','assetDeliveryState','sourceFileChecksum')}
        rescue TaipeiBusRelease::Error => error
          item[:verification_error] = error.message; item[:diagnostics] = error.diagnostics
        end
        item
      end
    rescue TaipeiBusRelease::Error => error
      [{group_id:group[:id],error:error.message}]
    end
  end
end
File.write(File.join(ENV.fetch('RUNNER_TEMP'),'billing-audit.json'),JSON.pretty_generate(report)+"\n")
puts "Read-only billing audit saved for app #{id}. No contracts or payment settings changed."
