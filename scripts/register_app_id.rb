# Registers Whisperoid's App ID at Apple: online.blackmeridian.whisperoid, named "Whisperoid" (only the developer
# portal shows the name), with no capabilities requested. One App ID per product, so it is asked for as UNIVERSAL;
# if Apple refuses that platform for a new App ID, it is registered for MAC_OS. The Mac App Store build and its app
# record need it; the Developer ID disk image does not. See specs/code-signing.md 4.5 and 6.2 in the management
# repository.
#
# Registering is a change at Apple: run it only with the owner's approval for that run. It changes nothing when the
# App ID exists already. --check only reads: whether the App ID exists, its platform and its capabilities.
#
#   bundle exec ruby scripts/register_app_id.rb --check
#   bundle exec ruby scripts/register_app_id.rb
#
# The token is made from the studio's App Store Connect API key, referenced by its file's path only. The team, the
# key's identifiers and the key's path are the shared lanes' (blackmeridian-fastlane, lib/blackmeridian/signing.rb),
# read from the studio's checkout of the lanes, so that none of them is written in this public repository.
require "spaceship"

LANES_SIGNING = File.expand_path("~/Development/blackmeridian/blackmeridian-fastlane/lib/blackmeridian/signing.rb")
abort("The studio's lanes are missing: #{LANES_SIGNING}") unless File.exist?(LANES_SIGNING)
require LANES_SIGNING

IDENTIFIER = "online.blackmeridian.whisperoid"
NAME = "Whisperoid"
TEAM_ID = BlackMeridian::TEAM_ID
KEY_ID = BlackMeridian::API_KEY_ID
ISSUER_ID = BlackMeridian::API_ISSUER_ID
KEY_PATH = File.expand_path(BlackMeridian::API_KEY_PATH)

def describe(bundle_id)
  capabilities = bundle_id.get_capabilities.map(&:capability_type).sort
  "#{bundle_id.identifier}: name #{bundle_id.name.inspect}, platform #{bundle_id.platform}, " \
    "prefix #{bundle_id.seed_id}, capabilities #{capabilities.empty? ? 'none' : capabilities.join(', ')}"
end

check_only = ARGV.include?("--check")
abort("The App Store Connect API key file is missing: #{KEY_PATH}") unless File.exist?(KEY_PATH)
Spaceship::ConnectAPI.token = Spaceship::ConnectAPI::Token.create(key_id: KEY_ID, issuer_id: ISSUER_ID, filepath: KEY_PATH)

existing = Spaceship::ConnectAPI::BundleId.find(IDENTIFIER)
if existing
  puts "Registered already, nothing changed: #{describe(existing)}"
  abort("Its prefix is #{existing.seed_id}, not the studio's team #{TEAM_ID}") unless existing.seed_id == TEAM_ID
  exit 0
end
if check_only
  puts "Not registered: #{IDENTIFIER}"
  exit 1
end

created = begin
  Spaceship::ConnectAPI::BundleId.create(name: NAME, identifier: IDENTIFIER, platform: "UNIVERSAL")
rescue Spaceship::UnexpectedResponse => e
  # Only a refusal of the platform leads to the second request; any other refusal (the identifier taken, the
  # name refused) stops here with Apple's message.
  abort("Apple refused the App ID: #{e.message}") unless e.message =~ /platform/i
  puts "Apple refused the platform UNIVERSAL (#{e.message.lines.first&.strip}); registering for MAC_OS"
  Spaceship::ConnectAPI::BundleId.create(name: NAME, identifier: IDENTIFIER, platform: "MAC_OS")
end
# Read back what Apple recorded, rather than trusting the answer to the request.
registered = Spaceship::ConnectAPI::BundleId.find(IDENTIFIER)
abort("Apple answered #{created&.id.inspect}, but no App ID #{IDENTIFIER} can be found") unless registered
puts "Registered: #{describe(registered)}"
