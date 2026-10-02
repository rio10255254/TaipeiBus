# App Store Connect release automation. Standard library only; never logs credentials.
require 'base64'
require 'json'
require 'net/http'
require 'openssl'
require 'time'
require 'timeout'
require 'uri'

module TaipeiBusRelease
  class Error < StandardError; end

  class Client
    ORIGIN = 'https://api.appstoreconnect.apple.com'.freeze
    def initialize(key_id:, issuer_id:, key:)
      @key_id, @issuer_id, @key = key_id, issuer_id, key
      raise Error, 'Expected an Apple ES256 private key.' unless key.is_a?(OpenSSL::PKey::EC) && key.private? && key.group.curve_name == 'prime256v1'
    end

    def token(now = Time.now.to_i)
      encode = ->(value) { Base64.urlsafe_encode64(value, padding: false) }
      header = encode.call(JSON.generate(alg: 'ES256', kid: @key_id, typ: 'JWT'))
      payload = encode.call(JSON.generate(iss: @issuer_id, iat: now, exp: now + 600, aud: 'appstoreconnect-v1'))
      content = "#{header}.#{payload}"
      der = @key.sign(OpenSSL::Digest::SHA256.new, content)
      raw = OpenSSL::ASN1.decode(der).value.map { |part| [part.value.to_s(16).rjust(64, '0')].pack('H*') }.join
      "#{content}.#{encode.call(raw)}"
    end

    def uri(path, query = {})
      value = URI(path.start_with?('https://') ? path : "#{ORIGIN}#{path}")
      unless value.scheme == 'https' && value.host == 'api.appstoreconnect.apple.com' && value.port == 443 && !value.userinfo
        raise Error, 'Refusing an API URL outside App Store Connect.'
      end
      value.query = URI.encode_www_form(query) unless query.empty?
      value
    end

    def request(method, path, query = {}, body = nil)
      attempts = 0
      loop do
        value = uri(path, query)
        klass = { get: Net::HTTP::Get, post: Net::HTTP::Post, patch: Net::HTTP::Patch }.fetch(method)
        request = klass.new(value)
        request['Authorization'] = "Bearer #{token}"
        request['Accept'] = 'application/json'
        if body
          request['Content-Type'] = 'application/json'
          request.body = JSON.generate(body)
        end
        response = Net::HTTP.start(value.host, value.port, use_ssl: true, open_timeout: 20, read_timeout: 30) { |http| http.request(request) }
        if method == :get && (response.code == '429' || response.code.to_i >= 500) && attempts < 2
          attempts += 1
          sleep [response['Retry-After'].to_i.clamp(5, 30), 30].min
          next
        end
        unless response.is_a?(Net::HTTPSuccess)
          # Do not echo server error details that may contain request data.
          raise Error, "App Store Connect HTTP #{response.code}. Check key role, app access and Apple agreements."
        end
        return response.body.to_s.empty? ? {} : JSON.parse(response.body)
      end
    end

    def all(path, query = {})
      rows, visited = [], []
      while path
        raise Error, 'Invalid API pagination.' if visited.include?(path) || visited.length >= 100
        visited << path
        result = request(:get, path, query)
        rows.concat(result.fetch('data'))
        path, query = result.dig('links', 'next'), {}
      end
      rows
    end
  end

  class Release
    attr_reader :bundle, :version
    def initialize(client, config, env = ENV)
      @client, @config, @env = client, config, env
      @bundle = env['BUS_BUNDLE_ID'].to_s.empty? ? config.fetch('bundle_id') : env['BUS_BUNDLE_ID']
      @version = env['BUS_VERSION'].to_s.empty? ? config.fetch('version') : env['BUS_VERSION']
      raise Error, 'Use your registered Bundle ID, not com.example.' unless @bundle.match?(/\A[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+\z/) && !@bundle.start_with?('com.example.')
      raise Error, 'Marketing version must contain three numeric components.' unless @version.match?(/\A\d+\.\d+\.\d+\z/)
    end

    def write_allowed!
      raise Error, 'This operation requires an explicit publish action.' unless @env['BUS_PUBLISH_TESTFLIGHT'] == 'true'
    end

    def identifiers
      @client.all('/v1/bundleIds', 'filter[identifier]' => bundle).select { |row| row.dig('attributes', 'identifier') == bundle }
    end

    def register_identifier
      write_allowed!
      existing = identifiers.first
      return existing if existing
      result = @client.request(:post, '/v1/bundleIds', {}, data: {
        type: 'bundleIds', attributes: { identifier: bundle, name: 'TaipeiBus iOS', platform: 'IOS' }
      }).fetch('data')
      summary("Registered #{bundle}. Create its App Store Connect app record in the website next.")
      result
    end

    def app
      @app ||= @client.all('/v1/apps', 'filter[bundleId]' => bundle, 'fields[apps]' => 'name,bundleId').find { |row| row.dig('attributes', 'bundleId') == bundle }
      raise Error, "No app record for #{bundle}. Create it in App Store Connect > My Apps > New App." unless @app
      raise Error, 'Invalid Apple app record ID.' unless @app.fetch('id').match?(/\A\d+\z/)
      @app
    end

    def build_query
      { 'filter[app]' => app.fetch('id'), 'filter[preReleaseVersion.version]' => version,
        'filter[preReleaseVersion.platform]' => 'IOS', 'limit' => '200',
        'fields[builds]' => 'version,processingState,expired,usesNonExemptEncryption' }
    end

    def preflight
      raise Error, "Bundle ID #{bundle} is not registered in this key's Apple team. Use register-app-id first." if identifiers.empty?
      builds = @client.all('/v1/builds', build_query)
      highest = builds.map { |row| row.dig('attributes', 'version').to_s.split('.').first.to_i }.max || 0
      major = [highest + 1, @env.fetch('GITHUB_RUN_NUMBER', '1').to_i].max
      attempt = @env.fetch('GITHUB_RUN_ATTEMPT', '1').to_i
      raise Error, 'Build number exceeded CFBundleVersion component limits.' unless (1..9999).cover?(major) && (1..99).cover?(attempt)
      number = "#{major}.#{attempt}.0"
      export_env('BUS_APP_ID' => app.fetch('id'), 'BUS_BUNDLE_ID' => bundle, 'BUS_VERSION' => version, 'BUS_BUILD_NUMBER' => number)
      receipt = save(status: 'account_verified', build_number: number)
      summary("Account verified: #{bundle}, version #{version}, proposed build #{number}. Nothing has been uploaded by this check.")
      receipt
    end

    def exact_build(number)
      @client.all('/v1/builds', build_query.merge('filter[version]' => number)).find { |row| row.dig('attributes', 'version') == number }
    end

    def beta_details(build)
      @client.all('/v1/buildBetaDetails', 'filter[build]' => build.fetch('id')).first
    end

    def localize(type, relationship, parent, text_field, text)
      write_allowed!
      locale = @config.fetch('locale')
      rows = @client.all("/v1/#{type}", "filter[#{relationship}]" => parent, 'filter[locale]' => locale)
      row = rows.find { |item| item.dig('attributes', 'locale') == locale }
      attributes = { text_field => text }
      if type == 'betaAppLocalizations'
        email, policy = @env['BUS_FEEDBACK_EMAIL'].to_s, @env['BUS_PRIVACY_POLICY_URL'].to_s
        raise Error, 'Invalid feedback email.' unless email.empty? || email.match?(/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/)
        unless policy.empty?
          parsed = URI(policy)
          raise Error, 'Privacy policy needs a public HTTPS URL.' unless parsed.scheme == 'https' && parsed.host && !parsed.userinfo
        end
        attributes['feedbackEmail'] = email unless email.empty?
        attributes['privacyPolicyUrl'] = policy unless policy.empty?
      end
      data = { type: type, attributes: attributes }
      if row
        data[:id] = row.fetch('id')
        @client.request(:patch, "/v1/#{type}/#{row.fetch('id')}", {}, data: data)
      else
        attributes['locale'] = locale
        data[:relationships] = { relationship => { data: { type: relationship == 'app' ? 'apps' : 'builds', id: parent } } }
        @client.request(:post, "/v1/#{type}", {}, data: data)
      end
    end

    def attach_internal(build, details)
      write_allowed!
      unless build.dig('attributes', 'processingState') == 'VALID' && build.dig('attributes', 'expired') != true &&
             %w[READY_FOR_BETA_TESTING IN_BETA_TESTING].include?(details&.dig('attributes', 'internalBuildState'))
        raise Error, 'Build is not ready for internal testing.'
      end
      name = @config.fetch('internal_group')
      group = @client.all('/v1/betaGroups', 'filter[app]' => app.fetch('id'), 'filter[name]' => name).find { |row| row.dig('attributes', 'name') == name }
      raise Error, 'The named group is external; choose a separate internal group.' if group && group.dig('attributes', 'isInternalGroup') != true
      # Disable notifications before attaching. Never add testers, invite anyone or create public links.
      @client.request(:patch, "/v1/buildBetaDetails/#{details.fetch('id')}", {}, data: {
        type: 'buildBetaDetails', id: details.fetch('id'), attributes: { autoNotifyEnabled: false }
      })
      root = __dir__
      localize('betaAppLocalizations', 'app', app.fetch('id'), 'description', File.read(File.join(root, @config.fetch('description_file'))))
      localize('betaBuildLocalizations', 'build', build.fetch('id'), 'whatsNew', File.read(File.join(root, @config.fetch('what_to_test_file'))))
      group ||= @client.request(:post, '/v1/betaGroups', {}, data: {
        type: 'betaGroups', attributes: { name: name, isInternalGroup: true, hasAccessToAllBuilds: false, feedbackEnabled: true },
        relationships: { app: { data: { type: 'apps', id: app.fetch('id') } } }
      }).fetch('data')
      path = "/v1/betaGroups/#{group.fetch('id')}/relationships/builds"
      linked = @client.all(path).any? { |row| row.fetch('id') == build.fetch('id') }
      @client.request(:post, path, {}, data: [{ type: 'builds', id: build.fetch('id') }]) unless linked
      group
    end

    def processing(number, timeout: 1200, interval: 30)
      write_allowed!
      raise Error, 'Specify the exact uploaded build number.' unless number.match?(/\A\d{1,4}(?:\.\d{1,2}){0,2}\z/)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        build = exact_build(number)
        state = build&.dig('attributes', 'processingState')
        puts "Build #{version} (#{number}): #{state || 'waiting for Apple record'}"
        raise Error, 'Apple rejected this build. Read its processing error in App Store Connect.' if %w[FAILED INVALID].include?(state)
        raise Error, 'This build has expired; upload a new build.' if build&.dig('attributes', 'expired') == true
        if state == 'VALID'
          details = beta_details(build)
          internal = details&.dig('attributes', 'internalBuildState')
          if %w[MISSING_EXPORT_COMPLIANCE IN_EXPORT_COMPLIANCE_REVIEW PROCESSING_EXCEPTION EXPIRED].include?(internal)
            save(status: 'apple_action_required', build_number: number, build_id: build.fetch('id'), internal_state: internal)
            raise Error, "Apple requires action: #{internal}. Resolve this build in App Store Connect, then use finish-processing."
          end
          if %w[READY_FOR_BETA_TESTING IN_BETA_TESTING].include?(internal)
            group = attach_internal(build, details)
            receipt = save(status: 'internal_group_assigned', build_number: number, build_id: build.fetch('id'), group_id: group.fetch('id'))
            summary("Build #{version} (#{number}) is processed and assigned to #{@config.fetch('internal_group')}. Add your own eligible App Store Connect user to that group to install with TestFlight. No invitations were sent by this workflow.")
            return receipt
          end
        end
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          receipt = save(status: 'processing_pending', build_number: number, upload_confirmed: @env['BUS_UPLOAD_SUCCEEDED'] == 'true')
          summary("Build #{version} (#{number}) is not yet confirmed as testable. Use finish-processing with this exact version/build after Apple processing. Do not re-upload the same build number.")
          return receipt
        end
        sleep interval
      end
    end

    def save(values)
      path = @env['RUNNER_TEMP'] && File.join(@env['RUNNER_TEMP'], 'testflight-receipt.json')
      previous = path && File.file?(path) ? JSON.parse(File.read(path)) : {}
      previous = {} unless previous['bundle_id'] == bundle && previous['version'] == version && previous['build_number'] == values[:build_number]
      previous = previous.transform_keys(&:to_sym)
      data = previous.merge(app_id: app.fetch('id'), bundle_id: bundle, version: version, commit: @env['GITHUB_SHA'],
               run_url: "https://github.com/#{@env['GITHUB_REPOSITORY']}/actions/runs/#{@env['GITHUB_RUN_ID']}").merge(values)
      File.write(path, JSON.pretty_generate(data) + "\n") if path
      data
    end

    def export_env(values)
      values.each { |key, value| @env[key] = value }
      File.open(@env['GITHUB_ENV'], 'a') { |file| values.each { |key, value| file.puts "#{key}=#{value}" } } if @env['GITHUB_ENV']
    end

    def summary(message)
      puts message
      File.open(@env['GITHUB_STEP_SUMMARY'], 'a') { |file| file.puts(message + "\n") } if @env['GITHUB_STEP_SUMMARY']
    end
  end

  def self.run(action, env = ENV)
    required = %w[APPLE_TEAM_ID ASC_KEY_ID ASC_ISSUER_ID RUNNER_TEMP]
    missing = required.select { |key| env[key].to_s.empty? }
    raise Error, "Missing configuration: #{missing.join(', ')}" unless missing.empty?
    raise Error, 'Invalid Apple Team ID / Key ID.' unless env['APPLE_TEAM_ID'].match?(/\A[A-Z0-9]{10}\z/) && env['ASC_KEY_ID'].match?(/\A[A-Z0-9]{10}\z/)
    raise Error, 'Invalid issuer UUID.' unless env['ASC_ISSUER_ID'].match?(/\A[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\z/)
    key = OpenSSL::PKey.read(File.read(File.join(env['RUNNER_TEMP'], 'bus-signing', 'AuthKey.p8')))
    client = Client.new(key_id: env['ASC_KEY_ID'], issuer_id: env['ASC_ISSUER_ID'], key: key)
    release = Release.new(client, JSON.parse(File.read(File.join(__dir__, 'testflight.json'))), env)
    case action
    when 'preflight' then release.preflight
    when 'register-app-id' then release.register_identifier
    when 'processing' then release.processing(env.fetch('BUS_BUILD_NUMBER'))
    else raise Error, 'Choose preflight, register-app-id or processing.'
    end
  end
end
