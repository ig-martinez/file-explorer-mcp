class McpController < ApplicationController
  # MCP Streamable HTTP transport – single endpoint handles all JSON-RPC 2.0 traffic.
  # Spec: https://spec.modelcontextprotocol.io/specification/

  PROTOCOL_VERSION = "2024-11-05"
  SERVER_NAME      = "file-explorer-mcp"
  SERVER_VERSION   = "1.0.0"

  def handle
    body = request.body.read
    return render_error(nil, -32_700, "Parse error") if body.blank?

    data = JSON.parse(body)
    process_message(data)
  rescue JSON::ParserError
    render_error(nil, -32_700, "Parse error")
  end

  private

  # --------------------------------------------------------------------------
  # Message dispatch
  # --------------------------------------------------------------------------

  def process_message(msg)
    id     = msg["id"]
    method = msg["method"]
    params = msg["params"] || {}

    # Notifications (no id) – acknowledge without response
    return head(:no_content) if id.nil?

    result = case method
             when "initialize"             then handle_initialize(params)
             when "notifications/initialized" then return head(:no_content)
             when "ping"                   then {}
             when "tools/list"             then handle_tools_list
             when "tools/call"             then handle_tools_call(params)
             else
               return render_error(id, -32_601, "Method not found: #{method}")
             end

    render json: { jsonrpc: "2.0", id:, result: }
  rescue McpError => e
    render_error(id, e.code, e.message, e.data)
  rescue => e
    render_error(id, -32_603, "Internal error: #{e.message}")
  end

  # --------------------------------------------------------------------------
  # initialize
  # --------------------------------------------------------------------------

  def handle_initialize(params)
    {
      protocolVersion: PROTOCOL_VERSION,
      capabilities: { tools: {} },
      serverInfo: { name: SERVER_NAME, version: SERVER_VERSION },
      instructions: "File-system exploration server. " \
                    "All paths must be absolute. " \
                    "The server runs with the OS permissions of the Rails process."
    }
  end

  # --------------------------------------------------------------------------
  # tools/list
  # --------------------------------------------------------------------------

  def handle_tools_list
    { tools: TOOLS }
  end

  # --------------------------------------------------------------------------
  # tools/call
  # --------------------------------------------------------------------------

  def handle_tools_call(params)
    name      = params["name"] or raise McpError.new(-32_602, "Missing tool name")
    arguments = params["arguments"] || {}

    content = case name
              when "read_file"       then tool_read_file(arguments)
              when "list_directory"  then tool_list_directory(arguments)
              when "file_info"       then tool_file_info(arguments)
              when "search_files"    then tool_search_files(arguments)
              when "read_file_lines" then tool_read_file_lines(arguments)
              else
                raise McpError.new(-32_602, "Unknown tool: #{name}")
              end

    { content: [{ type: "text", text: content }] }
  end

  # --------------------------------------------------------------------------
  # Tool implementations
  # --------------------------------------------------------------------------

  def tool_read_file(args)
    path = require_path(args)
    raise McpError.new(-32_602, "Path is a directory") if File.directory?(path)
    raise McpError.new(-32_602, "File not found: #{path}") unless File.exist?(path)
    raise McpError.new(-32_602, "Not a file: #{path}") unless File.file?(path)

    encoding = args["encoding"] || "utf-8"
    File.read(path, encoding:)
  rescue Errno::EACCES
    raise McpError.new(-32_602, "Permission denied: #{args['path']}")
  end

  def tool_read_file_lines(args)
    path = require_path(args)
    raise McpError.new(-32_602, "File not found: #{path}") unless File.file?(path)

    start_line = (args["start_line"] || 1).to_i
    end_line   = (args["end_line"] || Float::INFINITY)
    end_line   = end_line == "end" ? Float::INFINITY : end_line.to_i

    lines = File.readlines(path, encoding: "utf-8")
    selected = lines[(start_line - 1)..(end_line == Float::INFINITY ? -1 : end_line - 1)]
    raise McpError.new(-32_602, "Line range out of bounds") if selected.nil? || selected.empty?

    selected.each_with_index.map { |l, i| "#{start_line + i}: #{l.chomp}" }.join("\n")
  rescue Errno::EACCES
    raise McpError.new(-32_602, "Permission denied: #{args['path']}")
  end

  def tool_list_directory(args)
    path = require_path(args)
    raise McpError.new(-32_602, "Directory not found: #{path}") unless File.exist?(path)
    raise McpError.new(-32_602, "Not a directory: #{path}") unless File.directory?(path)

    entries = Dir.entries(path).reject { |e| e == "." || e == ".." }.sort
    lines = entries.map do |entry|
      full = File.join(path, entry)
      type = File.directory?(full) ? "DIR " : "FILE"
      size = File.directory?(full) ? "" : " (#{File.size(full)} bytes)"
      "#{type}  #{entry}#{size}"
    end

    "Contents of #{path}:\n" + lines.join("\n")
  rescue Errno::EACCES
    raise McpError.new(-32_602, "Permission denied: #{args['path']}")
  end

  def tool_file_info(args)
    path = require_path(args)
    raise McpError.new(-32_602, "Path not found: #{path}") unless File.exist?(path)

    stat = File.stat(path)
    info = {
      path:,
      type:         (File.directory?(path) ? "directory" : "file"),
      size_bytes:   stat.size,
      permissions:  sprintf("%o", stat.mode),
      created_at:   stat.ctime.iso8601,
      modified_at:  stat.mtime.iso8601,
      readable:     File.readable?(path),
      writable:     File.writable?(path),
      executable:   File.executable?(path)
    }

    if File.directory?(path)
      info[:entry_count] = Dir.entries(path).count - 2 # exclude . and ..
    end

    info.map { |k, v| "#{k}: #{v}" }.join("\n")
  rescue Errno::EACCES
    raise McpError.new(-32_602, "Permission denied: #{args['path']}")
  end

  def tool_search_files(args)
    base    = require_path(args)
    pattern = args["pattern"] or raise McpError.new(-32_602, "Missing 'pattern' argument")
    raise McpError.new(-32_602, "Directory not found: #{base}") unless File.directory?(base)

    case args["type"]
    when "content"
      search_by_content(base, pattern, args)
    else
      search_by_name(base, pattern, args)
    end
  end

  # --------------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------------

  def require_path(args)
    raw = args["path"] or raise McpError.new(-32_602, "Missing 'path' argument")
    File.expand_path(raw)
  end

  def search_by_name(base, pattern, args)
    max     = (args["max_results"] || 50).to_i
    glob    = File.join(base, "**", "*")
    results = Dir.glob(glob, File::FNM_DOTMATCH)
                 .reject { |p| File.basename(p).start_with?(".") && !args["include_hidden"] }
                 .select { |p| File.basename(p).match?(Regexp.new(pattern, Regexp::IGNORECASE)) }
                 .first(max)

    return "No files found matching '#{pattern}' in #{base}" if results.empty?
    "Found #{results.size} file(s):\n" + results.join("\n")
  rescue RegexpError => e
    raise McpError.new(-32_602, "Invalid regex pattern: #{e.message}")
  end

  def search_by_content(base, pattern, args)
    max     = (args["max_results"] || 20).to_i
    glob    = args["file_pattern"] ? File.join(base, "**", args["file_pattern"]) : File.join(base, "**", "*")
    regex   = Regexp.new(pattern, Regexp::IGNORECASE)
    matches = []

    Dir.glob(glob).each do |path|
      next unless File.file?(path)
      next if File.size(path) > 10 * 1024 * 1024 # skip files > 10 MB

      File.foreach(path).with_index(1) do |line, lineno|
        if line.match?(regex)
          matches << "#{path}:#{lineno}: #{line.chomp}"
          break if matches.size >= max
        end
      end
      break if matches.size >= max
    rescue Errno::EACCES, ArgumentError
      next
    end

    return "No content matches for '#{pattern}' in #{base}" if matches.empty?
    "Found #{matches.size} match(es):\n" + matches.join("\n")
  rescue RegexpError => e
    raise McpError.new(-32_602, "Invalid regex pattern: #{e.message}")
  end

  # --------------------------------------------------------------------------
  # Error rendering
  # --------------------------------------------------------------------------

  def render_error(id, code, message, data = nil)
    error = { code:, message: }
    error[:data] = data if data
    render json: { jsonrpc: "2.0", id:, error: }, status: :ok
  end

  # --------------------------------------------------------------------------
  # Tool schemas (JSON Schema used by tools/list)
  # --------------------------------------------------------------------------

  TOOLS = [
    {
      name: "read_file",
      description: "Read the complete contents of a file from the filesystem. " \
                   "Supports any text file. Binary files should be avoided.",
      inputSchema: {
        type: "object",
        properties: {
          path: {
            type: "string",
            description: "Absolute path to the file to read."
          },
          encoding: {
            type: "string",
            description: "File encoding (default: utf-8).",
            default: "utf-8"
          }
        },
        required: ["path"]
      }
    },
    {
      name: "read_file_lines",
      description: "Read a specific range of lines from a file. " \
                   "Useful for large files where you only need a portion.",
      inputSchema: {
        type: "object",
        properties: {
          path: {
            type: "string",
            description: "Absolute path to the file."
          },
          start_line: {
            type: "integer",
            description: "First line to read (1-based, default: 1).",
            default: 1
          },
          end_line: {
            type: "integer",
            description: "Last line to read (1-based, inclusive). Omit to read to end of file."
          }
        },
        required: ["path"]
      }
    },
    {
      name: "list_directory",
      description: "List the contents of a directory, showing filenames, types (file/dir), and sizes.",
      inputSchema: {
        type: "object",
        properties: {
          path: {
            type: "string",
            description: "Absolute path to the directory to list."
          }
        },
        required: ["path"]
      }
    },
    {
      name: "file_info",
      description: "Get detailed metadata about a file or directory: size, permissions, timestamps, etc.",
      inputSchema: {
        type: "object",
        properties: {
          path: {
            type: "string",
            description: "Absolute path to the file or directory."
          }
        },
        required: ["path"]
      }
    },
    {
      name: "search_files",
      description: "Search for files by name (regex) or by content (grep-style) within a directory tree.",
      inputSchema: {
        type: "object",
        properties: {
          path: {
            type: "string",
            description: "Absolute path to the root directory to search within."
          },
          pattern: {
            type: "string",
            description: "Search pattern (regex). " \
                         "For name search: matches filenames. " \
                         "For content search: matches lines within files."
          },
          type: {
            type: "string",
            enum: ["name", "content"],
            description: "Whether to search by file 'name' (default) or file 'content'.",
            default: "name"
          },
          file_pattern: {
            type: "string",
            description: "Glob pattern to restrict content search to specific file types, e.g. '*.rb'. " \
                         "Only used when type=content."
          },
          max_results: {
            type: "integer",
            description: "Maximum number of results to return (default: 50 for name, 20 for content)."
          },
          include_hidden: {
            type: "boolean",
            description: "Include hidden files/directories (those starting with '.'). Default: false.",
            default: false
          }
        },
        required: ["path", "pattern"]
      }
    }
  ].freeze
end
