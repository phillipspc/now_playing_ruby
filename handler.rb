require 'json'
require 'cgi'
require 'aws-sdk'
require 'slack-notifier'
require 'uri'
require 'rack'
require 'net/http'
require 'httparty'

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

def callback(event:, context:)
  id = event['queryStringParameters']['state']
  code = event['queryStringParameters']['code']

  # use the code from the query string params to request spotify access tokens
  response = request_access_token(code)

  # put everything together and create the user record
  parsed = JSON.parse(response.body)
  timestamp = Time.now.to_i

  item = {
    id: id,
    access_token: parsed['access_token'],
    refresh_token: parsed['refresh_token'],
    created_at: timestamp,
    updated_at: timestamp
  }

  dynamodb = Aws::DynamoDB::Client.new
  dynamodb.put_item({ table_name: 'nowplaying-users', item: item })

  {
    statusCode: 200,
    body: JSON.generate({ message: "Authorization successful. You are now ready to use the /nowplaying command!" })
  }
end

private

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
    response = refresh_token(user['refresh_token'])
    parsed = JSON.parse(response.body)
    token = parsed['access_token']

    url = 'https://api.spotify.com/v1/me/player/'
    headers = {
      "Authorization" => "Bearer #{token}"
    }

    response = HTTParty.get(url, headers: headers)
    puts response.body
  end

  def refresh_token(token)
    uri = URI("https://accounts.spotify.com/api/token")
    params = {
      grant_type: 'refresh_token',
      refresh_token: token,
      client_id: ENV['SPOTIFY_CLIENT_ID'],
      client_secret: ENV['SPOTIFY_CLIENT_SECRET']
    }
    Net::HTTP::post_form(uri, params)
  end

  def send_spotify_auth(id, response_url)
    query = URI.encode_www_form({
      client_id: ENV['SPOTIFY_CLIENT_ID'],
      response_type: "code",
      redirect_uri: ENV['SPOTIFY_REDIRECT_URI'],
      scope: 'user-read-playback-state',
      state: id
    })

    authorize_url = URI::HTTP.build(host: "accounts.spotify.com", path: "/authorize", query: query)

    notifier = Slack::Notifier.new(response_url)
    notifier.ping "Use this link to authorize your account: #{authorize_url}"
  end

  def request_access_token(code)
    uri = URI("https://accounts.spotify.com/api/token")
    params = {
      grant_type: 'authorization_code',
      code: code,
      redirect_uri: ENV['SPOTIFY_REDIRECT_URI'],
      client_id: ENV['SPOTIFY_CLIENT_ID'],
      client_secret: ENV['SPOTIFY_CLIENT_SECRET']
    }
    Net::HTTP::post_form(uri, params)
  end
