require_relative 'apple_client'
require 'bigdecimal'

module TaipeiBusRelease
  # A draft contains the exact app build, group version and both subscription versions.
  # Adding items asks Apple to validate metadata; only store-submit sends the draft.
  class ReviewBundle
    def initialize(client, config)
      @client, @config = client, config
      raise Error, 'Production billing was not authorized.' unless config['production_submission_authorized'] == true
    end

    def expected_catalog
      group = @client.all("/v1/apps/#{@config.fetch('app_id')}/subscriptionGroups").find { |row| row.dig('attributes','referenceName') == @config.fetch('group_name') }
      raise Error, 'Expected Pro subscription group is missing.' unless group
      group_version = editable_version('subscriptionGroups', group.fetch('id'))
      group_names = @client.all("/v1/subscriptionGroupVersions/#{group_version.fetch('id')}/localizations")
      raise Error, 'Pro group names are incomplete.' unless %w[zh-Hant en-US].all? { |locale| group_names.any? { |row| row.dig('attributes','locale') == locale && !row.dig('attributes','name').to_s.empty? } }
      products = @client.all("/v1/subscriptionGroups/#{group.fetch('id')}/subscriptions")
      targets = []
      @config.fetch('products').each do |expected|
        item = products.find { |row| row.dig('attributes','productId') == expected.fetch('product_id') }
        raise Error, 'Expected subscription or period is missing.' unless item && item.dig('attributes','subscriptionPeriod') == expected.fetch('period')
        prices = @client.all("/v1/subscriptions/#{item.fetch('id')}/prices", 'filter[territory]' => 'TWN', 'filter[planType]' => 'UPFRONT', 'include' => 'subscriptionPricePoint')
        today = Time.now.utc.strftime('%Y-%m-%d')
        live_prices = prices.select { |row| row.dig('attributes','endDate').nil? && (row.dig('attributes','startDate').nil? || row.dig('attributes','startDate') <= today) }
        raise Error, 'Expected active Taiwan price is missing.' if live_prices.empty?
        live_prices.each do |price|
          point_id = price.dig('relationships','subscriptionPricePoint','data','id')
          raise Error, 'Apple did not return the referenced subscription price point.' if point_id.to_s.empty?
          point = @client.request(:get,"/v1/subscriptionPricePoints/#{point_id}").fetch('data')
          raise Error, 'Taiwan subscription price differs from approval.' unless BigDecimal(point.dig('attributes','customerPrice')) == BigDecimal(expected.fetch('price'))
        end
        plans = @client.all("/v1/subscriptions/#{item.fetch('id')}/planAvailabilities")
        upfront = plans.find { |row| row.dig('attributes','planType') == 'UPFRONT' }
        territories = upfront && @client.all("/v1/subscriptionPlanAvailabilities/#{upfront.fetch('id')}/availableTerritories").map { |row| row.fetch('id') }
        raise Error, 'Subscription availability differs from Taiwan-only approval.' unless upfront && upfront.dig('attributes','availableInNewTerritories') == false && territories == ['TWN']
        offers = @client.all("/v1/subscriptions/#{item.fetch('id')}/introductoryOffers")
        raise Error, 'Seven-day Taiwan introductory offer is missing.' unless offers.any? { |row| row.dig('relationships','territory','data','id') == 'TWN' && row.dig('attributes','offerMode') == 'FREE_TRIAL' && row.dig('attributes','duration') == 'ONE_WEEK' && row.dig('attributes','numberOfPeriods') == 1 && (row.dig('attributes','startDate').nil? || row.dig('attributes','startDate') <= today) && (row.dig('attributes','endDate').nil? || row.dig('attributes','endDate') >= today) }
        shot = @client.request(:get,"/v1/subscriptions/#{item.fetch('id')}/appStoreReviewScreenshot")['data']
        raise Error, 'Subscription review screenshot is not processed.' unless shot && shot.dig('attributes','assetDeliveryState','state') == 'COMPLETE'
        version = editable_version('subscriptions', item.fetch('id'))
        names = @client.all("/v1/subscriptionVersions/#{version.fetch('id')}/localizations")
        raise Error, 'Subscription name or description is incomplete.' unless %w[zh-Hant en-US].all? { |locale| names.any? { |row| row.dig('attributes','locale') == locale && row.dig('attributes','name').to_s.length.between?(2,30) && row.dig('attributes','description').to_s.length.between?(1,45) } }
        targets << {relationship: :subscriptionVersion, type: 'subscriptionVersions', id: version.fetch('id'), product_id: expected.fetch('product_id'), product_state: item.dig('attributes','state')}
      end
      targets << {relationship: :subscriptionGroupVersion, type: 'subscriptionGroupVersions', id: group_version.fetch('id')}
    end

    def prepare(app_version_id)
      targets = expected_catalog
      targets.unshift({relationship: :appStoreVersion, type: 'appStoreVersions', id: app_version_id})
      submissions = @client.all("/v1/apps/#{@config.fetch('app_id')}/reviewSubmissions")
      items_by_id = {}
      submission = submissions.find do |row|
        next false unless %w[READY_FOR_REVIEW WAITING_FOR_REVIEW IN_REVIEW].include?(row.dig('attributes','state'))
        items_by_id[row.fetch('id')] = @client.all("/v1/reviewSubmissions/#{row.fetch('id')}/items")
        items_by_id[row.fetch('id')].any? { |item| item.dig('relationships','appStoreVersion','data','id') == app_version_id }
      end
      submission ||= submissions.find { |row| row.dig('attributes','state') == 'READY_FOR_REVIEW' && row.dig('attributes','platform') == 'IOS' && (items_by_id[row.fetch('id')] ||= @client.all("/v1/reviewSubmissions/#{row.fetch('id')}/items")).empty? }
      submission ||= @client.request(:post,'/v1/reviewSubmissions',{},data:{type:'reviewSubmissions',attributes:{platform:'IOS'},relationships:{app:{data:{type:'apps',id:@config.fetch('app_id')}}}}).fetch('data')
      items = items_by_id[submission.fetch('id')] || []
      targets.each do |target|
        next if items.any? { |item| item.dig('relationships',target.fetch(:relationship).to_s,'data','id') == target.fetch(:id) }
        raise Error, 'Cannot add missing items after a submission was sent.' unless submission.dig('attributes','state') == 'READY_FOR_REVIEW'
        begin
          @client.request(:post,'/v1/reviewSubmissionItems',{},data:{type:'reviewSubmissionItems',relationships:{
            reviewSubmission:{data:{type:'reviewSubmissions',id:submission.fetch('id')}},
            target.fetch(:relationship)=>{data:{type:target.fetch(:type),id:target.fetch(:id)}}}})
        rescue Error => error
          raise Error.new("Draft validation failed for #{target.fetch(:type)} #{target.fetch(:id)}: #{error.message}",diagnostics:error.diagnostics)
        end
      end
      saved = @client.all("/v1/reviewSubmissions/#{submission.fetch('id')}/items")
      raise Error, 'Review draft does not contain the complete authorized bundle.' unless targets.all? { |target| saved.any? { |item| item.dig('relationships',target.fetch(:relationship).to_s,'data','id') == target.fetch(:id) } }
      {submission_id:submission.fetch('id'),targets:targets,items_verified:true}
    end

    private
    def editable_version(type, id)
      versions = @client.all("/v1/#{type}/#{id}/versions")
      versions.sort_by { |row| -(row.dig('attributes','version') || 0) }.find { |row| %w[PREPARE_FOR_SUBMISSION READY_FOR_REVIEW WAITING_FOR_REVIEW IN_REVIEW APPROVED].include?(row.dig('attributes','state')) } || raise(Error, 'Subscription metadata version is missing.')
    end
  end
end
