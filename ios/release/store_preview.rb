require_relative 'apple_client'
require 'digest'

# Puts the prepared app preview video on the editable update's product page, ahead of the
# screenshots. Draft only: nothing here submits the update or changes its release type.

at_exit do
  error = $!
  warn JSON.generate(error.diagnostics) if error.is_a?(TaipeiBusRelease::Error)
end

# Length in seconds and picture size, read from the file's own header (no ffprobe on the runner).
def video_facts(bytes)
  atoms = lambda do |from, to|
    found = []
    while from + 8 <= to
      size, name = bytes[from, 8].unpack('Na4')
      header = 8
      size, header = bytes[from + 8, 8].unpack1('Q>'), 16 if size == 1
      size = to - from if size.zero?
      break if size < header
      found << [name, from + header, from + size]
      from += size
    end
    found
  end
  moov = atoms.call(0, bytes.bytesize).find { |name, _, _| name == 'moov' }
  return nil unless moov
  inside = atoms.call(moov[1], moov[2])
  mvhd = inside.find { |name, _, _| name == 'mvhd' }
  return nil unless mvhd
  version = bytes.getbyte(mvhd[1])
  scale, length = version == 1 ? bytes[mvhd[1] + 20, 12].unpack('NQ>') : bytes[mvhd[1] + 12, 8].unpack('NN')
  sizes = inside.select { |name, _, _| name == 'trak' }.filter_map do |_, from, to|
    tkhd = atoms.call(from, to).find { |name, _, _| name == 'tkhd' }
    tkhd && bytes[tkhd[2] - 8, 8].unpack('NN').map { |fixed| fixed >> 16 }
  end
  { seconds: length.to_f / scale, size: sizes.find { |width, height| width.positive? && height.positive? } }
end

config = JSON.parse(File.read(File.join(__dir__, 'testflight.json')))
copy = JSON.parse(File.read(File.join(__dir__, 'app-store.zh-Hant.json')))
preview = copy.fetch('appPreview')
file = File.join(__dir__, preview.fetch('file'))
frame = preview.fetch('posterFrame')
abort 'The poster frame must be written as HH:MM:SS:FF.' unless frame.match?(/\A\d\d:\d\d:\d\d:\d\d\z/)
abort 'The prepared app preview is missing.' unless File.file?(file)
bytes = File.binread(file)
facts = video_facts(bytes)
abort 'The app preview must be an MP4 of at most 500 MB.' unless bytes[4, 4] == 'ftyp' && bytes.bytesize <= 500 * 1024 * 1024 && facts
abort 'The app preview must be 886 x 1920 and 15 to 30 seconds long.' unless facts[:size] == [886, 1920] && facts[:seconds].between?(15, 30)
abort 'App previews are uploaded to a draft only.' unless ENV['BUS_STORE_DRAFT_ONLY'] == 'true'

key = OpenSSL::PKey.read(ENV.fetch('ASC_PRIVATE_KEY').sub(/\A\uFEFF/, '').strip)
client = TaipeiBusRelease::Client.new(key_id: ENV.fetch('ASC_KEY_ID'), issuer_id: ENV.fetch('ASC_ISSUER_ID'), key: key)
release = TaipeiBusRelease::Release.new(client, config)
release.write_allowed!
app_id = release.app.fetch('id')
version = client.all("/v1/apps/#{app_id}/appStoreVersions").find { |v| v.dig('attributes', 'versionString') == release.version && v.dig('attributes', 'platform') == 'IOS' }
abort 'An app preview needs the matching editable version with manual release.' unless version &&
  TaipeiBusRelease::EDITABLE_VERSION_STATES.include?(version.dig('attributes', 'appStoreState')) && version.dig('attributes', 'releaseType') == 'MANUAL'
locale = client.all("/v1/appStoreVersions/#{version.fetch('id')}/appStoreVersionLocalizations").find { |v| v.dig('attributes', 'locale') == config.fetch('locale') }
abort 'Update localization is missing.' unless locale

# The 6.9-inch set; smaller iPhones are served this one scaled down.
sets = client.all("/v1/appStoreVersionLocalizations/#{locale.fetch('id')}/appPreviewSets")
set = sets.find { |s| s.dig('attributes', 'previewType') == 'IPHONE_67' }
set ||= client.request(:post, '/v1/appPreviewSets', {}, data: {
  type: 'appPreviewSets', attributes: { previewType: 'IPHONE_67' },
  relationships: { appStoreVersionLocalization: { data: { type: 'appStoreVersionLocalizations', id: locale.fetch('id') } } }
}).fetch('data')
path = "/v1/appPreviewSets/#{set.fetch('id')}/appPreviews"
name, checksum = File.basename(file), Digest::MD5.hexdigest(bytes)
state = ->(item) { item.dig('attributes', 'assetDeliveryState', 'state') }
current = nil
client.all(path).each do |item|
  same = item.dig('attributes', 'fileName') == name && item.dig('attributes', 'sourceFileChecksum') == checksum && state.call(item) != 'FAILED'
  if same && current.nil? then current = item else client.request(:delete, "/v1/appPreviews/#{item.fetch('id')}") end
end
unless current
  current = client.request(:post, '/v1/appPreviews', {}, data: {
    type: 'appPreviews', attributes: { fileName: name, fileSize: bytes.bytesize, mimeType: 'video/mp4', previewFrameTimeCode: frame },
    relationships: { appPreviewSet: { data: { type: 'appPreviewSets', id: set.fetch('id') } } }
  }).fetch('data')
  current.fetch('attributes').fetch('uploadOperations').each do |operation|
    uri = URI(operation.fetch('url'))
    abort 'Invalid Apple asset upload endpoint.' unless uri.scheme == 'https' && uri.host.end_with?('.apple.com') && !uri.userinfo && operation.fetch('method') == 'PUT'
    request = Net::HTTP::Put.new(uri)
    operation.fetch('requestHeaders', []).each { |h| request[h.fetch('name')] = h.fetch('value') }
    request.body = bytes.byteslice(operation.fetch('offset'), operation.fetch('length'))
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 20, read_timeout: 300) { |http| http.request(request) }
    abort "Apple asset upload failed (HTTP #{response.code})." unless response.is_a?(Net::HTTPSuccess)
  end
  client.request(:patch, "/v1/appPreviews/#{current.fetch('id')}", {}, data: {
    type: 'appPreviews', id: current.fetch('id'), attributes: { uploaded: true, sourceFileChecksum: checksum }
  })
  puts "Uploaded #{name} (#{bytes.bytesize} bytes, #{facts[:seconds].round(1)} s)."
end

# Apple transcodes the video after upload, which can take from minutes to a day.
deadline = Time.now + 900
loop do
  current = client.request(:get, "/v1/appPreviews/#{current.fetch('id')}").fetch('data')
  break if state.call(current) == 'COMPLETE'
  if state.call(current) == 'FAILED'
    warn JSON.generate(current.dig('attributes', 'assetDeliveryState', 'errors'))
    abort 'Apple could not process the app preview.'
  end
  if Time.now > deadline
    puts "The app preview is uploaded and still processing at Apple (#{state.call(current)}). Run this operation again later to confirm it."
    exit 0
  end
  sleep 20
end
# The poster frame only holds once the video is processed.
unless current.dig('attributes', 'previewFrameTimeCode') == frame
  client.request(:patch, "/v1/appPreviews/#{current.fetch('id')}", {}, data: {
    type: 'appPreviews', id: current.fetch('id'), attributes: { previewFrameTimeCode: frame }
  })
end
puts "Verified the processed app preview on update #{release.version} (poster frame #{frame}); the update is still a draft."
