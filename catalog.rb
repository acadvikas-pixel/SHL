require 'net/http'
require 'json'
require 'nokogiri'
require 'csv'
require 'fileutils'
require 'time'
require 'uri'

module SHL
  class Catalog
    CATALOG_URL = "https://www.shl.com/solutions/products/product-catalog/"
    CACHE_FILE = File.join(__dir__, "catalog_cache.json")
    CACHE_DURATION = 3600 # 1 hour

    attr_reader :assessments, :last_updated

    def initialize
      @assessments = []
      @last_updated = nil
      load_or_scrape
    end

    def load_or_scrape
      if File.exist?(CACHE_FILE) && (Time.now - File.mtime(CACHE_FILE)) < CACHE_DURATION
        load_cache
        puts "[Catalog] Loaded #{@assessments.length} assessments from cache."
      else
        scrape
        save_cache
      end
    end

    def scrape
      puts "[Catalog] Scraping SHL product catalog from #{CATALOG_URL}..."
      begin
        uri = URI(CATALOG_URL)
        response = Net::HTTP.get_response(uri)

        # Follow redirects
        if response.code.to_i == 301 || response.code.to_i == 302
          location = response['location']
          if location
            puts "[Catalog] Following redirect to #{location}"
            uri = URI(location)
            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl = (uri.scheme == 'https')
            response = http.request(Net::HTTP::Get.new(uri))
          end
        end

        if response.code.to_i != 200
          puts "[Catalog] HTTP #{response.code} fetching catalog. Using fallback data."
          use_fallback
          return
        end

        html = response.body
        doc = Nokogiri::HTML(html)
        @assessments = []
        @last_updated = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')

        # Parse the product catalog table
        # SHL catalog typically has assessments in a table with columns: name, url, test type
        table = doc.at_css('table') || doc.at_css('.product-table') || doc.at_css('[class*="table"]')

        if table
          rows = table.css('tr')
          rows.each do |row|
            cells = row.css('td')
            next if cells.empty?

            name_cell = cells[0]
            next unless name_cell

            name = name_cell.text.strip
            link = name_cell.at_css('a')
            url = link ? URI.join(CATALOG_URL, link['href']).to_s : nil

            test_type = cells[1] ? cells[1].text.strip : nil
            description = cells[2] ? cells[2].text.strip : nil

            next if name.empty? || name.downcase.include?('product') && name.length < 10

            @assessments << {
              "name" => name,
              "url" => url || "#{CATALOG_URL}##{name.gsub(/\s+/, '-').downcase}",
              "test_type" => test_type || "K",
              "description" => description || "",
              "keywords" => extract_keywords(name, description || "")
            }
          end
        end

        # If no table found, try alternative parsing
        if @assessments.empty?
          puts "[Catalog] No table found on page. Trying alternative parsing..."
          # Try to find assessment links
          doc.css('a').each do |link|
            href = link['href']
            text = link.text.strip
            next if text.empty? || href.nil?
            next unless href.include?('/product/') || href.include?('/assessment/')
            @assessments << {
              "name" => text,
              "url" => URI.join(CATALOG_URL, href).to_s,
              "test_type" => "K",
              "description" => "",
              "keywords" => extract_keywords(text, "")
            }
          end
        end

        if @assessments.empty?
          puts "[Catalog] Could not parse SHL catalog. Using fallback dataset."
          use_fallback
        else
          puts "[Catalog] Successfully scraped #{@assessments.length} assessments."
        end

      rescue => e
        puts "[Catalog] Error scraping catalog: #{e.message}"
        use_fallback
      end
    end

    def use_fallback
      puts "[Catalog] Using built-in assessment dataset."
      @assessments = FALLBACK_ASSESSMENTS.dup
      @last_updated = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
    end

    def extract_keywords(name, description)
      words = (name + " " + description).downcase
        .gsub(/[^a-z0-9\s]/, ' ')
        .split(/\s+/)
        .reject { |w| w.length < 2 }

      # Add role-related keywords
      role_keywords = {
        'java' => ['java', 'developer', 'backend', 'programming', 'object-oriented'],
        'python' => ['python', 'developer', 'programming', 'scripting', 'data-science'],
        'javascript' => ['javascript', 'web', 'frontend', 'developer', 'full-stack'],
        'manager' => ['management', 'leadership', 'manager', 'supervisory', 'people-management'],
        'sales' => ['sales', 'account-management', 'business-development', 'customer-facing'],
        'analyst' => ['analyst', 'business-analyst', 'data-analysis', 'critical-thinking'],
        'engineer' => ['engineering', 'technical', 'problem-solving', 'analytical'],
        'executive' => ['executive', 'c-suite', 'strategic', 'leadership', 'decision-making'],
      }

      role_keywords.each do |key, kw|
        if name.downcase.include?(key)
          words.concat(kw)
        end
      end

      words.uniq
    end

    def search(query)
      return @assessments if query.nil? || query.strip.empty?

      query = query.downcase
      # Split on whitespace, preserving original words, then also split
      # each word on non-alphanumeric chars to handle "java+react," -> ["java","react"]
      # Keep original words too so "full-stack" still matches keyword 'full-stack'
      query_words = query.split(/\s+/).flat_map { |w|
        [w] + w.gsub(/[^a-z0-9]/, ' ').split(/\s+/)
      }.reject { |w| w.length < 2 }.uniq

      scored = @assessments.map do |a|
        score = 0
        name_lower = a["name"].downcase
        desc_lower = a["description"].downcase
        kw = a["keywords"]

        query_words.each do |qw|
          if name_lower.include?(qw)
            score += 10
          end
          if kw.include?(qw)
            score += 5
          end
          if desc_lower.include?(qw)
            score += 3
          end
        end

        # Exact phrase match
        if name_lower.include?(query)
          score += 15
        end

        { assessment: a, score: score }
      end

      scored.sort_by { |s| -s[:score] }.map { |s| s[:assessment] }
    end

    def find_by_name(name)
      @assessments.find { |a| a["name"].downcase == name.downcase }
    end

    def search_by_role(role)
      role_keywords = role.downcase.split(/\s+/)
      @assessments.select do |a|
        kw = a["keywords"]
        role_keywords.any? { |rk| kw.include?(rk) } ||
          role_keywords.any? { |rk| a["name"].downcase.include?(rk) }
      end
    end

    private

    def load_cache
      data = JSON.parse(File.read(CACHE_FILE))
      @assessments = data["assessments"]
      @last_updated = data["last_updated"]
    rescue
      puts "[Catalog] Cache corrupted, re-scraping."
      scrape
    end

    def save_cache
      data = {
        "last_updated" => @last_updated,
        "assessments" => @assessments
      }
      File.write(CACHE_FILE, JSON.pretty_generate(data))
      puts "[Catalog] Cache saved to #{CACHE_FILE}"
    rescue => e
      puts "[Catalog] Could not save cache: #{e.message}"
    end

    # Comprehensive fallback dataset of SHL Individual Test Solutions
    FALLBACK_ASSESSMENTS = [
      { "name" => "Java 8 (New)", "url" => "https://www.shl.com/solutions/products/product-catalog/view/java-8-new/", "test_type" => "K", "description" => "Measures Java 8 programming skills including lambdas, streams, functional interfaces", "keywords" => %w[java programming developer backend object-oriented coding] },
      { "name" => "Java 11", "url" => "https://www.shl.com/solutions/products/product-catalog/view/java-11/", "test_type" => "K", "description" => "Measures Java 11 programming skills", "keywords" => %w[java programming developer backend] },
      { "name" => "Python 3", "url" => "https://www.shl.com/solutions/products/product-catalog/view/python-3/", "test_type" => "K", "description" => "Measures Python 3 programming skills", "keywords" => %w[python programming developer scripting data-science] },
      { "name" => "JavaScript", "url" => "https://www.shl.com/solutions/products/product-catalog/view/javascript/", "test_type" => "K", "description" => "Measures JavaScript programming skills for web development", "keywords" => %w[javascript web frontend developer full-stack programming] },
      { "name" => "TypeScript", "url" => "https://www.shl.com/solutions/products/product-catalog/view/typescript/", "test_type" => "K", "description" => "Measures TypeScript programming skills", "keywords" => %w[typescript javascript web frontend developer programming] },
      { "name" => "C#", "url" => "https://www.shl.com/solutions/products/product-catalog/view/c-sharp/", "test_type" => "K", "description" => "Measures C# programming skills", "keywords" => %w[c-sharp csharp dotnet programming developer backend] },
      { "name" => "SQL", "url" => "https://www.shl.com/solutions/products/product-catalog/view/sql/", "test_type" => "K", "description" => "Measures SQL and database querying skills", "keywords" => %w[sql database querying data backend developer] },
      { "name" => "React", "url" => "https://www.shl.com/solutions/products/product-catalog/view/react/", "test_type" => "K", "description" => "Measures React frontend development skills", "keywords" => %w[react javascript frontend web developer ui] },
      { "name" => "Angular", "url" => "https://www.shl.com/solutions/products/product-catalog/view/angular/", "test_type" => "K", "description" => "Measures Angular frontend development skills", "keywords" => %w[angular javascript frontend web developer typescript] },
      { "name" => "Node.js", "url" => "https://www.shl.com/solutions/products/product-catalog/view/node-js/", "test_type" => "K", "description" => "Measures Node.js backend development skills", "keywords" => %w[nodejs javascript backend developer full-stack] },
      { "name" => "Go", "url" => "https://www.shl.com/solutions/products/product-catalog/view/go/", "test_type" => "K", "description" => "Measures Go programming skills", "keywords" => %w[go golang programming developer backend] },
      { "name" => "Rust", "url" => "https://www.shl.com/solutions/products/product-catalog/view/rust/", "test_type" => "K", "description" => "Measures Rust programming skills", "keywords" => %w[rust programming developer systems] },
      { "name" => "Ruby", "url" => "https://www.shl.com/solutions/products/product-catalog/view/ruby/", "test_type" => "K", "description" => "Measures Ruby programming skills", "keywords" => %w[ruby programming developer web rails] },
      { "name" => "PHP", "url" => "https://www.shl.com/solutions/products/product-catalog/view/php/", "test_type" => "K", "description" => "Measures PHP programming skills", "keywords" => %w[php programming developer web backend] },
      { "name" => "Docker", "url" => "https://www.shl.com/solutions/products/product-catalog/view/docker/", "test_type" => "K", "description" => "Measures Docker and containerization skills", "keywords" => %w[docker container devops infrastructure engineering] },
      { "name" => "Kubernetes", "url" => "https://www.shl.com/solutions/products/product-catalog/view/kubernetes/", "test_type" => "K", "description" => "Measures Kubernetes orchestration skills", "keywords" => %w[kubernetes k8s container orchestration devops engineering] },
      { "name" => "AWS", "url" => "https://www.shl.com/solutions/products/product-catalog/view/aws/", "test_type" => "K", "description" => "Measures Amazon Web Services cloud skills", "keywords" => %w[aws cloud devops infrastructure engineering] },
      { "name" => "Azure", "url" => "https://www.shl.com/solutions/products/product-catalog/view/azure/", "test_type" => "K", "description" => "Measures Microsoft Azure cloud skills", "keywords" => %w[azure cloud devops infrastructure engineering] },
      { "name" => "GCP", "url" => "https://www.shl.com/solutions/products/product-catalog/view/gcp/", "test_type" => "K", "description" => "Measures Google Cloud Platform skills", "keywords" => %w[gcp google-cloud cloud devops infrastructure engineering] },
      { "name" => "OPQ32r", "url" => "https://www.shl.com/solutions/products/product-catalog/view/opq32r/", "test_type" => "P", "description" => "Occupational Personality Questionnaire - measures personality traits for job fit", "keywords" => %w[personality behavioral traits soft-skills leadership management] },
      { "name" => "OPQ32s", "url" => "https://www.shl.com/solutions/products/product-catalog/view/opq32s/", "test_type" => "P", "description" => "Short version of the Occupational Personality Questionnaire", "keywords" => %w[personality behavioral traits soft-skills quick] },
      { "name" => "MCA", "url" => "https://www.shl.com/solutions/products/product-catalog/view/mca/", "test_type" => "K", "description" => "Management and Corporate Accountability assessment", "keywords" => %w[management corporate accountability leadership] },
      { "name" => "Verify G+", "url" => "https://www.shl.com/solutions/products/product-catalog/view/verify-g-plus/", "test_type" => "K", "description" => "General Ability cognitive ability test", "keywords" => %w[cognitive ability general aptitude problem-solving analytical] },
      { "name" => "Verify Numerical Reasoning", "url" => "https://www.shl.com/solutions/products/product-catalog/view/verify-numerical/", "test_type" => "K", "description" => "Measures numerical reasoning and data interpretation skills", "keywords" => %w[numerical analytical data quantitative reasoning] },
      { "name" => "Verify Verbal Reasoning", "url" => "https://www.shl.com/solutions/products/product-catalog/view/verify-verbal/", "test_type" => "K", "description" => "Measures verbal reasoning and comprehension skills", "keywords" => %w[verbal communication comprehension reasoning analytical] },
      { "name" => "Verify Logical Reasoning", "url" => "https://www.shl.com/solutions/products/product-catalog/view/verify-logical/", "test_type" => "K", "description" => "Measures logical reasoning and problem analysis", "keywords" => %w[logical reasoning problem-solving analytical critical-thinking] },
      { "name" => "Verify Coding Ability", "url" => "https://www.shl.com/solutions/products/product-catalog/view/verify-coding/", "test_type" => "K", "description" => "General coding ability assessment", "keywords" => %w[coding programming problem-solving algorithmic] },
      { "name" => "Sales Achievement Predictor", "url" => "https://www.shl.com/solutions/products/product-catalog/view/sales-achievement-predictor/", "test_type" => "P", "description" => "Predicts sales performance and achievement potential", "keywords" => %w[sales achievement customer-facing business-development] },
      { "name" => "Customer Service Aptitude", "url" => "https://www.shl.com/solutions/products/product-catalog/view/customer-service-aptitude/", "test_type" => "K", "description" => "Measures customer service orientation and aptitude", "keywords" => %w[customer-service support communication interpersonal] },
      { "name" => "Management Aptitude", "url" => "https://www.shl.com/solutions/products/product-catalog/view/management-aptitude/", "test_type" => "K", "description" => "Measures management and supervisory potential", "keywords" => %w[management supervisory leadership people-management] },
      { "name" => "Data Analysis Skills", "url" => "https://www.shl.com/solutions/products/product-catalog/view/data-analysis-skills/", "test_type" => "K", "description" => "Measures data analysis and interpretation skills", "keywords" => %w[data analysis analytics analytical interpretation] },
      { "name" => "Attention to Detail", "url" => "https://www.shl.com/solutions/products/product-catalog/view/attention-to-detail/", "test_type" => "K", "description" => "Measures attention to detail and accuracy", "keywords" => %w[detail accuracy precision careful meticulous] },
      { "name" => "Critical Thinking", "url" => "https://www.shl.com/solutions/products/product-catalog/view/critical-thinking/", "test_type" => "K", "description" => "Measures critical thinking and analytical reasoning", "keywords" => %w[critical-thinking analytical reasoning problem-solving evaluation] },
      { "name" => "Communication Skills", "url" => "https://www.shl.com/solutions/products/product-catalog/view/communication-skills/", "test_type" => "K", "description" => "Measures written and verbal communication skills", "keywords" => %w[communication written verbal interpersonal soft-skills] },
      { "name" => "Team Effectiveness", "url" => "https://www.shl.com/solutions/products/product-catalog/view/team-effectiveness/", "test_type" => "P", "description" => "Measures teamwork and collaboration preferences", "keywords" => %w[teamwork collaboration interpersonal cooperation] },
      { "name" => "Emotional Intelligence", "url" => "https://www.shl.com/solutions/products/product-catalog/view/emotional-intelligence/", "test_type" => "P", "description" => "Measures emotional intelligence and self-awareness", "keywords" => %w[emotional-intelligence eq self-awareness empathy interpersonal] },
      { "name" => "Decision Making", "url" => "https://www.shl.com/solutions/products/product-catalog/view/decision-making/", "test_type" => "K", "description" => "Measures decision-making and judgment skills", "keywords" => %w[decision-making judgment analytical problem-solving] },
      { "name" => "Adaptability", "url" => "https://www.shl.com/solutions/products/product-catalog/view/adaptability/", "test_type" => "P", "description" => "Measures adaptability and flexibility in changing environments", "keywords" => %w[adaptability flexibility change resilience agility] },
    ].freeze
  end
end
