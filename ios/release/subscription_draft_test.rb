require 'minitest/autorun'
require_relative 'subscription_draft'

class SubscriptionDraftTest < Minitest::Test
  class Client
    attr_reader :writes
    def initialize(states)
      @versions = states.each_with_index.map { |state, i| { 'id' => "v#{i}", 'attributes' => { 'state' => state, 'version' => i + 1 } } }
      @writes = []
    end
    def all(path) = @versions
    def request(method, path, query = {}, body = nil)
      @writes << [method, path, body]
      { 'data' => { 'id' => 'new', 'attributes' => { 'state' => 'PREPARE_FOR_SUBMISSION' } } }
    end
  end
  def draft(client)
    TaipeiBusRelease.subscription_draft(client, 'subscriptions', 'plan', 'subscriptionVersions', :subscription)
  end
  def test_withdrawn_metadata_gets_a_new_review_snapshot
    client = Client.new(%w[DEVELOPER_REJECTED])
    assert_equal 'new', draft(client)['id']
    assert_equal '/v1/subscriptionVersions', client.writes.first[1]
    assert_equal 'plan', client.writes.first[2][:data][:relationships][:subscription][:data][:id]
  end
  def test_retry_reuses_the_latest_prepared_snapshot
    client = Client.new(%w[DEVELOPER_REJECTED PREPARE_FOR_SUBMISSION READY_FOR_REVIEW])
    assert_equal 'v2', draft(client)['id']
    assert_empty client.writes
  end
  def test_in_review_catalog_is_never_replaced
    client = Client.new(%w[DEVELOPER_REJECTED IN_REVIEW])
    assert_raises(TaipeiBusRelease::Error) { draft(client) }
    assert_empty client.writes
  end
end
