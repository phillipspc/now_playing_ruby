require 'json'
require 'cgi'
require 'aws-sdk'
require 'slack-notifier'
require 'dynamoid'
require 'uri'
require 'rack'

def now_playing(event:, context:)
  parsed = Rack::Utils.parse_nested_query(event['body'])
  id = "#{parsed['user_id']}-#{parsed['team_id']}"
  response_url = parsed['response_url']

  # kick off SNS which will check for user and take follow up action
  topic = Aws::SNS::Resource.new(region: 'us-east-1').topic(ENV['CHECK_FOR_USER_ARN'])
  topic.publish({ message: { id: id, response_url: response_url }.to_json })

  # ensure command invocation shows up publicly
  { statusCode: 200, body: {response_type: "in_channel", text: ""}.to_json }
end

def check_for_user(event:, context:)
  message = JSON.parse(event["Records"][0]["Sns"]["Message"])
  id = message["id"]
  response_url = message["response_url"]

  user = find_user_by_id(id)

  if user
    fetch_track(user, response_url)
  else
    send_spotify_auth(id, response_url)
  end
end

def find_user_by_id(id)
  dynamodb = Aws::DynamoDB::Client.new

  params = {
    table_name: 'nowplaying-users',
    key_condition_expression: "#id = :id",
    expression_attribute_names: {
      "#id" => "id"
    },
    expression_attribute_values: {
      ":id" => id
    }
  }

  dynamodb.query(params).items.first
end

def fetch_track(user, response_url)
end

def send_spotify_auth(id, response_url)
  query = {
    client_id: ENV['SPOTIFY_CLIENT_ID'],
    response_type: "code",
    redirect_uri: "http://www.google.com",
    scope: 'user-read-playback-state',
    state: id
  }.to_query

  authorize_url = URI::HTTP.build(host: "accounts.spotify.com", path: "/authorize", query: query)

  notifier = Slack::Notifier.new response_url.to_s
  notifier.ping "Use this link to authorize your account: #{authorize_url}"
end
