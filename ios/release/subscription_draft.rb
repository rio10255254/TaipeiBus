require_relative 'apple_client'

module TaipeiBusRelease
  # A withdrawn version belongs to its closed review cycle. Apple's versioned
  # catalog requires a fresh snapshot, rather than reusing DEVELOPER_REJECTED.
  def self.subscription_draft(client, parent_type, parent_id, version_type, relationship)
    versions = client.all("/v1/#{parent_type}/#{parent_id}/versions")
    active = versions.select { |row| %w[PREPARE_FOR_SUBMISSION READY_FOR_REVIEW].include?(row.dig('attributes', 'state')) }
    return active.max_by { |row| row.dig('attributes', 'version') || 0 } unless active.empty?
    raise Error, 'Subscription metadata is already under review.' if versions.any? { |row| %w[WAITING_FOR_REVIEW IN_REVIEW].include?(row.dig('attributes', 'state')) }
    client.request(:post, "/v1/#{version_type}", {}, data: {
      type: version_type,
      relationships: { relationship => { data: { type: parent_type, id: parent_id } } }
    }).fetch('data')
  end
end
