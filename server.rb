#!/usr/bin/env ruby
# SHL Assessment Recommendation Agent - API Server
# Implements FastAPI-compatible endpoints: GET /health and POST /chat

require 'webrick'
require 'json'
require 'net/http'
require 'uri'
require 'timeout'

require_relative 'catalog'
require_relative 'agent'

module SHL
  class APIServer
    PORT = ENV.fetch('PORT', 8000).to_i
    HOST = ENV.fetch('HOST', '0.0.0.0')

    def initialize
      @catalog = Catalog.new
      @agent = Agent.new(@catalog)
      puts "[Server] SHL Assessment Agent initialized with #{@catalog.assessments.length} assessments."
    end

    def start
      server = WEBrick::HTTPServer.new(
        Port: PORT,
        BindAddress: HOST,
        Logger: WEBrick::Log.new($stdout, WEBrick::Log::INFO),
        AccessLog: [[File.open('/dev/null', 'w'), WEBrick::AccessLog::COMMON_LOG_FORMAT]]
      )

      # GET /health - Health check endpoint
      server.mount_proc '/health' do |req, res|
        if req.request_method != 'GET'
          res.status = 405
          res['Content-Type'] = 'application/json'
          res.body = JSON.generate({ "error" => "Method not allowed" })
          next
        end

        res.status = 200
        res['Content-Type'] = 'application/json'
        res['Access-Control-Allow-Origin'] = '*'
        res.body = JSON.generate({ "status" => "ok" })
      end

      # POST /chat - Main agent endpoint
      server.mount_proc '/chat' do |req, res|
        res['Access-Control-Allow-Origin'] = '*'
        res['Content-Type'] = 'application/json'

        # Handle CORS preflight
        if req.request_method == 'OPTIONS'
          res['Access-Control-Allow-Methods'] = 'POST, OPTIONS'
          res['Access-Control-Allow-Headers'] = 'Content-Type'
          res.status = 204
          next
        end

        unless req.request_method == 'POST'
          res.status = 405
          res.body = JSON.generate({ "error" => "Only POST allowed" })
          next
        end

        # Parse request body
        begin
          body = JSON.parse(req.body)
        rescue JSON::ParserError
          res.status = 400
          res.body = JSON.generate({ "error" => "Invalid JSON body" })
          next
        end

        # Validate messages
        messages = body['messages']
        unless messages.is_a?(Array) && !messages.empty?
          res.status = 400
          res.body = JSON.generate({ "error" => "messages must be a non-empty array" })
          next
        end

        # Validate message structure
        catch(:invalid_message) do
          messages.each_with_index do |msg, i|
            unless msg.is_a?(Hash) && msg['role'] && msg['content']
              res.status = 400
              res.body = JSON.generate({ "error" => "Message at index #{i} must have 'role' and 'content'" })
              throw :invalid_message
            end
          end
        end
        # If validation failed, stop processing
        next if res.status == 400

        # Process through agent
        begin
          result = process_with_timeout(@agent, :process, [messages], 28)
          res.status = 200
          res.body = JSON.generate(result)
        rescue => e
          res.status = 500
          res.body = JSON.generate({
            "reply" => "I encountered an error processing your request. Please try again.",
            "recommendations" => [],
            "end_of_conversation" => true
          })
          puts "[Server] Error: #{e.message}"
        end
      end

      # GET / - Root landing page for browser visitors (must be mounted LAST)
      server.mount_proc '/' do |req, res|
        res['Content-Type'] = 'application/json'
        res['Access-Control-Allow-Origin'] = '*'
        res.status = 200
        res.body = JSON.generate({
          "service" => "SHL Assessment Recommendation Agent",
          "version" => "1.0",
          "endpoints" => {
            "health" => { "method" => "GET", "path" => "/health", "description" => "Health check" },
            "chat" => { "method" => "POST", "path" => "/chat", "description" => "Conversational assessment recommendations" }
          },
          "status" => "ok"
        })
      end

      # Handle shutdown gracefully
      trap('INT') { server.shutdown }
      trap('TERM') { server.shutdown }

      puts "[Server] Starting SHL Assessment Agent API on http://#{HOST}:#{PORT}"
      puts "[Server] Health check: http://localhost:#{PORT}/health"
      puts "[Server] Chat endpoint: POST http://localhost:#{PORT}/chat"
      puts "[Server] Press Ctrl+C to stop."

      server.start
    end

    private

    def process_with_timeout(obj, method, args, timeout_sec)
      result = nil
      thread = Thread.new { result = obj.send(method, *args) }
      thread.join(timeout_sec)
      if thread.alive?
        thread.kill
        raise Timeout::Error, "Request timed out"
      end
      result
    end
  end
end

# Run the server if this file is executed directly
if __FILE__ == $0
  server = SHL::APIServer.new
  server.start
end
