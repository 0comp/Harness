require "net/http"
require "json"
require "uri"

OLLAMA_URL = URI("http://localhost:11434/api/chat")

DEFAULT_TEMPERATURE = 0.2

def ask_model(prompt, temperature: DEFAULT_TEMPERATURE)
  request = Net::HTTP::Post.new(OLLAMA_URL)
  request["content-type"] = "application/json"
  request.body = JSON.generate(
    model: "smollm2:latest",
    stream: false,
    options: { temperature: temperature },
    messages: [
      { role: "user", content: prompt }
    ]
  )
  

  response = Net::HTTP.start(OLLAMA_URL.hostname, OLLAMA_URL.port) do |http|
    http.request(request)
  end

  data = JSON.parse(response.body)
  raise "Ollama error: #{data}" unless response.is_a?(Net::HTTPSuccess)


  puts temperature
  data["message"]["content"]
end

awnser1 = ask_model("How do i make sushi", temperature: 1)

awnser2 = ask_model("How do i make sushi.", temperature: 0.0)
question = "This is 2 of the same prompts, with the only diffrence being one having the temprature 1 and the other 0. WHAT is the diffrence between the 2 diffrent outputs?: '"+ awnser1+ "and '"+ awnser2
puts question
puts ask_model(question)
