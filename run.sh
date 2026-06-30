#!/bin/bash
# SHL Assessment Recommendation Agent - Runner
# Usage: ./run.sh [command]

PORT=${PORT:-8000}

case "${1:-server}" in
  server)
    echo "Starting SHL Assessment Agent API Server..."
    echo "Health check: http://localhost:$PORT/health"
    echo "Chat endpoint: POST http://localhost:$PORT/chat"
    ruby -e "require_relative 'server'; SHL::APIServer.new.start"
    ;;
  test)
    echo "Running evaluation tests against server at http://localhost:$PORT"
    ruby -e "require_relative 'test_traces'; SHL::TestTraces::Evaluator.new('http://localhost:$PORT').run_all"
    ;;
  eval)
    echo "Running evaluation tests against external URL..."
    ruby -e "require_relative 'test_traces'; SHL::TestTraces::Evaluator.new('${2:-http://localhost:$PORT}').run_all"
    ;;
  scrape)
    echo "Scraping SHL catalog..."
    ruby -e "
      require_relative 'catalog'
      c = SHL::Catalog.new
      puts \"Found #{c.assessments.length} assessments:\"
      c.assessments.each { |a| puts \"  - #{a['name']} (#{a['test_type']}) - #{a['url']}\" }
    "
    ;;
  interactive)
    echo "Starting interactive agent session..."
    ruby -e "
      require_relative 'agent'
      agent = SHL::Agent.new
      messages = []
      puts 'SHL Assessment Agent (type \"exit\" to quit)'
      puts '-' * 40
      loop do
        print 'You: '
        input = STDIN.gets.strip
        break if input == 'exit' || input == 'quit'
        messages << { 'role' => 'user', 'content' => input }
        response = agent.process(messages)
        puts \"Agent: \#{response['reply']}\"
        if response['recommendations']&.any?
          puts 'Recommendations:'
          response['recommendations'].each { |r| puts \"  - \#{r['name']}: \#{r['url']}\" }
        end
        messages << { 'role' => 'assistant', 'content' => response['reply'], 'recommendations' => response['recommendations'] }
        puts
      end
    "
    ;;
  *)
    echo "Usage: ./run.sh [server|test|eval|scrape|interactive]"
    echo ""
    echo "Commands:"
    echo "  server       Start the API server (default)"
    echo "  test         Run evaluation tests against local server"
    echo "  eval <url>   Run evaluation tests against external URL"
    echo "  scrape       Show scraped catalog data"
    echo "  interactive  Start an interactive agent session"
    ;;
esac
