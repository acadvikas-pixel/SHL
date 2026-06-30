require_relative 'catalog'

module SHL
  class Agent
    attr_reader :catalog

    # Conversational behaviors the agent identifies
    BEHAVIOR_CLARIFY = :clarify
    BEHAVIOR_RECOMMEND = :recommend
    BEHAVIOR_REFINE = :refine
    BEHAVIOR_COMPARE = :compare
    BEHAVIOR_REFUSE = :refuse
    BEHAVIOR_GREETING = :greeting

    def initialize(catalog = nil)
      @catalog = catalog || Catalog.new
    end

    # Main entry point: process a full conversation history and return agent response
    def process(messages)
      # Validate input
      return error_response("messages must be an array") unless messages.is_a?(Array)
      return error_response("messages cannot be empty") if messages.empty?

      # Extract context
      user_messages = messages.select { |m| m["role"] == "user" }
      last_message = messages.last
      last_user_content = user_messages.last&.dig("content") || ""

      # Check for off-topic / prompt injection
      refusal = check_refusal(last_user_content)
      if refusal
        return refusal_response(refusal)
      end

      # Detect behavior
      behavior = detect_behavior(messages, last_user_content)

      # Build conversation summary for context
      context = build_context(messages)

      # Handle the detected behavior
      case behavior
      when BEHAVIOR_GREETING
        handle_greeting(context)
      when BEHAVIOR_CLARIFY
        handle_clarify(context, last_user_content)
      when BEHAVIOR_RECOMMEND
        handle_recommend(context, last_user_content, messages)
      when BEHAVIOR_REFINE
        handle_refine(context, last_user_content, messages)
      when BEHAVIOR_COMPARE
        handle_compare(context, last_user_content)
      else
        handle_clarify(context, last_user_content)
      end
    end

    private

    def detect_behavior(messages, content)
      content_lower = content.downcase.strip

      # Check for greeting - use word boundaries to avoid matching "hi" in "hiring"
      if messages.length <= 2
        greeting_patterns = [/\bhi\b/i, /\bhello\b/i, /\bhey\b/i, /\bgreetings\b/i,
                            /\bgood morning\b/i, /\bgood afternoon\b/i, /\bgood evening\b/i]
        return BEHAVIOR_GREETING if greeting_patterns.any? { |p| content_lower.match?(p) }
      end

      # Check for compare (use word boundaries to avoid "compare" in "comparing")
      compare_patterns = [/\bcompare\b/i, /\bvs\b/i, /\bversus\b/i, /\bdifference between\b/i]
      return BEHAVIOR_COMPARE if compare_patterns.any? { |p| content_lower.match?(p) }

      # Check for refine (changing previous constraints)
      # Require at least 2 user messages (3 total messages: user1 + assistant1 + user2)
      if messages.length >= 3
        refine_patterns = [/\bactually\b/, /\binstead\b/, /\bchange\b/, /\bupdate\b/, /\brevise\b/, /\blet me correct\b/,
                          /\bi meant\b/, /\bmodify\b/, /\bdifferent\b/, /\bnot what i\b/, /\brather\b/, /\bon second thought\b/,
                          /\bwait\b/, /\bto be more specific\b/, /\bforget\b/]
        return BEHAVIOR_REFINE if refine_patterns.any? { |r| content_lower.match?(r) }
      end

      # Check if we have enough context to recommend
      if has_sufficient_context?(messages, content_lower)
        return BEHAVIOR_RECOMMEND
      end

      # Check if user is asking for a recommendation directly
      recommend_patterns = ['recommend', 'suggest', 'what assessment', 'what assessments', 'which test', 'find assessment',
                           'i need', 'looking for', 'suitable', 'appropriate', 'hire',
                           'hiring', 'recruit', 'recruiting', 'assessments do you']
      if recommend_patterns.any? { |r| content_lower.include?(r) }
        # But we might still need clarification
        if has_role_seniority?(content_lower)
          return BEHAVIOR_RECOMMEND
        end
        return BEHAVIOR_CLARIFY
      end

      BEHAVIOR_CLARIFY
    end

    def has_sufficient_context?(messages, latest_content)
      full_text = messages.select { |m| m["role"] == "user" }.map { |m| m["content"] }.join(" ").downcase

      # Check for role/skill + seniority
      has_role = has_role_seniority?(full_text)

      # Count previous recommendations
      assistant_msgs = messages.select { |m| m["role"] == "assistant" }
      previous_recs = assistant_msgs.select { |m|
        (m["recommendations"] && m["recommendations"].any?) ||
        (m["content"] && (m["content"].include?("recommendation") || m["content"].include?("shortlist")))
      }

      # If we've already recommended, refine (not re-recommend from scratch)
      if previous_recs.any?
        return false  # Let refine handle it
      end

      # Sufficient context requires role/seniority information.
      # Pure asking words ("need", "looking for") without role context
      # should fall through to the recommend_patterns fallback which
      # distinguishes between has_role (recommend) and no_role (clarify).
      has_role
    end

    def has_role_seniority?(text)
      text_lower = text.downcase
      roles = ['developer', 'engineer', 'manager', 'analyst', 'architect', 'director',
               'lead', 'specialist', 'consultant', 'administrator', 'associate',
               'java', 'python', 'javascript', 'react', 'angular', 'node', 'sql',
               'sales', 'marketing', 'finance', 'hr', 'operations', 'support',
               'product', 'design', 'devops', 'data', 'scientist', 'researcher',
               'full-stack', 'frontend', 'backend', 'mobile', 'qa', 'tester',
               'representative', 'coordinator', 'assistant', 'clerk', 'agent',
               'vp', 'vice president', 'c-suite', 'chief', 'head', 'officer']
      seniority = ['junior', 'mid', 'senior', 'lead', 'principal', 'staff', 'entry',
                   'associate', 'level', 'years', 'experienced', 'head', 'vp',
                   'director', 'manager', 'executive', 'graduate', 'intern',
                   'vice president', 'chief', 'officer', 'representative']

      has_role_word = roles.any? { |r| text_lower.include?(r) }
      has_seniority_word = seniority.any? { |s| text_lower.include?(s) }

      has_role_word || has_seniority_word
    end

    def build_context(messages)
      user_msgs = messages.select { |m| m["role"] == "user" }
      assistant_msgs = messages.select { |m| m["role"] == "assistant" }

      {
        user_messages: user_msgs,
        assistant_messages: assistant_msgs,
        all_text: user_msgs.map { |m| m["content"] }.join(" "),
        turn_count: messages.length,
        has_previous_recommendations: assistant_msgs.any? { |m| m["recommendations"]&.any? },
        previous_recommendations: assistant_msgs.flat_map { |m| m["recommendations"] || [] }.uniq { |r| r["name"] }
      }
    end

    def handle_greeting(context)
      {
        "reply" => "Hello! I'm the SHL Assessment Advisor. I can help you find the right assessments for your hiring needs. Could you tell me about the role you're hiring for?",
        "recommendations" => [],
        "end_of_conversation" => false
      }
    end

    def handle_clarify(context, content)
      # Determine what information we're missing
      text = context[:all_text].downcase + " " + content.downcase

      missing_role = !has_role_seniority?(text)

      if missing_role
        return {
          "reply" => "I'd be happy to help find the right assessments! Could you tell me more about the role? For example, what specific skills or job title are you hiring for, and what level of seniority?",
          "recommendations" => [],
          "end_of_conversation" => false
        }
      end

      # We have some info but might need more
      {
        "reply" => "Thanks! One more thing — could you specify the seniority level (e.g., junior, mid, senior) or any particular skills you'd like to assess beyond the core requirements? This will help me narrow down the best assessments.",
        "recommendations" => [],
        "end_of_conversation" => false
      }
    end

    def handle_recommend(context, latest_content, messages)
      text = context[:all_text].downcase + " " + latest_content.downcase
      recommendations = generate_recommendations(text, messages)

      if recommendations.empty?
        return {
          "reply" => "I wasn't able to find assessments matching your criteria. Could you provide more details about the role, such as specific skills or technologies involved?",
          "recommendations" => [],
          "end_of_conversation" => false
        }
      end

      reply = build_reply(recommendations, text)
      {
        "reply" => reply,
        "recommendations" => recommendations.map { |r| { "name" => r["name"], "url" => r["url"], "test_type" => r["test_type"] } },
        "end_of_conversation" => true
      }
    end

    def handle_refine(context, latest_content, messages)
      text = context[:all_text].downcase + " " + latest_content.downcase
      previous_recs = context[:previous_recommendations]

      # Generate new recommendations that respect the new constraints
      recommendations = generate_recommendations(text, messages)

      if recommendations.empty?
        return {
          "reply" => "I understand you'd like to adjust the criteria. Could you clarify the changes so I can update the recommendations?",
          "recommendations" => previous_recs.map { |r| { "name" => r["name"], "url" => r["url"], "test_type" => r["test_type"] } },
          "end_of_conversation" => false
        }
      end

      reply = "Sure, I've updated the shortlist based on your new requirements. Here are the revised recommendations:\n\n"
      reply += recommendations.each_with_index.map { |r, i|
        "#{i+1}. **#{r['name']}** (#{r['test_type'] == 'P' ? 'Personality' : 'Knowledge/Skills'}) - #{r['url']}"
      }.join("\n")

      {
        "reply" => reply,
        "recommendations" => recommendations.map { |r| { "name" => r["name"], "url" => r["url"], "test_type" => r["test_type"] } },
        "end_of_conversation" => false
      }
    end

    def handle_compare(context, content)
      text = context[:all_text].downcase + " " + content.downcase

      # Extract assessment names to compare
      assessment_names = @catalog.assessments.map { |a| a["name"].downcase }
      mentioned = assessment_names.select { |an| text.include?(an) }

      assessments_to_compare = mentioned.map { |m| @catalog.assessments.find { |a| a["name"].downcase == m } }.compact

      if assessments_to_compare.length < 2
        return {
          "reply" => "I can help compare assessments! Which specific assessments would you like me to compare? Please mention at least two by name.",
          "recommendations" => [],
          "end_of_conversation" => false
        }
      end

      reply = "Here's a comparison of the assessments you mentioned:\n\n"
      assessments_to_compare.each do |a|
        type_label = a['test_type'] == 'P' ? 'Personality/Behavioral' : 'Knowledge/Skills'
        reply += "• **#{a['name']}** (Type: #{type_label})\n  #{a['description']}\n  URL: #{a['url']}\n\n"
      end
      reply += "Would you like recommendations based on this comparison, or do you have other questions?"

      {
        "reply" => reply,
        "recommendations" => assessments_to_compare.map { |r| { "name" => r["name"], "url" => r["url"], "test_type" => r["test_type"] } },
        "end_of_conversation" => false
      }
    end

    def generate_recommendations(query_text, messages)
      text = query_text.downcase

      # Extract role and skills from the conversation
      role_keywords = {
        'java' => ['java', 'jvm', 'spring', 'enterprise'],
        'python' => ['python', 'django', 'flask', 'data', 'ml', 'machine learning'],
        'javascript' => ['javascript', 'js', 'node', 'react', 'angular', 'vue', 'web'],
        'full-stack' => ['javascript', 'python', 'web', 'frontend', 'backend', 'fullstack'],
        'frontend' => ['javascript', 'react', 'angular', 'css', 'html', 'ui', 'frontend'],
        'backend' => ['java', 'python', 'node', 'sql', 'api', 'backend', 'server'],
        'devops' => ['docker', 'kubernetes', 'aws', 'azure', 'ci/cd', 'devops'],
        'data' => ['python', 'sql', 'analytics', 'data', 'machine learning'],
        'manager' => ['management', 'leadership', 'people', 'team', 'management-aptitude'],
        'sales' => ['sales', 'customer', 'communication', 'achievement'],
        'analyst' => ['analytical', 'data', 'problem-solving', 'critical-thinking', 'attention-to-detail'],
        'engineer' => ['problem-solving', 'analytical', 'technical', 'coding'],
        'support' => ['customer-service', 'communication', 'problem-solving'],
        'executive' => ['leadership', 'strategic', 'decision-making', 'emotional-intelligence'],
      }

      # Find matching roles
      matched_roles = role_keywords.select { |role, keywords|
        keywords.any? { |kw| text.include?(kw) } || text.include?(role.to_s)
      }

      # Get relevant assessments from catalog
      results = @catalog.search(text)
      role_results = matched_roles.keys.flat_map { |role| @catalog.search(role.to_s) }

      # Combine and deduplicate
      all_results = (results + role_results).uniq { |a| a["name"] }

      # Determine test type mix (knowledge + personality)
      has_personality_keywords = ['personality', 'behavioral', 'soft skills', 'culture', 'fit',
                                  'team', 'leadership', 'management', 'emotional'].any? { |k| text.include?(k) }

      knowledge = all_results.select { |a| a["test_type"] != "P" }
      personality = all_results.select { |a| a["test_type"] == "P" }

      selected = []

      # Take top knowledge assessments
      selected.concat(knowledge.first(8))

      # Add personality assessments if requested or always add at least one
      if has_personality_keywords
        selected.concat(personality.first(3))
      elsif selected.length < 10 && personality.any?
        selected.concat(personality.first([1, 10 - selected.length].min))
      end

      # Add more from general results if we have room
      if selected.length < 10
        more = all_results.reject { |a| selected.include?(a) }
        selected.concat(more.first(10 - selected.length))
      end

      selected.first(10)
    end

    def build_reply(recommendations, query_text)
      if recommendations.length == 1
        return "Based on your requirements, I recommend this assessment:\n\n**#{recommendations[0]['name']}** (#{recommendations[0]['test_type'] == 'P' ? 'Personality' : 'Knowledge/Skills'})\n#{recommendations[0]['url']}"
      end

      type_counts = recommendations.group_by { |r| r['test_type'] == 'P' ? 'Personality/Behavioral' : 'Knowledge/Skills' }
      type_summary = type_counts.map { |type, items| "#{items.length} #{type}" }.join(", ")

      reply = "Here are #{recommendations.length} SHL assessments (#{type_summary}) that match your needs:\n\n"
      reply += recommendations.each_with_index.map { |r, i|
        "#{i+1}. **#{r['name']}** (#{r['test_type'] == 'P' ? 'P' : 'K'}) - #{r['url']}"
      }.join("\n")
      reply += "\n\nWould you like to refine these results, compare any of them, or get more details?"
      reply
    end

    def check_refusal(content)
      content_lower = content.downcase

      # Off-topic detection
      off_topic_signals = [
        /weather/, /sports/, /politics/, /cooking/, /entertainment/,
        /movie/, /music/, /game/, /travel/, /fashion/,
        /what is (\d+)\+(\d+)/, /write a poem/, /tell me a joke/,
        /how old are you/, /who created you/
      ]

      off_topic_signals.each do |pattern|
        if content_lower.match?(pattern)
          return "I'm designed to help with SHL assessment recommendations only. Let's stay focused on finding the right assessments for your hiring needs. Could you tell me about the role you're hiring for?"
        end
      end

      # Prompt injection detection
      injection_signals = [
        /ignore (all )?(previous|prior|above).*(instructions|commands|directions)/,
        /forget (all )?(previous|prior|above)/,
        /you are (now |)an? (free|unrestricted|unbounded) (AI|chatbot|assistant)/,
        /new (instructions|task|command):/,
        /system prompt/i,
        /your system prompt/i,
        /reveal your (prompt|instructions|system message)/i,
        /you must (respond|answer) (regardless|even if|no matter)/i,
        /disregard (all )?(rules|guidelines|restrictions)/i,
        /act as (if you are|though you are) (a |an |)(different|unrestricted)/i,
        /simulate (being|having)/i,
        /dad mode/i,
        /developer mode/i,
        /output your (prompt|instructions)/i,
        /\[INST\]|\[\/INST\]/,
        /<s>|<\/s>/,
      ]

      injection_signals.each do |pattern|
        if content_lower.match?(pattern)
          return "I can only provide SHL assessment recommendations. Please keep our conversation focused on finding the right assessments for your hiring needs."
        end
      end

      # General hiring/legal advice refusal
      legal_patterns = [
        /legal (advice|question|matter|issue)/,
        /is it legal/, /am i (required|obligated)/,
        /should i (hire|fire|terminate)/i,
      ]

      legal_patterns.each do |pattern|
        if content_lower.match?(pattern)
          return "I can only recommend SHL assessments. For legal or HR policy questions, please consult your organization's legal department or HR team."
        end
      end

      # General hiring advice refusal (not about specific assessments)
      hiring_advice_patterns = [
        /how (to |do |should |can |)(i |we |)(conduct|structure|run|design|improve|evaluate|assess|screen).*(interview|hiring|recruiting|selection|candidates?)/i,
        /(best practices|tips|advice) (for|on|about) (hiring|interviewing|recruiting)/i,
        /how (much|many).*(salary|offer|compensation|pay)/i,
        /(what|which) (interview |)(questions|methods|techniques|strategies|process).*(use|follow|adopt|need)/i,
      ]

      hiring_advice_patterns.each do |pattern|
        if content_lower.match?(pattern)
          return "I specialize in SHL assessment recommendations. While I can't provide general hiring advice, I can help you find the right assessments to evaluate your candidates. What role are you hiring for?"
        end
      end

      nil
    end

    def refusal_response(reason)
      {
        "reply" => reason,
        "recommendations" => [],
        "end_of_conversation" => false
      }
    end

    def error_response(message)
      {
        "reply" => "Error: #{message}",
        "recommendations" => [],
        "end_of_conversation" => true
      }
    end
  end
end
