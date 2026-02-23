# Allow all origins for the MCP server.
# This server is intended to run locally; tighten origins in production.
Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins "*"
    resource "*",
      headers: :any,
      methods: %i[get post options head]
  end
end
