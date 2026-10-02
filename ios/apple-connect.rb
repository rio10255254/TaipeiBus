# App Store Connect command line entry point; keys stay in the runner's temporary directory.
require_relative 'release/apple_client'

if $PROGRAM_NAME == __FILE__
  begin
    TaipeiBusRelease.run(ARGV.fetch(0, 'preflight'))
  rescue TaipeiBusRelease::Error, KeyError, OpenSSL::OpenSSLError, SystemCallError,
         Timeout::Error, URI::InvalidURIError, JSON::ParserError => error
    warn error.message
    exit 1
  end
end
