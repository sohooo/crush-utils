# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Crush
  module Utils
    class GitlabClient
      Response = Struct.new(:data, :raw_response)

      def initialize(base_url:, token:, per_page: 100)
        @base_url = base_url.sub(%r{/+$}, "")
        @token = token
        @per_page = per_page
      end

      def get(path, params = {}, headers = {})
        request(:get, path, params: params, headers: headers).data
      end

      def paginate(path, params = {})
        results = []
        page = 1
        loop do
          page_params = params.merge(page: page, per_page: @per_page)
          response = request(:get, path, params: page_params)
          data = response.data

          if data.is_a?(Array)
            results.concat(data)
          elsif data.nil?
            # nothing to add
          else
            results << data
          end

          next_page = response.raw_response["X-Next-Page"]
          break if next_page.nil? || next_page.empty?

          page = next_page.to_i
          page = 1 if page <= 0
        end
        results
      end

      private

      def request(method, path, params: {}, headers: {}, body: nil)
        uri = build_uri(path, params)
        http_request = build_request(method, uri, headers, body)

        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
          response = http.request(http_request)
          verify_response!(response)
          Response.new(parse_json(response.body, response["Content-Type"]), response)
        end
      end

      def build_request(method, uri, headers, body)
        request_class = case method.to_s.downcase
                        when "get" then Net::HTTP::Get
                        when "post" then Net::HTTP::Post
                        when "put" then Net::HTTP::Put
                        when "delete" then Net::HTTP::Delete
                        when "patch" then Net::HTTP::Patch
                        else
                          raise ArgumentError, "Unsupported HTTP method: #{method}"
                        end
        request = request_class.new(uri)
        request["PRIVATE-TOKEN"] = @token if @token && !@token.empty?
        headers.each { |key, value| request[key] = value }
        request.body = body if body
        request
      end

      def build_uri(path, params = {})
        uri = URI.parse("#{@base_url}#{path}")
        query_params = []
        query_params.concat(URI.decode_www_form(uri.query)) if uri.query
        params.each do |key, value|
          query_params << [key.to_s, value]
        end
        uri.query = URI.encode_www_form(query_params) unless query_params.empty?
        uri
      end

      def verify_response!(response)
        return if response.is_a?(Net::HTTPSuccess)

        raise "GitLab request failed: #{response.code} #{response.body}"
      end

      def parse_json(body, content_type)
        return nil if body.nil? || body.empty?
        return body unless content_type&.include?("application/json")

        JSON.parse(body)
      rescue JSON::ParserError
        raise "Failed to parse JSON response: #{body.inspect}"
      end
    end
  end
end
