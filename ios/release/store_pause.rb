require_relative 'apple_client'

# Withdraw only the exact submission the user asked to pause. No app removal,
# subscription price change, build expiry, or existing-storefront modification.
abort 'Explicit pause action required.' unless ENV['BUS_PAUSE_STORE'] == 'true'
receipt = JSON.parse(File.read(File.join(__dir__, 'app-store-1.6.1-receipt.json')))
abort 'Unexpected pause target.' unless receipt['app_id'] == '6818475740' && receipt['version'] == '1.6.1' && receipt['build_number'] == '98.1.0'
key = OpenSSL::PKey.read(ENV.fetch('ASC_PRIVATE_KEY').sub(/\A\uFEFF/, '').strip)
client = TaipeiBusRelease::Client.new(key_id: ENV.fetch('ASC_KEY_ID'), issuer_id: ENV.fetch('ASC_ISSUER_ID'), key: key)
version_id, submission_id = receipt.values_at('version_id', 'submission_id')
version_path = "/v1/appStoreVersions/#{version_id}"
submission_path = "/v1/reviewSubmissions/#{submission_id}"
report = {app_id:receipt['app_id'],version:'1.6.1',build_number:'98.1.0',version_id:version_id,submission_id:submission_id,status:'pause_in_progress',requested_at:Time.now.utc.iso8601,errors:[]}
save = -> { File.write(File.join(ENV.fetch('RUNNER_TEMP'),'app-store-paused.json'),JSON.pretty_generate(report)+"\n") }
begin
  version = client.all("/v1/apps/#{receipt['app_id']}/appStoreVersions",include:'build').find { |row| row['id'] == version_id }
  raise TaipeiBusRelease::Error,'Exact app version/build identity mismatch.' unless version && version.dig('attributes','versionString') == '1.6.1' && version.dig('relationships','build','data','id') == receipt['build_id']
  submission = client.request(:get,submission_path).fetch('data')
  items = client.all("#{submission_path}/items",include:'appStoreVersion,subscriptionVersion,subscriptionGroupVersion')
  raise TaipeiBusRelease::Error,'The submission does not contain the requested app.' unless items.any? { |item| item.dig('relationships','appStoreVersion','data','id') == version_id }
  report[:initial_version_state] = version.dig('attributes','appStoreState')
  report[:initial_submission_state] = submission.dig('attributes','state')
  report[:review_item_count] = items.length
  save.call
  raise TaipeiBusRelease::Error,'This version is already public; automatic withdrawal is unavailable.' if %w[READY_FOR_SALE READY_FOR_DISTRIBUTION].include?(report[:initial_version_state])
  manual = -> {
    client.request(:patch,version_path,{},data:{type:'appStoreVersions',id:version_id,attributes:{releaseType:'MANUAL'}})
  }
  begin
    manual.call
  rescue TaipeiBusRelease::Error => error
    report[:errors] << {action:'manual_release_before_withdrawal',message:error.message,diagnostics:error.diagnostics}
  end
  if %w[WAITING_FOR_REVIEW IN_REVIEW UNRESOLVED_ISSUES].include?(report[:initial_submission_state])
    client.request(:patch,submission_path,{},data:{type:'reviewSubmissions',id:submission_id,attributes:{canceled:true}})
    report[:withdrawal_requested] = true
  end
  deadline = Time.now + 180
  loop do
    saved_version = client.request(:get,version_path).fetch('data')
    saved_submission = client.request(:get,submission_path).fetch('data')
    report[:version_state] = saved_version.dig('attributes','appStoreState')
    report[:submission_state] = saved_submission.dig('attributes','state')
    report[:release_type] = saved_version.dig('attributes','releaseType')
    break if !%w[WAITING_FOR_REVIEW IN_REVIEW CANCELING].include?(report[:submission_state]) && !%w[WAITING_FOR_REVIEW IN_REVIEW].include?(report[:version_state])
    raise TaipeiBusRelease::Error,'Apple withdrawal is still processing; read back the same submission.' if Time.now > deadline
    save.call; sleep 5
  end
  manual.call unless report[:release_type] == 'MANUAL'
  report[:release_type] = client.request(:get,version_path).dig('data','attributes','releaseType')
  raise TaipeiBusRelease::Error,'Automatic publication was not disabled.' unless report[:release_type] == 'MANUAL'
  report[:status] = 'publication_paused'
  report[:confirmed_at] = Time.now.utc.iso8601
  puts "Apple confirmed publication paused: #{report[:version_state]}, submission #{report[:submission_state]}, release MANUAL."
rescue TaipeiBusRelease::Error => error
  report[:status] = 'pause_requires_attention'
  report[:errors] << {action:'withdraw_submission',message:error.message,diagnostics:error.diagnostics}
  warn JSON.generate(report)
  raise
ensure
  save.call
end
