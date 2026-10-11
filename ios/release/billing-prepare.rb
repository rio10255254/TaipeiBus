require_relative 'apple_client'
require 'bigdecimal'
require 'date'

# Creates only the user-approved draft catalog. No review submission or contract acceptance.
config = JSON.parse(File.read(File.join(__dir__,'billing.json')))
abort 'Approved pricing is required.' unless config['approved_prices'] == true && ENV['BUS_PREPARE_BILLING'] == 'true'
abort 'Unexpected billing target.' unless config['bundle_id'] == 'com.rio10255254.TaipeiBus' && config['app_id'] == '6818475740'
key = OpenSSL::PKey.read(ENV.fetch('ASC_PRIVATE_KEY').sub(/\A\uFEFF/,'').strip)
client = TaipeiBusRelease::Client.new(key_id:ENV.fetch('ASC_KEY_ID'),issuer_id:ENV.fetch('ASC_ISSUER_ID'),key:key)
report = {app_id:config['app_id'],status:'preparing',products:[],production_submitted:false,agreements_changed:false}
receipt = File.join(ENV.fetch('RUNNER_TEMP'),'billing-setup.json')
save = -> { File.write(receipt,JSON.pretty_generate(report)+"\n") }
create = ->(path,type,attributes,relationships) {
  client.request(:post,path,{},data:{type:type,attributes:attributes,relationships:relationships}).fetch('data')
}
link = ->(type,id) { {data:{type:type,id:id}} }
version_for = ->(parent_type,parent,version_type,relationship) {
  values = client.all("/v1/#{parent_type}/#{parent}/versions")
  values.find { |row| %w[PREPARE_FOR_SUBMISSION DEVELOPER_ACTION_NEEDED REJECTED].include?(row.dig('attributes','state')) } ||
    values.first || create.call("/v1/#{version_type}",version_type,{}, {relationship=>link.call(parent_type,parent)})
}
localize = ->(type,version_type,version,attributes) {
  values = client.all("/v1/#{version_type}/#{version}/localizations")
  existing = values.find { |row| row.dig('attributes','locale') == attributes.fetch(:locale) }
  if existing
    next existing
  end
  create.call("/v2/#{type}",type,attributes,{version:link.call(version_type,version)})
}
begin
  app = client.all('/v1/apps','filter[bundleId]'=>config.fetch('bundle_id')).first
  raise TaipeiBusRelease::Error,'App identity mismatch.' unless app && app['id'] == config['app_id']
  groups = client.all("/v1/apps/#{app['id']}/subscriptionGroups")
  group = groups.find { |row| row.dig('attributes','referenceName') == config['group_name'] } ||
    create.call('/v1/subscriptionGroups','subscriptionGroups',{referenceName:config['group_name']},{app:link.call('apps',app['id'])})
  report[:group_id] = group['id']; save.call
  group_version = version_for.call('subscriptionGroups',group['id'],'subscriptionGroupVersions',:subscriptionGroup)
  report[:group_version_id] = group_version['id']; save.call
  [['zh-Hant','台北公車 Pro'],['en-US','Taipei Bus Pro']].each do |locale,name|
    localize.call('subscriptionGroupLocalizations','subscriptionGroupVersions',group_version['id'],{locale:locale,name:name})
  end
  products = client.all("/v1/subscriptionGroups/#{group['id']}/subscriptions")
  config.fetch('products').each do |expected|
    item = products.find { |row| row.dig('attributes','productId') == expected['product_id'] } ||
      create.call('/v1/subscriptions','subscriptions',
        {name:expected['name'],productId:expected['product_id'],subscriptionPeriod:expected['period'],groupLevel:1,
         familySharable:false},
        {group:link.call('subscriptionGroups',group['id'])})
    raise TaipeiBusRelease::Error,'Existing product period differs.' unless item.dig('attributes','subscriptionPeriod') == expected['period']
    row = {product_id:expected['product_id'],id:item['id'],period:expected['period'],requested_price:expected['price'],state:item.dig('attributes','state')}
    report[:products] << row; save.call
    version = version_for.call('subscriptions',item['id'],'subscriptionVersions',:subscription)
    row[:version_id] = version['id']; save.call
    client.request(:patch,"/v1/subscriptions/#{item['id']}",{},data:{type:'subscriptions',id:item['id'],attributes:{
      reviewNote:'Open Information and settings > Taipei Bus Pro > View Pro plans. Both plans unlock saved commute shortcuts and personal route preferences. Eligible accounts receive one seven-day free trial per subscription group, then renew at the displayed Apple price. Core navigation, official arrivals and 3D tracking remain free. No app login is required.'}})
    [['zh-Hant',expected['period'] == 'ONE_MONTH' ? 'Pro 月費' : 'Pro 年費','常用行程捷徑與個人路線偏好'],
     ['en-US',expected['name'],'Saved trips and personal route preferences']].each do |locale,name,description|
      localize.call('subscriptionLocalizations','subscriptionVersions',version['id'],{locale:locale,name:name,description:description})
    end
    points = client.all("/v1/subscriptions/#{item['id']}/pricePoints",'filter[territory]'=>config['territory'],'limit'=>'200')
    price = points.find { |point| BigDecimal(point.dig('attributes','customerPrice')) == BigDecimal(expected['price']) }
    unless price
      row[:status] = 'exact_price_unavailable'
      row[:nearby_prices] = points.sort_by { |point| (BigDecimal(point.dig('attributes','customerPrice'))-BigDecimal(expected['price'])).abs }
        .first(5).map { |point| point.dig('attributes','customerPrice') }
      save.call; next
    end
    availability = client.all("/v1/subscriptions/#{item['id']}/planAvailabilities")
    if availability.empty?
      create.call('/v1/subscriptionPlanAvailabilities','subscriptionPlanAvailabilities',
        {planType:'UPFRONT',availableInNewTerritories:false},
        {subscription:link.call('subscriptions',item['id']),availableTerritories:{data:[{type:'territories',id:config['territory']}]}})
    end
    existing_prices = client.all("/v1/subscriptions/#{item['id']}/prices",'filter[territory]'=>config['territory'],'filter[planType]'=>'UPFRONT','include'=>'subscriptionPricePoint')
    exact = existing_prices.any? { |value| value.dig('relationships','subscriptionPricePoint','data','id') == price['id'] }
    if !exact && !existing_prices.empty?
      row[:status] = 'existing_price_requires_review'; save.call; next
    end
    unless exact
      create.call('/v1/subscriptionPrices','subscriptionPrices',{startDate:nil,planType:'UPFRONT',preserveCurrentPrice:true},
        {subscription:link.call('subscriptions',item['id']),subscriptionPricePoint:link.call('subscriptionPricePoints',price['id']),territory:link.call('territories',config['territory'])})
    end
    row[:price_point_id] = price['id']; row[:configured_price] = price.dig('attributes','customerPrice')
    trial = config.fetch('trial')
    if trial['approved'] && trial['days'] == 7 && trial['mode'] == 'FREE_TRIAL'
      offers = client.all("/v1/subscriptions/#{item['id']}/introductoryOffers",'include'=>'territory')
      current = offers.find { |offer| offer.dig('relationships','territory','data','id') == trial['territory'] &&
        (offer.dig('attributes','endDate').nil? || offer.dig('attributes','endDate') >= Date.today.iso8601) }
      if current && (current.dig('attributes','offerMode') != 'FREE_TRIAL' || current.dig('attributes','duration') != 'ONE_WEEK')
        row[:status] = 'existing_trial_requires_review'; save.call; next
      end
      offer = current || create.call('/v1/subscriptionIntroductoryOffers','subscriptionIntroductoryOffers',
        {startDate:Date.today.iso8601,duration:'ONE_WEEK',numberOfPeriods:1,offerMode:'FREE_TRIAL',targetSubscriptionPlanType:'UPFRONT'},
        {subscription:link.call('subscriptions',item['id']),territory:link.call('territories',trial['territory'])})
      row[:trial_days] = 7; row[:introductory_offer_id] = offer['id']
    end
    row[:status] = 'draft_configured'; save.call
  end
  report[:status] = report[:products].all? { |row| row[:status] == 'draft_configured' } ? 'draft_catalog_configured' : 'needs_price_review'
rescue TaipeiBusRelease::Error => error
  report[:status] = 'apple_setup_blocked'; report[:error] = error.message; report[:diagnostics] = error.diagnostics
ensure
  save.call
end
puts "Billing setup: #{report[:status]}. No App Review submission, contract acceptance or customer charge occurred."
