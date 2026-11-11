require "net/http"
require "json"
require "uri"
require "fileutils"

OLLAMA_URL = URI("http://localhost:11434/api/chat")

DEFAULT_TEMPERATURE = 0.2
BRAINSTORM_TEMPERATURE = 0.9
REFUSAL = /cannot be answered with the provided tools/
MODELS = {
  best:  "qwen3:14b",
  small: "smollm2:latest",
  tiny:  "llama3.1:8b"
}



def chat(messages, tools: nil, temperature: DEFAULT_TEMPERATURE, max_tokens: nil)
  messages = [{ role: "user", content: messages }] if messages.is_a?(String)
  request = Net::HTTP::Post.new(OLLAMA_URL)
  request["content-type"] = "application/json"

  options = { temperature: temperature }
  options[:num_predict] = max_tokens if max_tokens

  best = :best
  body = { model: MODELS[best], stream: false, options: options, messages: messages }
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
      description: "Brainstorm several different wider perspectives on a situation when you need to step back and see the bigger picture: other goals, other options, or factors that might be overlooked. Do not use for simple facts, math, definitions, or questions with one known answer.",
      parameters: {
        type: "object",
        properties: {
          situation: {
            type: "string",
            description: "The situation or question you want to brainstorm about"
          },
          amount: {
            type: "integer",
            description: "How many ideas to brainstorm, from 1 to 10. Defaults to 5 if omitted."
          }
        },
        required: ["situation"]
      }
    }
  },
  {
    type: "function",
    function: {
      name: "Create_file",
      content: "You create files with the Create_file tool. When asked to create a file, you must call Create_file. Never paste file contents in your reply.",
      parameters: {
        type: "object",
        properties: {
          file_name: {
            type: "string",
            description: "The name of the file, including its extension"
          },
          path: {
            type: "string",
            description: "The directory where the file should be created starting from this folder"
          },
          content: {
            type: "string",
            description: "Optional initial contents of the file"
          }
        },
        required: ["file_name", "path"]
      }
    }
  },
  {
    type: "function",
    function: {
      name: "File_remove",
      description: "Remove a file",
      parameters: {
        type: "object",
        properties: {
          file_name: {
            type: "string",
            description: "The name of the file, including its extension"
          },
          path: {
            type: "string",
            description: "The directory of the file to be removed starting from this folder"
          },
        },
        required: ["file_name", "path"]
      }
    }
  },
  {
    type: "function",
    function: {
      name: "Read_file",
      description: "Read a file",
      parameters: {
        type: "object",
        properties: {
          file_name: {
            type: "string",
            description: "The name of the file, including its extension"
          },
          path: {
            type: "string",
            description: "The directory of the file"
          },
        },
        required: ["file_name", "path"]
      }
    }
  },
  {
  type: "function",
  function: {
    name: "File_edit",
    description: "Change the text of an existing file or create it. Use insert to add lines, replace to overwrite lines, or append to add lines at the end. Do not use this to delete lines.",
    parameters: {
      type: "object",
      properties: {
        file_name: {
          type: "string",
          description: "The name of the file including its extension, for example index.html"
        },
        path: {
          type: "string",
          description: "The folder that holds the file, relative to the sandbox, for example ./ or ./css"
        },
        mode: {
          type: "string",
          enum: ["insert", "replace", "append"],
          description: "insert puts the content before start_line. replace overwrites lines from start_line to end_line with the content. append adds the content after the last line of the file."
        },
        content: {
          type: "string",
          description: "The exact text to write, with real line breaks between lines. Do not add explanations or placeholders."
        },
        start_line: {
          type: "integer",
          description: "The line number where the change begins, counting from 1. Ignored by append."
        },
        end_line: {
          type: "integer",
          description: "The last line to replace, counting from 1, inclusive. Only used by replace. Leave out to replace only as many lines as the content has."
        }
      },
      required: ["file_name", "path", "mode", "content"]
    }
  }
}
  # Maybe add a file manager for creating, writing, and removing files.
]

BRAINSTORM_SYSTEM = "You brainstorm. Given a question and a situation, come up with different ideas that widen the view: other goals, other options, and factors that are easy to overlook. Make every idea a different angle from the others. Give each one a short label and an explanation. Do not write the final answer."



def clamp(value, low, high)
  [[value, low].max, high].min
end

def save_lines(full_path, lines)
  FileUtils.mkdir_p(File.dirname(full_path))
  tmp = "#{full_path}.tmp"
  File.write(tmp, lines.join)
  FileUtils.mv(tmp, full_path, force: true)
end

WRITE_MODES = %w[insert replace append remove]

def write_file(full_path, mode:, content:, start_line: 1, end_line: nil)
  mode = mode.to_s.strip.downcase
  unless WRITE_MODES.include?(mode)
    return "Error: unknown mode '#{mode}'. Use insert, replace, append or remove."
  end

  lines = File.exist?(full_path) ? File.readlines(full_path) : []
  new_lines = content.to_s.lines
  new_lines << "\n" if new_lines.any? && !new_lines.last.end_with?("\n")

  start_idx = clamp(start_line.to_i - 1, 0, lines.size)

  case mode
  when "append"
    lines.concat(new_lines)
  when "insert"
    lines.insert(start_idx, *new_lines)
  when "replace"
    end_idx = if end_line
                clamp(end_line.to_i, start_idx, lines.size)
              else
                clamp(start_idx + new_lines.size, start_idx, lines.size)
              end
    lines[start_idx...end_idx] = new_lines
  when "remove"
    end_idx = if end_line
                clamp(end_line.to_i, start_idx, lines.size)
              else
                clamp(start_idx + 1, start_idx, lines.size)
              end
    lines.slice!(start_idx...end_idx)
  end

  save_lines(full_path, lines)
  "Done: #{mode} at line #{start_idx + 1} in #{File.basename(full_path)}"
end

BASE_DIR = File.expand_path("./sandbox")

def safe_path(path)
  full = File.expand_path(File.join(BASE_DIR, path.to_s))
  raise "Path outside sandbox: #{path}" unless full.start_with?(BASE_DIR + File::SEPARATOR)
  full
end

def use_tool(name, args, question: nil, previous_ideas: [])
  case name
  when "Create_file"
    full = safe_path(File.join(args["path"].to_s, args["file_name"].to_s))
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, args["content"].to_s)
    "Created #{args["file_name"]}"
  
  when "Read_file"
    full = safe_path(File.join(args["path"].to_s, args["file_name"].to_s))
    return "Error: #{args["file_name"]} does not exist" unless File.file?(full)

    numbered = File.readlines(full).each_with_index.map { |line, i| "#{i + 1}: #{line}" }
    numbered.join

  when "File_edit"
    full = safe_path(File.join(args["path"].to_s, args["file_name"].to_s))
    write_file(full,
               mode: args["mode"],
               content: args["content"],
               start_line: (args["start_line"] || 1).to_i,
               end_line: args["end_line"]&.to_i)

  when "File_remove"
    full = safe_path(File.join(args["path"].to_s, args["file_name"].to_s))
    if File.file?(full)
      File.delete(full)
      "Removed #{args["file_name"]}"
    else
      "Error: #{args["file_name"]} does not exist at #{args["path"]}"
    end

  when "brainstorm"
    earlier  = previous_ideas.empty? ? "None yet." : previous_ideas.join("\n")
    amount   = (args["amount"] || 5).to_i
    messages = [
      { role: "system", content: BRAINSTORM_SYSTEM },
      { role: "user", content: "Question: #{question}\nSituation: #{args["situation"]}\nIdeas already given:\n#{earlier}\n\nBrainstorm #{amount} different ideas that are not already covered above." }
    ]
    chat(messages, temperature: BRAINSTORM_TEMPERATURE)["content"].to_s

  else
    "Unknown tool: #{name}"
  end
rescue => e
  "Error: #{e.message}"
end
  

def available_tools(last_tool, streak, max_consecutive)
  return TOOLS if streak < max_consecutive
  TOOLS.reject { |t| t[:function][:name] == last_tool }
end

def build_prompt(question, ideas)
  return question if ideas.empty?

  numbered = ideas.each_with_index.map { |a, i| "#{i + 1}. #{a}" }.join("\n\n")
  <<~TEXT
    Question: #{question}

    
  TEXT
end

def ask_with_tools(prompt, notes, max_rounds: 10)
    messages = [
    {
      role: "system",
      content: "You are a helpful AI assistant. Answer the user's question using the provided notes. Dont include the notes in the awnser only use them to help you make a good reply. Use tools when Needed."
    },
    { role: "assistant", content: notes },
    { role: "user", content: prompt }
  ]
  
  max_rounds.times do
    message = chat(messages, tools: TOOLS)
    tool_calls = message["tool_calls"]
    return message["content"].to_s if tool_calls.nil? || tool_calls.empty?
    messages << message
    tool_calls.each do |call|
      name = call["function"]["name"]
      args = call["function"]["arguments"]
      result = use_tool(name, args, question: prompt)
      messages << { role: "tool", content: result.to_s }
    end
  end

  "Stopped after #{max_rounds} rounds without a final answer."
end

def double_check(prompt, awnser)
  messages = [
    { role: "system", content: "You are a doublechecking agent which is created to only check if thiss awnser is good enough Return false if it already is good and if it needs improving explain shortly what needs to be improved" },
    { role: "user", content: "the prompt is: #{prompt} and this is the generated awnser #{awnser} " }
  ]
  
  reply= chat(messages, max_tokens: 500)
  p reply
  return reply
end


THINK_SYSTEM = "Write private notes for yourself and will be put under the role assistant. Use short fragments and as few words as possible. Note what is wanted, the stated facts copied exactly, the constraints that limit the answer, anything missing that matters, and what should come first. If something is not stated, say it is unknown. Never guess or invent details. Write only the notes, not the answer. If no notes are needed reply None"
def think(prompt)
  messages = [
    { role: "system", content: THINK_SYSTEM },
    { role: "user", content: prompt }
  ]
  notes = chat(messages, temperature: 0.9, max_tokens: 2000)["content"].to_s
  
  ask_with_tools(prompt, notes)


end

puts think("Create a complete, playable two-player ping-pong game as a single file named index.html. Use only HTML, CSS, and vanilla JavaScript—no libraries or external assets. The game should have a canvas, two paddles, a bouncing ball, a center line, and scores. Player 1 moves with W/S; Player 2 moves with the Up/Down arrow keys. The first player to reach 5 points wins. Include a start screen, restart button, responsive layout, and keyboard instructions. Keep the code simple and readable. Create and attach the actual downloadable index.html file; don’t just describe the game or provide instructions. If file creation isn’t supported, provide the complete code in one block that I can save as index.html.")