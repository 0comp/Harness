require "net/http"
require "json"
require "uri"

OLLAMA_URL = URI("http://localhost:11434/api/chat")

DEFAULT_TEMPERATURE = 0.2

def chat(messages, tools: nil, temperature: DEFAULT_TEMPERATURE)
  messages = [{ role: "user", content: messages }] if messages.is_a?(String)
  request = Net::HTTP::Post.new(OLLAMA_URL)
  request["content-type"] = "application/json"

  body = {
    model: "smollm2:latest",
    stream: false,
    options: { temperature: temperature },
    messages: messages
  }
  body[:tools] = tools if tools

  request.body = JSON.generate(body)

  response = Net::HTTP.start(OLLAMA_URL.hostname, OLLAMA_URL.port,
                             read_timeout: 300, open_timeout: 30) do |http|
    http.request(request)
  end

  data = JSON.parse(response.body)
  raise "Ollama error: #{data}" unless response.is_a?(Net::HTTPSuccess)

  data["message"]
end

TOOLS = [
  {
    type: "function",
    function: {
      name: "brainstorm",
      description: "Ask an advisor for the most useful next step when you are unsure how to proceed. Returns one recommended action with a short reason.",
      parameters: {
        type: "object",
        properties: {
          problem: {
            type: "string",
            description: "The task or situation you need advice on"
          }
        },
        required: ["problem"]
      }
    }
  }
]

ADVISOR_SYSTEM = "You are an advisor. Read the question and the situation, then recommend the single most useful next step, with a short reason and one or two concrete details. Keep it under 120 words. Advise on the next step only; don't answer the whole question."

def use_tool(name, args, question:)
  case name
  when "brainstorm"
    messages = [
      { role: "system", content: ADVISOR_SYSTEM },
      { role: "user", content: "Question: #{question}\nSituation: #{args["problem"]}\nWhat should be done next?" }
    ]
    advice = chat(messages)["content"]

    puts "--- ADVICE ---"
    puts advice
    puts "--------------"

    advice
  else
    "Unknown tool: #{name}"
  end
end

def available_tools(last_tool, streak, max_consecutive)
  return TOOLS if streak < max_consecutive
  TOOLS.reject { |t| t[:function][:name] == last_tool }
end

def build_prompt(question, advice)
  return question if advice.empty?

  numbered = advice.each_with_index.map { |a, i| "#{i + 1}. #{a}" }.join("\n\n")
  "#{question}\n\nAdvice gathered so far:\n#{numbered}"
end

def ask_with_tools(prompt, max_consecutive: 3, max_rounds: 20)
  system = {
    role: "system",
    content: "If you are unsure what the next step should be, call the brainstorm tool. Use the advice you receive to write the final answer."
  }
  advice = []
  last_tool = nil
  streak = 0

  max_rounds.times do
    messages = [system, { role: "user", content: build_prompt(prompt, advice) }]

    offered = available_tools(last_tool, streak, max_consecutive)
    message = chat(messages, tools: offered.empty? ? nil : offered)

    tool_calls = message["tool_calls"]
    return message["content"].to_s if tool_calls.nil? || tool_calls.empty?

    tool_calls.each do |call|
      name = call["function"]["name"]
      args = call["function"]["arguments"]

      # Count consecutive calls to the same tool; a different tool resets the count
      streak = name == last_tool ? streak + 1 : 1
      last_tool = name

      advice << use_tool(name, args, question: prompt)
    end
  end

  "Stopped after #{max_rounds} rounds without a final answer."
end

puts ask_with_tools("How do i make sushi")


  # DEN FASTNAR I SIG SJÄLV DÄR DEN TYP KOPIERAR AV VAD BRAINSTORM SADE. TROR FÖR ATT DEN INTE SPECIFIERAR ATT DET ÄR TIPS FÖR ALLT.