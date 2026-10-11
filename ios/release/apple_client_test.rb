require 'minitest/autorun'
require 'tmpdir'
require_relative 'apple_client'

class AppleReleaseTest < Minitest::Test
  class FakeClient
    attr_reader :writes, :queries
    def initialize(rows = {})
      @rows, @writes, @queries = rows, [], []
    end
    def all(path, query = {})
      @queries << [path, query]
      @rows.fetch(path, [])
    end
    def request(method, path, query = {}, body = nil)
      @writes << [method, path, body]
      { 'data' => { 'id' => 'created-group' } }
    end
  end

  def setup
    @config = JSON.parse(File.read(File.join(__dir__, 'testflight.json')))
    @env = { 'GITHUB_RUN_NUMBER' => '12', 'GITHUB_RUN_ATTEMPT' => '2', 'BUS_PUBLISH_TESTFLIGHT' => 'true' }
    @app = { 'id' => '123456', 'attributes' => { 'bundleId' => @config['bundle_id'] } }
    @build = { 'id' => 'exact-build', 'attributes' => { 'version' => '13.2.0', 'processingState' => 'VALID', 'expired' => false } }
    @details = { 'id' => 'detail-id', 'attributes' => { 'internalBuildState' => 'READY_FOR_BETA_TESTING' } }
    @group = { 'id' => 'internal-id', 'attributes' => { 'name' => @config['internal_group'], 'isInternalGroup' => true } }
    @rows = { '/v1/apps' => [@app], '/v1/bundleIds' => [{ 'id' => 'registered', 'attributes' => { 'identifier' => @config['bundle_id'] } }],
              '/v1/builds' => [@build], '/v1/buildBetaDetails' => [@details], '/v1/betaGroups' => [@group] }
  end

  def release(rows = @rows, env = @env)
    @client = FakeClient.new(rows)
    TaipeiBusRelease::Release.new(@client, @config, env)
  end

  def test_jwt_signature_and_expiry
    key = OpenSSL::PKey::EC.generate('prime256v1')
    client = TaipeiBusRelease::Client.new(key_id: 'ABCDEFGHIJ', issuer_id: 'issuer', key: key)
    header, payload, signature = client.token(1000).split('.')
    claims = JSON.parse(Base64.urlsafe_decode64(payload))
    assert_equal 'appstoreconnect-v1', claims['aud']
    assert_equal 1600, claims['exp']
    raw = Base64.urlsafe_decode64(signature)
    assert_equal 64, raw.bytesize
    parts = [raw.byteslice(0, 32), raw.byteslice(32, 32)].map { |part| OpenSSL::ASN1::Integer.new(OpenSSL::BN.new(part, 2)) }
    assert key.verify(OpenSSL::Digest::SHA256.new, OpenSSL::ASN1::Sequence.new(parts).to_der, "#{header}.#{payload}")
  end

  def test_pagination_cannot_send_key_to_another_host
    client = TaipeiBusRelease::Client.new(key_id: 'ABCDEFGHIJ', issuer_id: 'issuer', key: OpenSSL::PKey::EC.generate('prime256v1'))
    assert_raises(TaipeiBusRelease::Error) { client.uri('https://attacker.example/v1/apps') }
    assert_raises(TaipeiBusRelease::Error) { client.uri('https://user:pass@api.appstoreconnect.apple.com/v1/apps') }
    assert_equal @config['bundle_id'], URI.decode_www_form(client.uri('/v1/apps', 'filter[bundleId]' => @config['bundle_id']).query).to_h['filter[bundleId]']
  end

  def test_preflight_uses_existing_builds_and_rerun_attempt_without_writes
    result = release.preflight
    assert_equal '14.2.0', result[:build_number]
    assert_equal 'account_verified', result[:status]
    assert_empty @client.writes
    assert_equal @config['version'], @client.queries.find { |path, _| path == '/v1/builds' }[1]['filter[preReleaseVersion.version]']
  end

  def test_exact_build_cannot_accept_a_nearby_upload
    run = release
    assert_nil run.exact_build('14.2.0')
    assert_equal '14.2.0', @client.queries.last[1]['filter[version]']
    assert_equal @build, run.exact_build('13.2.0')
  end

  def test_register_reuses_identifier_and_requires_publish_flag
    assert_equal 'registered', release.register_identifier['id']
    assert_empty @client.writes
    assert_raises(TaipeiBusRelease::Error) { release(@rows, @env.merge('BUS_PUBLISH_TESTFLIGHT' => 'false')).register_identifier }
    assert_empty @client.writes
  end

  def test_widget_profile_reuses_a_valid_profile_for_the_installed_certificate
    der = 'certificate-bytes'
    sha1 = OpenSSL::Digest::SHA1.hexdigest(der).upcase
    widget = "#{@config['bundle_id']}.Widgets"
    profile = { 'id' => 'p1', 'attributes' => { 'name' => "TaipeiBus Widgets #{sha1[0, 8]} 202610110000", 'profileType' => 'IOS_APP_STORE',
      'profileState' => 'ACTIVE', 'expirationDate' => (Time.now + 300 * 86_400).utc.iso8601, 'profileContent' => Base64.strict_encode64('profile') } }
    rows = @rows.merge('/v1/bundleIds' => [{ 'id' => 'widget-id', 'attributes' => { 'identifier' => widget } }],
      '/v1/certificates' => [{ 'id' => 'other', 'attributes' => { 'certificateContent' => Base64.strict_encode64('other') } },
                             { 'id' => 'cert', 'attributes' => { 'certificateContent' => Base64.strict_encode64(der) } }],
      '/v1/bundleIds/widget-id/profiles' => [profile])
    Dir.mktmpdir do |dir|
      Dir.mkdir(File.join(dir, 'bus-signing'))
      env = @env.merge('BUS_SIGNING_CERTIFICATE_SHA1' => sha1, 'RUNNER_TEMP' => dir)
      path = release(rows, env).widget_profile
      assert_equal 'profile', File.binread(path)
      assert_empty @client.writes
      expired = profile.merge('attributes' => profile['attributes'].merge('expirationDate' => (Time.now + 86_400).utc.iso8601))
      run = release(rows.merge('/v1/bundleIds/widget-id/profiles' => [expired]), env)
      assert_raises(TaipeiBusRelease::Error) { run.widget_profile }
      method, path, body = @client.writes.first
      assert_equal [:post, '/v1/profiles'], [method, path]
      assert_equal 'cert', body[:data][:relationships][:certificates][:data][0][:id]
      assert_equal 'widget-id', body[:data][:relationships][:bundleId][:data][:id]
    end
    assert_raises(TaipeiBusRelease::Error) { release(@rows, @env.merge('BUS_PUBLISH_TESTFLIGHT' => 'false')).widget_profile }
  end

  def test_group_assignment_requires_processed_unexpired_build
    run = release
    assert_raises(TaipeiBusRelease::Error) { run.attach_internal(@build.merge('attributes' => @build['attributes'].merge('processingState' => 'PROCESSING')), @details) }
    assert_raises(TaipeiBusRelease::Error) { run.attach_internal(@build.merge('attributes' => @build['attributes'].merge('expired' => true)), @details) }
    assert_empty @client.writes
  end

  def test_export_compliance_prevents_group_assignment
    @details['attributes']['internalBuildState'] = 'MISSING_EXPORT_COMPLIANCE'
    assert_raises(TaipeiBusRelease::Error) { release.processing('13.2.0', timeout: 0) }
    assert_empty @client.writes
  end

  def test_existing_external_group_is_rejected_before_writes
    @group['attributes']['isInternalGroup'] = false
    assert_raises(TaipeiBusRelease::Error) { release.attach_internal(@build, @details) }
    assert_empty @client.writes
  end

  def test_recovery_preserves_contact_fields_and_skips_duplicate_build_assignment
    @rows['/v1/betaGroups/internal-id/relationships/builds'] = [{ 'id' => 'exact-build' }]
    @rows['/v1/betaAppLocalizations'] = [{ 'id' => 'locale-app', 'attributes' => { 'locale' => 'zh-Hant', 'feedbackEmail' => 'existing@example.com' } }]
    result = release.processing('13.2.0', timeout: 0)
    assert_equal 'internal_group_assigned', result[:status]
    assert_empty @client.writes.select { |_, path, _| path.include?('relationships/builds') }
    notification = @client.writes.find { |_, path, _| path == '/v1/buildBetaDetails/detail-id' }
    assert_equal false, notification[2][:data][:attributes][:autoNotifyEnabled]
    localized = @client.writes.find { |_, path, _| path == '/v1/betaAppLocalizations/locale-app' }
    refute localized[2][:data][:attributes].key?('feedbackEmail')
    refute localized[2][:data][:attributes].key?('privacyPolicyUrl')
    refute @client.writes.any? { |_, path, _| path.include?('betaTesters') || path.include?('betaReview') }
  end

  def test_processing_timeout_does_not_claim_upload_or_installability
    @rows['/v1/builds'] = []
    result = release.processing('13.2.0', timeout: 0)
    assert_equal 'processing_pending', result[:status]
    assert_equal false, result[:upload_confirmed]
    assert_empty @client.writes
  end

  def test_receipt_is_saved_without_credentials
    Dir.mktmpdir do |directory|
      run = release(@rows, @env.merge('RUNNER_TEMP' => directory, 'ASC_PRIVATE_KEY' => 'private-test-value'))
      run.preflight
      receipt = File.read(File.join(directory, 'testflight-receipt.json'))
      assert_equal '14.2.0', JSON.parse(receipt)['build_number']
      refute_includes receipt, 'private-test-value'
    end
  end

  def test_ready_receipt_preserves_upload_confirmation_for_the_same_build
    Dir.mktmpdir do |directory|
      run = release(@rows, @env.merge('RUNNER_TEMP' => directory))
      path = File.join(directory, 'testflight-receipt.json')
      File.write(path, JSON.generate(bundle_id: @config['bundle_id'], version: @config['version'],
                                     build_number: '13.2.0', status: 'uploaded_processing_pending', upload_confirmed: true))
      run.processing('13.2.0', timeout: 0)
      saved = JSON.parse(File.read(path))
      assert_equal true, saved['upload_confirmed']
      assert_equal 'internal_group_assigned', saved['status']
    end
  end
end
