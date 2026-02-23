Rails.application.routes.draw do
  # MCP Streamable HTTP transport – single endpoint for all JSON-RPC messages.
  post "/mcp", to: "mcp#handle"

  # Health check
  get "/health", to: proc { [200, { "Content-Type" => "application/json" }, ['{"status":"ok"}']] }
end
