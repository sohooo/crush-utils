# frozen_string_literal: true

require "test_helper"
require "crush/utils/flows/pulse/weekly_pulse"
require "net/http"

class GitlabClientTest < Minitest::Test
  GitlabClient = Crush::Utils::Flows::Pulse::WeeklyPulse::GitlabClient

  def setup
    @client = GitlabClient.new(base_url: "https://gitlab.example.com", token: "secret", per_page: 2)
  end

  def test_request_includes_authentication_and_headers
    fake_response = Net::HTTPSuccess.new("1.1", "200", "OK")
    fake_response.instance_variable_set(:@read, true)
    fake_response.instance_variable_set(:@body, "{\"value\":123}")
    fake_response["Content-Type"] = "application/json"
    fake_response["X-Next-Page"] = ""

    captured_request = nil

    Net::HTTP.stub(:start, lambda do |host, port, use_ssl:, &block|
      assert_equal "gitlab.example.com", host
      assert_equal 443, port
      assert use_ssl

      http = Object.new
      http.define_singleton_method(:request) do |req|
        captured_request = req
        fake_response
      end

      block.call(http)
    end) do
      response = @client.send(:request, :get, "/api/v4/test", params: { a: 1 }, headers: { "Accept" => "application/json" })
      assert_equal({ "value" => 123 }, response.data)
    end

    refute_nil captured_request
    assert_equal "/api/v4/test?a=1", captured_request.path
    assert_equal "secret", captured_request["PRIVATE-TOKEN"]
    assert_equal "application/json", captured_request["Accept"]
  end

  def test_paginate_accumulates_all_pages
    responses = [
      GitlabClient::Response.new([1, 2], { "X-Next-Page" => "2" }),
      GitlabClient::Response.new([3], { "X-Next-Page" => "" })
    ]
    calls = []

    @client.stub(:request, lambda do |method, path, params: {}, headers: {}, body: nil|
      calls << [method, path, params]
      responses.shift
    end) do
      result = @client.paginate("/api/v4/items", foo: "bar")
      assert_equal [1, 2, 3], result
    end

    assert_equal 2, calls.length
    assert_equal({ foo: "bar", page: 1, per_page: 2 }, calls[0][2])
    assert_equal({ foo: "bar", page: 2, per_page: 2 }, calls[1][2])
  end

  def test_verify_response_raises_on_error
    response = Net::HTTPServerError.new("1.1", "500", "Internal Error")
    response.instance_variable_set(:@read, true)
    response.instance_variable_set(:@body, "nope")

    error = assert_raises(RuntimeError) do
      @client.send(:verify_response!, response)
    end
    assert_includes error.message, "GitLab request failed"
  end

  def test_parse_json_returns_plain_body_when_not_json
    assert_equal "plain", @client.send(:parse_json, "plain", "text/plain")
  end
end
