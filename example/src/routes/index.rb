# frozen_string_literal: true

# GET / — Welcome page rendered from a Twig template
Tina4.get "/" do |request, response|
  begin
    html = Tina4::Template.render("index.twig", {
      title: "Tina4 Ruby Example",
      message: "Welcome to Tina4 Ruby",
      version: Tina4::VERSION
    })
    response.html(html)
  rescue => e
    Tina4::Log.error("Template render failed: #{e.message}")
    response.html("<h1>Welcome to Tina4 Ruby</h1><p>Version: #{Tina4::VERSION}</p>")
  end
end
