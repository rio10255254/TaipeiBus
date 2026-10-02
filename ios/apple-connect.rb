# App Store Connect checks using only the Ruby standard library on the macOS runner.
# No token or private key is printed. All API operations are read-only.
require 'base64'
require 'json'
require 'net/http'
require 'openssl'
require 'time'
require 'uri'

def base64url(value)
  Base64.urlsafe_encode64(value, padding: false)
end

def apple_get(path, query = {})
  now = Time.now.to_i
  header = base64url(JSON.generate(alg: 'ES256', kid: ENV.fetch('ASC_KEY_ID'), typ: 'JWT'))
  payload = base64url(JSON.generate(iss: ENV.fetch('ASC_ISSUER_ID'), iat: now, exp: now + 600, aud: 'appstoreconnect-v1'))
  content = "#{header}.#{payload}"
  key_path = File.join(ENV.fetch('RUNNER_TEMP'), 'bus-signing', 'AuthKey.p8')
  key = OpenSSL::PKey.read(File.read(key_path))
  der = key.sign(OpenSSL::Digest::SHA256.new, content)
  signature = OpenSSL::ASN1.decode(der).value.map { |integer| [integer.value.to_s(16).rjust(64, '0')].pack('H*') }.join
  uri = URI("https://api.appstoreconnect.apple.com#{path}")
  uri.query = URI.encode_www_form(query) unless query.empty?
  request = Net::HTTP::Get.new(uri)
  request['Authorization'] = "Bearer #{content}.#{base64url(signature)}"
  request['Accept'] = 'application/json'
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 20, read_timeout: 30) { |http| http.request(request) }
  unless response.is_a?(Net::HTTPSuccess)
    abort "App Store Connect returned HTTP #{response.code}; check API key permissions and the app record."
  end
  JSON.parse(response.body)
end

bundle = ENV.fetch('BUS_BUNDLE_ID')
apps = apple_get('/v1/apps', 'filter[bundleId]' => bundle, 'fields[apps]' => 'name,bundleId')
app = apps.fetch('data').find { |item| item.dig('attributes', 'bundleId') == bundle }
abort "No App Store Connect app record for #{bundle}. Create the app record before uploading." unless app
puts "Verified App Store Connect app: #{app.dig('attributes', 'name')} (#{bundle})"

if ARGV[0] == 'processing'
  started = File.read(File.join(ENV.fetch('RUNNER_TEMP'), 'bus-signing', 'upload-start')).to_i
  deadline = Time.now + 1200
  loop do
    result = apple_get('/v1/builds', 'filter[app]' => app.fetch('id'),
                       'filter[preReleaseVersion.version]' => '0.2.0', 'filter[preReleaseVersion.platform]' => 'IOS',
                       'sort' => '-uploadedDate', 'limit' => '10',
                       'fields[builds]' => 'version,uploadedDate,processingState')
    build = result.fetch('data').find { |item| Time.parse(item.dig('attributes', 'uploadedDate')).to_i >= started - 120 }
    state = build&.dig('attributes', 'processingState')
    puts "TestFlight processing: #{state || 'waiting for build record'}"
    abort 'Apple rejected the uploaded build; inspect App Store Connect for details.' if %w[FAILED INVALID].include?(state)
    if state == 'VALID'
      message = "TestFlight processed build #{build.dig('attributes', 'version')}. Manage internal tester access in App Store Connect."
      puts message
      File.open(ENV.fetch('GITHUB_STEP_SUMMARY'), 'a') { |file| file.puts(message) }
      break
    end
    if Time.now >= deadline
      puts 'Upload completed, but Apple is still processing. Check App Store Connect before treating the build as installable.'
      File.open(ENV.fetch('GITHUB_STEP_SUMMARY'), 'a') { |file| file.puts('Upload completed; TestFlight processing is pending.') }
      break
    end
    sleep 30
  end
end
