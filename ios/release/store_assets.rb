require_relative 'apple_client'
require 'digest'

config = JSON.parse(File.read(File.join(__dir__, 'testflight.json')))
copy = JSON.parse(File.read(File.join(__dir__, 'app-store.zh-Hant.json')))
abort 'Public release is not enabled.' if config['distribution'] == 'testflight-only'
key = OpenSSL::PKey.read(ENV.fetch('ASC_PRIVATE_KEY').sub(/\A\uFEFF/, '').strip)
client = TaipeiBusRelease::Client.new(key_id: ENV.fetch('ASC_KEY_ID'), issuer_id: ENV.fetch('ASC_ISSUER_ID'), key: key)
release = TaipeiBusRelease::Release.new(client, config)
app_id = release.app.fetch('id')
version = client.all("/v1/apps/#{app_id}/appStoreVersions").find { |v| v.dig('attributes', 'versionString') == release.version && v.dig('attributes', 'platform') == 'IOS' }
abort 'Only the matching editable update can receive screenshots.' unless version && version.dig('attributes', 'appStoreState') == 'PREPARE_FOR_SUBMISSION'
locale = client.all("/v1/appStoreVersions/#{version.fetch('id')}/appStoreVersionLocalizations").find { |v| v.dig('attributes', 'locale') == config.fetch('locale') }
abort 'Update localization is missing.' unless locale
files = copy.fetch('screenshotOrder').map { |name| File.join(__dir__, 'screenshots', name) }
abort 'Prepared screenshot files are missing.' unless files.length.between?(3, 10) && files.all? { |path| File.file?(path) }
files.each do |path|
  bytes = File.binread(path)
  abort 'Screenshot must be a 1320 x 2868 PNG.' unless bytes[0, 8] == "\x89PNG\r\n\x1A\n".b && bytes[16, 8].unpack('NN') == [1320, 2868]
end
sets = client.all("/v1/appStoreVersionLocalizations/#{locale.fetch('id')}/appScreenshotSets")
set = sets.find { |s| s.dig('attributes', 'screenshotDisplayType') == 'APP_IPHONE_67' }
set ||= client.request(:post, '/v1/appScreenshotSets', {}, data: {
  type: 'appScreenshotSets', attributes: { screenshotDisplayType: 'APP_IPHONE_67' },
  relationships: { appStoreVersionLocalization: { data: { type: 'appStoreVersionLocalizations', id: locale.fetch('id') } } }
}).fetch('data')
path = "/v1/appScreenshotSets/#{set.fetch('id')}/appScreenshots"
desired = files.map { |file| [File.basename(file), Digest::MD5.file(file).hexdigest] }.to_h
shots = client.all(path)
shots.each do |shot|
  name = shot.dig('attributes', 'fileName')
  matching = desired[name] == shot.dig('attributes', 'sourceFileChecksum') && shot.dig('attributes', 'assetDeliveryState', 'state') == 'COMPLETE'
  client.request(:delete, "/v1/appScreenshots/#{shot.fetch('id')}") unless matching
end
shots = client.all(path)
files.each do |file|
  name = File.basename(file)
  next if shots.any? { |s| s.dig('attributes', 'fileName') == name }
  bytes = File.binread(file)
  shot = client.request(:post, '/v1/appScreenshots', {}, data: {
    type: 'appScreenshots', attributes: { fileName: name, fileSize: bytes.bytesize },
    relationships: { appScreenshotSet: { data: { type: 'appScreenshotSets', id: set.fetch('id') } } }
  }).fetch('data')
  shot.fetch('attributes').fetch('uploadOperations').each do |operation|
    uri = URI(operation.fetch('url'))
    abort 'Invalid Apple asset upload endpoint.' unless uri.scheme == 'https' && uri.host.end_with?('.apple.com') && !uri.userinfo && operation.fetch('method') == 'PUT'
    request = Net::HTTP::Put.new(uri)
    operation.fetch('requestHeaders', []).each { |h| request[h.fetch('name')] = h.fetch('value') }
    request.body = bytes.byteslice(operation.fetch('offset'), operation.fetch('length'))
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 20, read_timeout: 120) { |http| http.request(request) }
    abort "Apple asset upload failed (HTTP #{response.code})." unless response.is_a?(Net::HTTPSuccess)
  end
  client.request(:patch, "/v1/appScreenshots/#{shot.fetch('id')}", {}, data: {
    type: 'appScreenshots', id: shot.fetch('id'), attributes: { uploaded: true, sourceFileChecksum: Digest::MD5.hexdigest(bytes) }
  })
  puts "Uploaded #{name}."
end
deadline = Time.now + 600
loop do
  shots = client.all(path)
  break if shots.length == files.length && shots.all? { |s| s.dig('attributes', 'assetDeliveryState', 'state') == 'COMPLETE' }
  abort 'Apple screenshot processing failed.' if shots.any? { |s| s.dig('attributes', 'assetDeliveryState', 'state') == 'FAILED' }
  abort 'Apple screenshots still processing; rerun the same assets operation.' if Time.now > deadline
  sleep 15
end
ordered = files.map { |file| shots.find { |s| s.dig('attributes', 'fileName') == File.basename(file) }.fetch('id') }
client.request(:patch, "#{path.sub('/appScreenshots', '')}/relationships/appScreenshots", {}, data: ordered.map { |id| { type: 'appScreenshots', id: id } })
puts "Verified #{ordered.length} processed screenshots on update #{release.version}."
