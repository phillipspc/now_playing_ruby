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
    p "Found User with id: #{id}"
    fetch_track(user, response_url)
  else
    p "No user found with id: #{id}"
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
    p "Refreshing user's token: #{user['refresh_token']}"
    response = refresh_token(user['refresh_token'])
    parsed = JSON.parse(response.body)
    token = parsed['access_token']
    p "New token: #{token}"

    url = 'https://api.spotify.com/v1/me/player/'
    headers = {
      "Authorization" => "Bearer #{token}"
    }

    response = HTTParty.get(url, headers: headers)
    p "Response from Spotify: #{response}"
    data = JSON.parse(response.body)

    show_now_playing(data, response_url)
  end

  def show_now_playing(data, response_url)
    notifier = Slack::Notifier.new(response_url)

    if data.keys.size == 0
      p "Empty response from Spotify"
      notifier.post(text: "It doesn't look like you're listening to anything.", response_type: "in_channel")
    elsif !data['item']
      if data['device']['is_private_session']
        p "Private Session detected"
        notifier.post(
          text: "It looks like you're currently in a private session. You'll need to go public to " \
                "share what you're listening to.",
          response_type: "in_channel"
        )
      else
        p "No item attribute in Spotify response"
        notifier.post(text: "It doesn't look like you're listening to anything.", response_type: "in_channel")
      end
    else
      notifier.post(
        text: data['item']['external_urls']['spotify'],
        response_type: "in_channel",
        unfurl_links: true
      )
    end
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
    notifier.ping("Use this link to authorize your account: #{authorize_url}")
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
