require_relative 'apple_client'
require 'bigdecimal'

module TaipeiBusRelease
  # Apple validates a full price table even when sales are limited to Taiwan.
  # Fill only missing prices using Apple's equalizations; never enable another territory.
  class RegionalPrices
    def initialize(client) = @client = client
    def complete(subscription, anchor, approved_price)
      raise Error, 'Taiwan anchor price differs from approval.' unless BigDecimal(anchor.dig('attributes','customerPrice')) == BigDecimal(approved_price)
      verify_taiwan_sales(subscription)
      points = @client.all("/v1/subscriptionPricePoints/#{anchor.fetch('id')}/equalizations",'include'=>'territory','limit'=>'200')
      points = points.reject { |point| point.dig('relationships','territory','data','id') == 'TWN' }
      raise Error, 'Apple equalization table is incomplete.' unless points.length.between?(150,220) && points.all? { |point| point.dig('relationships','territory','data','id').to_s.match?(/\A[A-Z]{3}\z/) }
      prices = current(subscription)
      taiwan = prices.find { |price| price.dig('relationships','territory','data','id') == 'TWN' }
      raise Error, 'Approved Taiwan price is not saved.' unless taiwan && taiwan.dig('relationships','subscriptionPricePoint','data','id') == anchor.fetch('id')
      present = prices.map { |price| price.dig('relationships','territory','data','id') }
      added = []
      points.each do |point|
        territory = point.dig('relationships','territory','data','id')
        next if present.include?(territory)
        @client.request(:post,'/v1/subscriptionPrices',{},data:{type:'subscriptionPrices',
          attributes:{startDate:nil,planType:'UPFRONT',preserveCurrentPrice:true},relationships:{
            subscription:{data:{type:'subscriptions',id:subscription}},
            subscriptionPricePoint:{data:{type:'subscriptionPricePoints',id:point.fetch('id')}},
            territory:{data:{type:'territories',id:territory}}}})
        added << territory
      end
      saved = current(subscription)
      saved_territories = saved.map { |price| price.dig('relationships','territory','data','id') }.compact.uniq.sort
      raise Error, 'Apple has not saved every required price.' unless (points.map { |point| point.dig('relationships','territory','data','id') } - saved_territories).empty?
      saved_taiwan = saved.find { |price| price.dig('relationships','territory','data','id') == 'TWN' }
      raise Error, 'Taiwan price changed during completion.' unless saved_taiwan.dig('relationships','subscriptionPricePoint','data','id') == anchor.fetch('id')
      verify_taiwan_sales(subscription)
      {added_prices:added.length,priced_territories:saved_territories.length,sales_territories:['TWN']}
    end
    private
    def current(id)
      @client.all("/v1/subscriptions/#{id}/prices",'filter[planType]'=>'UPFRONT','include'=>'subscriptionPricePoint,territory','limit'=>'200')
        .select { |price| price.dig('attributes','endDate').nil? }
    end
    def verify_taiwan_sales(id)
      plan = @client.all("/v1/subscriptions/#{id}/planAvailabilities").find { |row| row.dig('attributes','planType') == 'UPFRONT' }
      territories = plan && @client.all("/v1/subscriptionPlanAvailabilities/#{plan.fetch('id')}/availableTerritories").map { |row| row.fetch('id') }.sort
      raise Error, 'Sales must stay limited to Taiwan.' unless plan && plan.dig('attributes','availableInNewTerritories') == false && territories == ['TWN']
    end
  end
end
