require_relative 'apple_client'

module TaipeiBusRelease
  # Apple retains a developer-withdrawn catalog version as its inflight draft.
  # Reuse it; attempting to create another version returns ALREADY_EXISTS.
  def self.subscription_draft(client, parent_type, parent_id, version_type, relationship)
    versions = client.all("/v1/#{parent_type}/#{parent_id}/versions")
    raise Error, 'Subscription metadata is already under review.' if versions.any? { |row| %w[WAITING_FOR_REVIEW IN_REVIEW].include?(row.dig('attributes', 'state')) }
    active = versions.select { |row| %w[PREPARE_FOR_SUBMISSION READY_FOR_REVIEW DEVELOPER_REJECTED].include?(row.dig('attributes', 'state')) }
    return active.max_by { |row| row.dig('attributes', 'version') || 0 } unless active.empty?
    client.request(:post, "/v1/#{version_type}", {}, data: {
      type: version_type,
      relationships: { relationship => { data: { type: parent_type, id: parent_id } } }
    }).fetch('data')
  end
end
