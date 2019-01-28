require 'json'
require 'cgi'
require 'aws-sdk'

def now_playing(event:, context:)
  parsed = CGI::parse(event['body'])
  id = "#{parsed['user_id'].first}-#{parsed['team_id'].first}"
  response_url = parsed['response_url'].first

  topic = Aws::SNS::Resource.new(region: 'us-east-1').topic(ENV['SNS_ARN'])

  topic.publish({ message: { id: id, responseUrl: response_url }.to_json })

  # dynamodb = Aws::DynamoDB::Client.new
  #
  # params = {
  #   table_name: 'nowplaying-users',
  #   key_condition_expression: "#id = :id",
  #   expression_attribute_names: {
  #     "#id" => "id"
  #   },
  #   expression_attribute_values: {
  #     ":id" => id
  #   }
  # }
  #
  # result = dynamodb.query(params)

  { statusCode: 200, body: {response_type: "in_channel", text: ""}.to_json }
end

def dispatcher(event:, context:)
  puts "EVENT: #{event}"
  # parsed = CGI::parse(event['body'])
  # id = parsed['id'].first
  # puts "ID: #{id}"
  #
  # response_url = parsed['response_url'].first
  # puts "RESPONSE URL: #{response_url}"
end
