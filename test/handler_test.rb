require_relative '../handler.rb'
require 'test/unit'

class HandlerTest < Test::Unit::TestCase
  def test_happy_path
      response = hello(event: {"body": "Hello, World!"}, context: {})
      assert_equal 200, response[:statusCode]
      assert_match /Serverless/, response[:body]
  end

  def test_sad_path
    response = hello(event: nil, context: {})
    assert_equal 400, response[:statusCode]
    assert_match /please POST/, response[:body]
  end
end
