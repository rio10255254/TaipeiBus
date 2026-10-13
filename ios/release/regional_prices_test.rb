require 'minitest/autorun'
require_relative 'regional_prices'

class RegionalPricesTest < Minitest::Test
  class Catalog
    attr_reader :writes
    attr_accessor :sales
    def initialize
      @writes=[]; @sales=['TWN']
      @points=(0...150).map { |n| point('A'+(65+n/26).chr+(65+n%26).chr) }
      @prices=[price('TWN','anchor'),price('AAA','existing-foreign-price')]
    end
    def all(path,query={})
      return @points if path.end_with?('/equalizations')
      return @prices if path.end_with?('/prices')
      return [{'id'=>'avail','attributes'=>{'planType'=>'UPFRONT','availableInNewTerritories'=>false}}] if path.end_with?('/planAvailabilities')
      return @sales.map { |id| {'id'=>id} } if path.end_with?('/availableTerritories')
      raise "Unexpected request #{path}"
    end
    def request(method,path,query={},body=nil)
      raise 'Only price creation may change the catalog' unless method==:post && path=='/v1/subscriptionPrices'
      @writes << body
      row=body.fetch(:data)
      @prices << price(row.dig(:relationships,:territory,:data,:id),row.dig(:relationships,:subscriptionPricePoint,:data,:id))
      {'data'=>@prices.last}
    end
    def point(id) = {'id'=>"point-#{id}",'relationships'=>{'territory'=>{'data'=>{'id'=>id}}}}
    def price(territory,point) = {'attributes'=>{},'relationships'=>{'territory'=>{'data'=>{'id'=>territory}},'subscriptionPricePoint'=>{'data'=>{'id'=>point}}}}
  end
  def setup
    @client=Catalog.new
    @anchor={'id'=>'anchor','attributes'=>{'customerPrice'=>'39'}}
  end
  def test_fills_only_missing_prices_and_keeps_taiwan_sales_and_price
    result=TaipeiBusRelease::RegionalPrices.new(@client).complete('month',@anchor,'39')
    assert_equal 149,result[:added_prices]
    assert_equal 151,result[:priced_territories]
    assert_equal ['TWN'],result[:sales_territories]
    refute @client.writes.any? { |body| %w[TWN AAA].include?(body.dig(:data,:relationships,:territory,:data,:id)) }
    assert @client.writes.all? { |body| body.dig(:data,:attributes,:planType)=='UPFRONT' }
  end
  def test_rerun_does_not_duplicate_or_change_prices
    service=TaipeiBusRelease::RegionalPrices.new(@client)
    service.complete('month',@anchor,'39'); @client.writes.clear
    assert_equal 0,service.complete('month',@anchor,'39')[:added_prices]
    assert_empty @client.writes
  end
  def test_unapproved_anchor_stops_before_any_write
    assert_raises(TaipeiBusRelease::Error) { TaipeiBusRelease::RegionalPrices.new(@client).complete('month',@anchor,'49') }
    assert_empty @client.writes
  end
  def test_an_expanded_sales_region_stops_before_any_write
    @client.sales=['TWN','USA']
    assert_raises(TaipeiBusRelease::Error) { TaipeiBusRelease::RegionalPrices.new(@client).complete('month',@anchor,'39') }
    assert_empty @client.writes
  end
  def test_explicit_repricing_updates_equalizations_but_never_taiwan_or_sales
    result=TaipeiBusRelease::RegionalPrices.new(@client).complete('month',@anchor,'39',replace_equalizations:true)
    assert_equal 150,result[:added_prices]
    assert_equal ['TWN'],@client.sales
    refute @client.writes.any? { |body| body.dig(:data,:relationships,:territory,:data,:id)=='TWN' }
  end
end
