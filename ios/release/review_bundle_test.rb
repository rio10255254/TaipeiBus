require 'minitest/autorun'
require_relative 'review_bundle'

class ReviewBundleTest < Minitest::Test
  class CatalogClient
    attr_reader :writes
    attr_accessor :price, :screenshot_state, :drop_item, :state
    def initialize
      @writes, @items, @created = [], [], false
      @price = '39'; @screenshot_state = 'COMPLETE'; @state = 'READY_FOR_REVIEW'
    end
    def all(path, query = {})
      case path
      when '/v1/apps/app/subscriptionGroups' then [row('group',referenceName:'Pro')]
      when '/v1/subscriptionGroups/group/versions' then [row('gv',version:1,state:'PREPARE_FOR_SUBMISSION')]
      when '/v1/subscriptionGroupVersions/gv/localizations' then localizations
      when '/v1/subscriptionGroups/group/subscriptions'
        [row('month',productId:'pro.monthly',subscriptionPeriod:'ONE_MONTH'),row('year',productId:'pro.yearly',subscriptionPeriod:'ONE_YEAR')]
      when %r{/v1/subscriptions/(month|year)/prices}
        raise 'Price validation must request the price point linkage' unless query['include'] == 'subscriptionPricePoint'
        [{'attributes'=>{},'relationships'=>{'subscriptionPricePoint'=>{'data'=>{'id'=>path.include?('month') ? 'mp' : 'yp'}}}}]
      when %r{/v1/subscriptions/(month|year)/planAvailabilities} then [row('avail',planType:'UPFRONT',availableInNewTerritories:false)]
      when '/v1/subscriptionPlanAvailabilities/avail/availableTerritories' then [{'id'=>'TWN'}]
      when %r{/v1/subscriptions/(month|year)/introductoryOffers}
        raise 'Trial validation must request the territory linkage' unless query['include'] == 'territory'
        [{'attributes'=>{'duration'=>'ONE_WEEK','offerMode'=>'FREE_TRIAL','numberOfPeriods'=>1},'relationships'=>{'territory'=>{'data'=>{'id'=>'TWN'}}}}]
      when %r{/v1/subscriptions/(month|year)/versions}
        [row(path.include?('month') ? 'mv' : 'yv',version:1,state:'PREPARE_FOR_SUBMISSION')]
      when %r{/v1/subscriptionVersions/(mv|yv)/localizations} then localizations
      when '/v1/apps/app/reviewSubmissions' then @created ? [row('draft',state:@state,platform:'IOS')] : []
      when '/v1/reviewSubmissions/draft/items'
        raise 'Review items must request their version linkages' unless query['include'] == 'appStoreVersion,subscriptionVersion,subscriptionGroupVersion'
        @items
      else raise "Unexpected GET #{path}"
      end
    end
    def request(method,path,query={},body=nil)
      if method == :get
        return {'data'=>row(path.end_with?('mp') ? 'mp' : 'yp',customerPrice:path.end_with?('mp') ? @price : '390')} if path.start_with?('/v1/subscriptionPricePoints/')
        return {'data'=>row('shot',assetDeliveryState:{'state'=>@screenshot_state})} if path.end_with?('/appStoreReviewScreenshot')
        raise "Unexpected GET #{path}"
      end
      @writes << [method,path,body]
      if path == '/v1/reviewSubmissions'
        @created = true
        return {'data'=>row('draft',state:@state,platform:'IOS')}
      end
      raise 'Only draft item creation is allowed' unless method == :post && path == '/v1/reviewSubmissionItems'
      relationships = JSON.parse(JSON.generate(body.fetch(:data).fetch(:relationships)))
      @items << {'id'=>"item-#{@items.length}",'relationships'=>relationships} unless @drop_item
      {'data'=>@items.last || {}}
    end
    def row(id, **attributes) = {'id'=>id,'attributes'=>attributes.transform_keys(&:to_s)}
    def localizations = %w[zh-Hant en-US].map { |locale| row(locale,locale:locale,name:'Pro',description:'Trips and reminders') }
  end

  def setup
    @client = CatalogClient.new
    @config = {'app_id'=>'app','group_name'=>'Pro','production_submission_authorized'=>true,'products'=>[
      {'product_id'=>'pro.monthly','period'=>'ONE_MONTH','price'=>'39'},
      {'product_id'=>'pro.yearly','period'=>'ONE_YEAR','price'=>'390'}]}
  end
  def bundle = TaipeiBusRelease::ReviewBundle.new(@client,@config)
  def test_complete_draft_contains_app_group_and_both_plans_but_is_not_submitted
    result = bundle.prepare('app-version')
    assert result[:items_verified]
    assert_equal %w[appStoreVersions subscriptionVersions subscriptionVersions subscriptionGroupVersions],result[:targets].map { |t| t[:type] }
    assert_equal 5,@client.writes.length
    refute @client.writes.any? { |method,_,_| method == :patch }
  end
  def test_repeating_the_same_draft_does_not_duplicate_any_items
    bundle.prepare('app-version'); @client.writes.clear
    assert bundle.prepare('app-version')[:items_verified]
    assert_empty @client.writes
  end
  def test_unapproved_price_stops_before_creating_a_review_draft
    @client.price = '49'
    assert_raises(TaipeiBusRelease::Error) { bundle.prepare('app-version') }
    assert_empty @client.writes
  end
  def test_unprocessed_screenshot_stops_before_creating_a_review_draft
    @client.screenshot_state = 'FAILED'
    assert_raises(TaipeiBusRelease::Error) { bundle.prepare('app-version') }
    assert_empty @client.writes
  end
  def test_missing_readback_does_not_confirm_a_complete_submission
    @client.drop_item = true
    assert_raises(TaipeiBusRelease::Error) { bundle.prepare('app-version') }
  end
  def test_production_requires_the_human_authorization_flag
    assert_raises(TaipeiBusRelease::Error) { TaipeiBusRelease::ReviewBundle.new(@client,@config.merge('production_submission_authorized'=>false)) }
    assert_empty @client.writes
  end
end
