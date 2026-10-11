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
  report[:subscriptions] = report[:subscription_groups].flat_map do |group|
    begin
      client.all("/v1/subscriptionGroups/#{group.fetch(:id)}/subscriptions").map do |row|
        {id:row['id'],attributes:row.fetch('attributes',{}).select { |field,_| %w[name productId state subscriptionPeriod groupLevel].include?(field) }}
      end
    rescue TaipeiBusRelease::Error => error
      [{group_id:group[:id],error:error.message}]
    end
  end
end
File.write(File.join(ENV.fetch('RUNNER_TEMP'),'billing-audit.json'),JSON.pretty_generate(report)+"\n")
puts "Read-only billing audit saved for app #{id}. No contracts or payment settings changed."
